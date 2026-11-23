import Foundation
import PSContracts

/// Turns control-channel requests into actions. Everything that does not need the app itself
/// (settings, tunables, traces, picture captures, the flight recorder, log access) is handled
/// here; the rest is asked of the host through `Hooks`. The app and the headless test host
/// both plug into the same router, so the command handling tested without the GUI is the
/// command handling the app runs.
///
/// `handle` runs off the main thread and off the stream threads; file work goes to a utility
/// queue. Hooks decide for themselves where they run (the app's hop to the main actor).
public final class ControlRouter: @unchecked Sendable {
	public struct RelaunchRequest: Sendable, Equatable {
		/// Bundle to start. nil: the bundle that is running.
		public var bundlePath: String?
		/// Wait until the controller has been idle before relaunching.
		public var whenIdle = false
		public var idleSeconds = 5.0
		/// Give up waiting for idle after this long.
		public var timeoutSeconds = 600.0
		/// What to do at the timeout: relaunch anyway instead of giving up.
		public var relaunchOnTimeout = false
		/// Cancel a relaunch that is waiting for idle.
		public var cancel = false

		public init() {}
	}

	public struct Hooks {
		/// Build identity, session, console, profile, renderer, uptime.
		public var status: () async -> [String: Any] = { [:] }
		/// Complete stats snapshot.
		public var stats: () async -> [String: Any] = { [:] }
		public var sessionActive: () async -> Bool = { false }
		/// The running session's video pipeline, if it supports debug control.
		public var videoDebug: () async -> VideoDebugControlling? = { nil }
		public var flightRecorder: () async -> StreamCaptureTee? = { nil }
		/// Stores new setting values and applies them. `write` does the storing and returns the
		/// keys whose value changed; the host calls it where its settings are meant to change
		/// (the app: the main thread) and applies the result in the same step, then returns what
		/// took effect live, in words.
		public var applySettings: (_ write: @escaping () throws -> [String]) async throws -> [String] = { write in
			_ = try write()
			return []
		}
		/// "start", "stop" or "status" of the passthrough recorder.
		public var record: (_ action: String) async throws -> [String: Any] = { _ in throw ControlError("recording is not available here") }
		public var reconnect: (_ allowWake: Bool) async throws -> [String: Any] = { _ in throw ControlError("reconnect is not available here") }
		public var disconnect: () async throws -> [String: Any] = { throw ControlError("disconnect is not available here") }
		public var relaunch: (RelaunchRequest) async throws -> [String: Any] = { _ in throw ControlError("relaunch is not available here") }
		/// Commands only this host knows. Return nil for anything else.
		public var custom: (ControlRequest) async throws -> Any? = { _ in nil }

		public init() {}
	}

	public let defaults: UserDefaults
	public let storage: DebugStorage
	public var hooks: Hooks
	private let ioQueue = DispatchQueue(label: "playstream.control.io", qos: .utility)

	public init(defaults: UserDefaults, storage: DebugStorage, hooks: Hooks = Hooks()) {
		self.defaults = defaults
		self.storage = storage
		self.hooks = hooks
	}

