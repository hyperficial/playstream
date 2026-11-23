import Darwin
import Foundation

/// Starts an app bundle once the current process has exited, so a running app can replace
/// itself with a new build (or simply restart) without anyone clicking anything.
///
/// The work is done by a small detached shell helper: it waits for this process to go away,
/// opens the new bundle, checks a few seconds later that it is really running and, if it is
/// not and an older bundle is known, opens that one instead, so a build that fails to start
/// does not leave the owner without the app.
public enum Relauncher {
	public struct Plan {
		/// Process to wait for (normally our own).
		public var waitForPID: pid_t
		public var bundle: URL
		/// Opened instead when `bundle` does not come up. nil or equal to `bundle`: no fallback.
		public var fallbackBundle: URL?
		/// Command the bundle path is appended to. `open -n` starts a new instance even if
		/// Launch Services still thinks the app is running.
		public var launcher: [String] = ["/usr/bin/open", "-n"]
		/// If the old process is still alive after this long it is killed, so the swap cannot hang.
		public var killAfterSeconds: Double = 12
		/// How long after launching to check that the new instance is running. 0 skips the check.
		public var verifyAfterSeconds: Double = 6
		/// Helper output (one line per step) is appended here.
		public var logURL: URL

		public init(waitForPID: pid_t = getpid(), bundle: URL, fallbackBundle: URL? = nil, logURL: URL) {
			self.waitForPID = waitForPID
			self.bundle = bundle
			self.fallbackBundle = fallbackBundle
			self.logURL = logURL
		}
	}

	public struct BundleInfo: Sendable {
		public var url: URL
		public var executable: URL
		public var identifier: String
		public var version: String
		public var gitCommit: String?
		public var buildTime: String?
	}

	/// Checks that `url` is a launchable app bundle and, when `expectedIdentifier` is given,
	/// that it is the same app. Throws a `ControlError` describing what is wrong otherwise.
	public static func inspectBundle(at url: URL, expectedIdentifier: String?) throws -> BundleInfo {
		let url = url.standardizedFileURL
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
			throw ControlError("no app bundle at \(url.path)")
		}
		guard url.pathExtension == "app" else { throw ControlError("\(url.path) is not an .app bundle") }
		let plistURL = url.appendingPathComponent("Contents/Info.plist")
		guard let data = try? Data(contentsOf: plistURL),
		      let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
			throw ControlError("\(url.path) has no readable Contents/Info.plist (is the build finished?)")
		}
		guard let name = info["CFBundleExecutable"] as? String, !name.isEmpty else {
			throw ControlError("\(url.path) names no executable in its Info.plist")
		}
		let executable = url.appendingPathComponent("Contents/MacOS/\(name)")
		guard FileManager.default.isExecutableFile(atPath: executable.path) else {
			throw ControlError("\(executable.path) is missing or not executable (is the build finished?)")
		}
		let identifier = info["CFBundleIdentifier"] as? String ?? ""
		if let expectedIdentifier, identifier != expectedIdentifier {
			throw ControlError("\(url.path) is \(identifier.isEmpty ? "an app without a bundle identifier" : identifier), not \(expectedIdentifier)")
		}
		return BundleInfo(
			url: url, executable: executable, identifier: identifier,
			version: info["CFBundleShortVersionString"] as? String ?? "",
			gitCommit: info["PSGitCommit"] as? String, buildTime: info["PSBuildTime"] as? String)
	}

	/// The helper. Arguments: pid, new bundle, fallback bundle (may be empty), kill-after in
	/// tenths of a second, verify-after in seconds, then the launcher command.
	static let script = #"""
	pid="$1"; new="$2"; old="$3"; kill_after="$4"; verify_after="$5"; shift 5
	trap '' HUP INT TERM
	log() { echo "$(date '+%Y-%m-%d %H:%M:%S') relaunch: $*"; }
	running() { ps -axo comm= 2>/dev/null | grep -F -- "$1/Contents/MacOS/" >/dev/null; }
	n=0
	while kill -0 "$pid" 2>/dev/null; do
		n=$((n + 1))
		if [ "$n" -ge "$kill_after" ]; then
			log "process $pid is still running after $((kill_after / 10)) s, killing it"
			kill -9 "$pid" 2>/dev/null
			sleep 0.5
			break
		fi
		sleep 0.1
	done
	log "process $pid has exited, starting $new"
	if "$@" "$new"; then
		if [ "$verify_after" = "0" ]; then exit 0; fi
		sleep "$verify_after"
		if running "$new"; then
			log "new instance is running"
			exit 0
		fi
		log "new instance is not running ${verify_after} s after launch"
	else
		log "launching $new failed"
	fi
	if [ -n "$old" ] && [ "$old" != "$new" ]; then
		log "falling back to $old"
		"$@" "$old" || log "launching $old failed too"
	fi
	exit 1
	"""#

	/// Starts the helper, detached from this process (own session, no inherited descriptors),
	/// and returns its process id. The caller then exits.
	@discardableResult
	public static func spawn(_ plan: Plan) throws -> pid_t {
		guard !plan.launcher.isEmpty else { throw ControlError("relaunch: no launcher command") }
		try? FileManager.default.createDirectory(at: plan.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

		let fallback = plan.fallbackBundle.map(\.path) ?? ""
		let arguments = ["/bin/sh", "-c", script, "playstream-relaunch",
		                 String(plan.waitForPID), plan.bundle.path, fallback,
		                 String(max(1, Int(plan.killAfterSeconds * 10))),
		                 plan.verifyAfterSeconds > 0 ? String(format: "%g", plan.verifyAfterSeconds) : "0"] + plan.launcher

		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
		posix_spawn_file_actions_addopen(&actions, 1, plan.logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
		posix_spawn_file_actions_adddup2(&actions, 1, 2)

		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }
		// Own session (survives whatever happens to ours) and none of our descriptors: the
		// helper must not keep the app's sockets or files open after the app is gone.
		posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

		var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
		argv.append(nil)
		defer { for pointer in argv { free(pointer) } }

		var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
		envp.append(nil)
		defer { for pointer in envp { free(pointer) } }

		var pid: pid_t = 0
		let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
		guard status == 0 else { throw ControlError("relaunch helper could not be started: \(String(cString: strerror(status)))") }
		return pid
	}
}
