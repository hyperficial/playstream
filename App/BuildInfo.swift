import Foundation

/// Which build this is. The git commit and build time are stamped into the bundle's Info.plist
/// by `scripts/stamp-build.sh` (a build phase), so a running app can say exactly what it was
/// built from: `psctl status` shows it.
enum BuildInfo {
	private static let info = Bundle.main.infoDictionary ?? [:]

	static var version: String { info["CFBundleShortVersionString"] as? String ?? "?" }
	static var buildNumber: String { info["CFBundleVersion"] as? String ?? "?" }
	/// Short commit hash, with "+dirty" when the working tree had uncommitted changes.
	static var gitCommit: String { info["PSGitCommit"] as? String ?? "unknown" }
	static var gitBranch: String { info["PSGitBranch"] as? String ?? "unknown" }

	/// When the bundle was built (UTC, ISO 8601). Falls back to the executable's modification time.
	static var buildTime: String {
		if let stamped = info["PSBuildTime"] as? String { return stamped }
		if let path = Bundle.main.executablePath,
		   let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
			return ISO8601DateFormatter().string(from: modified) + " (executable time)"
		}
		return "unknown"
	}

	static var summary: String { "\(version) (\(buildNumber)) \(gitCommit) built \(buildTime)" }

	static var json: [String: Any] {
		[
			"name": info["CFBundleName"] as? String ?? "PlayStream",
			"version": version,
			"build": buildNumber,
			"gitCommit": gitCommit,
			"gitBranch": gitBranch,
			"buildTime": buildTime,
			"bundlePath": Bundle.main.bundlePath,
			"bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
		]
	}
}