	public static let commands: [(usage: String, summary: String)] = [
		("status", "Build identity (git commit, build time), session phase, console, profile, renderer, uptime."),
		("stats", "Complete snapshot: every video, audio and session statistic, recorder and flight recorder state."),
		("settings get [key]", "All settings (or one) with value, default, range and when a change applies."),
		("settings set <key> <value> [<key> <value> ...]", "Change settings with the same effect as the settings panel. \"default\" resets one."),
		("tunables", "The video pipeline's runtime-adjustable internal parameters."),
		("tune <name> <value>", "Change one of them while streaming."),
		("trace [seconds]", "Write the per-frame trace of the last seconds (default 10) as JSON Lines; returns the path."),
		("frames [count]", "Save the next count (default 8) presented pictures; returns the paths."),
		("capture [seconds]", "Write the last seconds of the encoded stream (default: all buffered) as a PSCAP1 file; returns the path."),
		("capture start [seconds]", "Record the encoded stream to disk from now on (optionally for a fixed time)."),
		("capture stop", "End that recording; returns the path."),
		("capture status", "Flight recorder and capture state."),
		("record start|stop|status", "The passthrough movie recorder."),
		("mark <text>", "Write a line into core.log."),
		("log [n]", "The last n log lines (default 40). Option grep=<text> keeps lines containing the text (a|b: either)."),
		("reconnect", "End the session and connect again (applies next-connection settings). Option wake=true wakes a console in rest mode."),
		("disconnect", "End the session."),
		("relaunch [bundle]", "End the session, start the bundle (default: the running one) and exit; the new instance resumes the stream. Options: whenIdle, idleSeconds, timeout, onTimeout=relaunch|cancel, cancel."),
		("ping", "Check that the channel is alive."),
		("help", "This list."),
	]

	// MARK: Dispatch

	public func handle(_ incoming: ControlRequest) async -> ControlResponse {
		var request = incoming
		// Option names are matched without regard to case, dashes or underscores.
		request.options = Dictionary(incoming.options.map { (Self.normalize($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
		do {
			return .success(try await dispatch(request))
		} catch let error as ControlError {
			return .failure(error.message)
		} catch {
			return .failure((error as? LocalizedError)?.errorDescription ?? "\(error)")
		}
	}

	private static func normalize(_ name: String) -> String {
		name.lowercased().filter { $0 != "-" && $0 != "_" }
	}

	private func dispatch(_ request: ControlRequest) async throws -> Any {
		switch request.command.lowercased() {
		case "ping":
			return ["pong": true, "pid": Int(ProcessInfo.processInfo.processIdentifier)] as [String: Any]
		case "help":
			return ["commands": Self.commands.map { ["usage": $0.usage, "summary": $0.summary] }]
		case "status":
			var status = await hooks.status()
			status["pid"] = Int(ProcessInfo.processInfo.processIdentifier)
			status["debugStorage"] = await onIO { self.storage.usage() }
			status["logFile"] = CoreLog.fileURL.path
			return status
		case "stats":
			return await hooks.stats()
		case "settings":
			return try await settings(request)
		case "tunables":
			let video = try await videoDebug()
			return ["tunables": video.debugTunables()]
		case "tune":
			return try await tune(request)
		case "trace":
			return try await trace(request)
		case "frames":
			return try await frames(request)
		case "capture":
			return try await capture(request)
		case "record":
			let action = (request.arg(0) ?? "status").lowercased()
			guard ["start", "stop", "status"].contains(action) else { throw ControlError("usage: record start|stop|status") }
			return try await hooks.record(action)
		case "mark":
			let text = request.args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
			guard !text.isEmpty else { throw ControlError("usage: mark <text>") }
			let line = "MARK: " + text.replacingOccurrences(of: "\n", with: " ")
			CoreLog.note(line)
			return ["logged": line, "time": JSONValue.string(from: Date()), "logFile": CoreLog.fileURL.path]
		case "log":
			let count = min(max(Int(request.arg(0) ?? "") ?? request.int("n") ?? 40, 1), 5000)
			let filter = request.string("grep")
			let lines = await onIO { CoreLog.tail(lines: count, matching: filter) }
			return ["lines": lines, "logFile": CoreLog.fileURL.path]
		case "reconnect":
			return try await hooks.reconnect(request.flag("wake"))
		case "disconnect":
			return try await hooks.disconnect()
		case "relaunch":
			return try await hooks.relaunch(try Self.relaunchRequest(from: request))
		default:
			if let result = try await hooks.custom(request) { return result }
			throw ControlError("unknown command \"\(request.command)\"; `help` lists the commands")
		}
	}

	/// Parses `relaunch [bundle] [cancel]` and its options.
	public static func relaunchRequest(from request: ControlRequest) throws -> RelaunchRequest {
		var out = RelaunchRequest()
		var positional = request.args
		if positional.first?.lowercased() == "cancel" {
			out.cancel = true
			positional.removeFirst()
		}
		if request.flag("cancel") { out.cancel = true }
		if let path = positional.first ?? request.string("bundle"), !path.isEmpty {
			out.bundlePath = (path as NSString).expandingTildeInPath
		}
		out.whenIdle = request.flag("whenidle")
		if let idle = request.double("idleseconds") {
			guard idle >= 0.5, idle <= 120 else { throw ControlError("idleSeconds must be between 0.5 and 120") }
			out.idleSeconds = idle
			out.whenIdle = true
		}
		if let timeout = request.double("timeout") {
			guard timeout >= 1, timeout <= 86_400 else { throw ControlError("timeout must be between 1 and 86400 seconds") }
			out.timeoutSeconds = timeout
		}
		if let action = request.string("ontimeout")?.lowercased() {
			switch action {
			case "relaunch", "force": out.relaunchOnTimeout = true
			case "cancel", "giveup": out.relaunchOnTimeout = false
			default: throw ControlError("onTimeout is relaunch or cancel")
			}
		}
		return out
	}

	// MARK: Settings

	private func settings(_ request: ControlRequest) async throws -> Any {
		let action = (request.arg(0) ?? "get").lowercased()
		switch action {
		case "get", "list":
			if let name = request.arg(1) {
				guard let descriptor = SettingsCatalog.descriptor(for: name) else { throw ControlError("unknown setting \"\(name)\"; `settings get` lists them all") }
				return SettingsCatalog.describe(descriptor, in: defaults)
			}
			return ["settings": SettingsCatalog.listing(defaults)]
		case "set":
			let pairs = Array(request.args.dropFirst())
			guard !pairs.isEmpty, pairs.count % 2 == 0 else { throw ControlError("usage: settings set <key> <value> [<key> <value> ...]") }
			// Validate everything before changing anything, so a typo in the second pair does
			// not leave the first one applied.
			for i in stride(from: 0, to: pairs.count, by: 2) { _ = try SettingsCatalog.parse(pairs[i], pairs[i + 1]) }
			// The host decides where the values are stored and applied (the app: on the main
			// thread, in one step, so that the answer reports exactly what changed live).
			let defaults = self.defaults
			let box = ChangeBox()
			let applied = try await hooks.applySettings {
				var written: [SettingsCatalog.Change] = []
				for i in stride(from: 0, to: pairs.count, by: 2) {
					written.append(try SettingsCatalog.set(pairs[i], to: pairs[i + 1], in: defaults))
				}
				box.changes = written
				return written.filter(\.changed).map(\.descriptor.key)
			}
			let changes = box.changes
			let active = await hooks.sessionActive()
			for change in changes where change.changed {
				CoreLog.note("Setting \(change.descriptor.key) = \(change.newValue) (was \(change.oldValue)) via control channel")
			}
			return [
				"changes": changes.map { change -> [String: Any] in
					var note: String
					if !change.changed {
						note = "unchanged"
					} else {
						switch change.descriptor.applies {
						case .live: note = "applied now"
						case .nextConnection: note = active ? "takes effect at the next connection (`psctl reconnect` applies it now)" : "takes effect at the next connection"
						case .nextLaunch: note = "takes effect at the next launch"
						}
					}
					if change.changed, change.descriptor.key == "debug.controlChannel", (change.newValue as? Bool) == false {
						note = "the control channel closes after this response; turn it back on in the app's settings"
					}
					return [
						"key": change.descriptor.key, "old": change.oldValue, "new": change.newValue,
						"changed": change.changed, "applies": change.descriptor.applies.rawValue, "note": note,
					]
				},
				"appliedLive": applied,
				"sessionActive": active,
			] as [String: Any]
		default:
			throw ControlError("usage: settings get [key] | settings set <key> <value> ...")
		}
	}

	// MARK: Video debugging

	private func videoDebug() async throws -> VideoDebugControlling {
		if let video = await hooks.videoDebug() { return video }
		if await hooks.sessionActive() {
			throw ControlError("the video pipeline in this build does not offer debug control (VideoDebugControlling is not implemented)")
		}
		throw ControlError("no session is running")
	}

	private func tune(_ request: ControlRequest) async throws -> Any {
		guard let name = request.arg(0), let text = request.arg(1) else { throw ControlError("usage: tune <name> <value>") }
		guard let value = Double(text), value.isFinite else { throw ControlError("\"\(text)\" is not a number") }
		let video = try await videoDebug()
		let before = video.debugTunables()
		guard video.setDebugTunable(name, to: value) else {
			if before[name] == nil {
				let close = before.keys.filter { $0.lowercased().contains(name.lowercased()) }.sorted()
				throw ControlError("unknown tunable \"\(name)\"" + (close.isEmpty ? "; `tunables` lists them" : "; did you mean \(close.joined(separator: ", "))?"))
			}
			throw ControlError("\(value) is outside the accepted range of \(name) (now \(before[name]!))")
		}
		let now = video.debugTunables()[name] ?? value
		CoreLog.note("Tunable \(name) = \(now)\(before[name].map { " (was \($0))" } ?? "") via control channel")
		return ["name": name, "value": now, "previous": before[name] ?? NSNull()] as [String: Any]
	}

	private func trace(_ request: ControlRequest) async throws -> Any {
		let seconds = Double(request.arg(0) ?? "") ?? request.double("seconds") ?? 10
		guard seconds > 0, seconds <= 3600 else { throw ControlError("trace takes a number of seconds between 0 and 3600") }
		let video = try await videoDebug()
		let storage = self.storage
		let limit = diskLimit
		return try await onIOThrowing { () -> [String: Any] in
			let url = try storage.newFile(in: .traces, prefix: "trace", extension: "jsonl")
			let records = try video.writeFrameTrace(to: url, lastSeconds: seconds)
			storage.cleanup(maxBytes: limit, protecting: [url])
			CoreLog.note("Frame trace written: \(url.lastPathComponent), \(records) records, last \(seconds) s")
			return ["path": url.path, "records": records, "seconds": seconds]
		}
	}

	private func frames(_ request: ControlRequest) async throws -> Any {
		let count = Int(request.arg(0) ?? "") ?? request.int("count") ?? 8
		guard count >= 1, count <= 600 else { throw ControlError("frames takes a count between 1 and 600") }
		let video = try await videoDebug()
		let directory = try await onIOThrowing { try self.storage.newDirectory(in: .frames, prefix: "frames") }
		let timeout = min(max(request.double("timeout") ?? (10 + Double(count) * 0.25), 1), 600)
		let files: [URL]? = await withTimeout(seconds: timeout) { done in
			video.capturePresentedFrames(count: count, to: directory) { done($0) }
		}
		let limit = diskLimit
		_ = await onIO { self.storage.cleanup(maxBytes: limit, protecting: [directory]) }
		guard let files else {
			throw ControlError("no pictures were captured within \(Int(timeout)) s (is anything being presented?); anything that still arrives goes to \(directory.path)")
		}
		CoreLog.note("Presented pictures captured: \(files.count) in \(directory.lastPathComponent)")
		return ["directory": directory.path, "files": files.map(\.path), "count": files.count] as [String: Any]
	}

	// MARK: Flight recorder

	private func capture(_ request: ControlRequest) async throws -> Any {
		let first = request.arg(0)?.lowercased()
		guard let tee = await hooks.flightRecorder() else {
			throw ControlError(await hooks.sessionActive() ? "this session has no flight recorder" : "no session is running (and none ended recently enough to still have its flight recorder)")
		}
		let limit = diskLimit
		switch first {
		case "status":
			return tee.status
		case "start":
			let seconds = Double(request.arg(1) ?? "") ?? request.double("seconds")
			if let seconds, !(seconds > 0 && seconds <= 86_400) { throw ControlError("capture start takes a duration between 0 and 86400 seconds") }
			let megabytes = min(max(request.double("maxmegabytes") ?? 4096, 1), 1_000_000)
			let url = try await onIOThrowing { try self.storage.newFile(in: .captures, prefix: "stream", extension: "pscap") }
			try tee.startCapture(to: url, maxSeconds: seconds, maxBytes: Int64(megabytes * 1024 * 1024))
			CoreLog.note("Stream capture started: \(url.lastPathComponent)\(seconds.map { ", for \($0) s" } ?? "")")
			return ["path": url.path, "state": "capturing", "seconds": seconds ?? NSNull(), "note": "a keyframe was requested; the file starts with it. `capture stop` ends the capture."] as [String: Any]
		case "stop":
			let outcome: Result<StreamCaptureTee.CaptureResult, Error>
			var note: String?
			if tee.isCapturing {
				outcome = await withCheckedContinuation { c in tee.stopCapture { c.resume(returning: $0) } }
			} else {
				// A capture with a duration ends by itself; report that file.
				let last: Result<StreamCaptureTee.CaptureResult, Error>? = await withCheckedContinuation { c in tee.lastCaptureResult { c.resume(returning: $0) } }
				guard let last else { throw ControlError("no capture is running") }
				outcome = last
				note = "no capture was running; this is the last one that finished"
			}
			let result = try outcome.get()
			_ = await onIO { self.storage.cleanup(maxBytes: limit, protecting: [result.url]) }
			var json = result.json
			if let note { json["note"] = note }
			return json
		default:
			var seconds: Double?
			if let first {
				guard let value = Double(first), value > 0, value.isFinite else { throw ControlError("usage: capture [seconds] | capture start [seconds] | capture stop | capture status") }
				seconds = value
			} else if let value = request.double("seconds"), value > 0, value.isFinite {
				seconds = value
			}
			let url = try await onIOThrowing { try self.storage.newFile(in: .captures, prefix: "flight", extension: "pscap") }
			let outcome: Result<StreamCaptureTee.CaptureResult, Error> = await withCheckedContinuation { c in
				tee.dump(lastSeconds: seconds, to: url) { c.resume(returning: $0) }
			}
			let result = try outcome.get()
			_ = await onIO { self.storage.cleanup(maxBytes: limit, protecting: [result.url]) }
			return result.json
		}
	}

	private var diskLimit: Int64 {
		Int64(SettingsCatalog.int("debug.maxDiskMegabytes", in: defaults)) * 1024 * 1024
	}

	// MARK: Helpers

	private func onIO<T>(_ work: @escaping () -> T) async -> T {
		await withCheckedContinuation { continuation in
			ioQueue.async { continuation.resume(returning: work()) }
		}
	}

	private func onIOThrowing<T>(_ work: @escaping () throws -> T) async throws -> T {
		try await withCheckedThrowingContinuation { continuation in
			ioQueue.async { continuation.resume(with: Result { try work() }) }
		}
	}

	/// Runs `start`, which reports its result through the closure it is given, and returns that
	/// result, or nil when it has not arrived within `seconds`.
	private func withTimeout<T>(seconds: Double, _ start: @escaping (@escaping (T) -> Void) -> Void) async -> T? {
		await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
			let once = Once()
			start { value in
				if once.claim() { continuation.resume(returning: value) }
			}
			ioQueue.asyncAfter(deadline: .now() + seconds) {
				if once.claim() { continuation.resume(returning: nil) }
			}
		}
	}

	private final class ChangeBox: @unchecked Sendable {
		var changes: [SettingsCatalog.Change] = []
	}

	private final class Once: @unchecked Sendable {
		private let lock = NSLock()
		private var claimed = false
		func claim() -> Bool {
			lock.lock()
			defer { lock.unlock() }
			if claimed { return false }
			claimed = true
			return true
		}
	}
}
