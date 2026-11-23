import Foundation
import PSContracts
import PSCore

/// The app without the app: a control server and command router wired to a synthetic session
/// (fake console, fake video pipeline, fake controller) with the real flight recorder, hitch
/// detector, settings catalog, resume policy and relaunch helper in between. Everything it
/// writes (socket, log, debug files, resume record, settings) stays under `root`, so it can run
/// next to the real app without touching anything of it.
final class HeadlessHost: @unchecked Sendable {
	struct Options {
		var fps = 60.0
		var bitrateMbps = 15.0
		/// Simulated network stall: every n-th frame arrives this late.
		var stallEvery: Int?
		var stallMs = 120.0
		/// The fake player keeps a button held for this long after start (for "relaunch when idle").
		var busySeconds = 0.0
		/// The first n connection attempts are refused with "Remote Play already in use".
		var busyAttempts = 0
		/// Command the relaunch helper runs with the bundle path appended. Empty: relaunch is a
		/// dry run that only reports what it would do.
		var relaunchLauncher: [String] = []
		var startSession = true
	}

	let root: URL
	let options: Options
	let defaults: HarnessDefaults
	let storage: DebugStorage
	let resumeStore: ResumeStore
	let stream: SyntheticStream
	let pipeline = FakePipeline()
	let tee = StreamCaptureTee()
	let activity = ControllerActivityMonitor()
	let router: ControlRouter
	private(set) var server: ControlServer!

	private let lock = NSLock()
	private let startedAt = Date()
	private var sessionStartedAt: Date?
	private var sessionPhase = "idle"
	private var connectAttempts = 0
	private var recording = false
	private var idleWait: IdleWait?
	private var pendingRelaunch: [String: Any]?
	private var lastRelaunch: [String: Any]?
	private var statsTimer: DispatchSourceTimer?
	private var detector = HitchDetector()
	private var controllerThread: Thread?
	private var busyUntil = Date.distantPast
	private let work = DispatchQueue(label: "harness.host")
	private(set) var appliedSettings: [[String]] = []
	/// Called instead of exiting when a relaunch with a real launcher has been handed over.
	var onExit: (Int32) -> Void = { exit($0) }

	var socketURL: URL { root.appendingPathComponent("control.sock") }

	init(root: URL, options: Options = Options()) throws {
		self.root = root
		self.options = options
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		// Settings in a file under the root (a relaunched host finds them again), never in the
		// preferences system and never the app's.
		defaults = HarnessDefaults(fileURL: root.appendingPathComponent("settings.plist"))
		storage = DebugStorage(root: root.appendingPathComponent("debug", isDirectory: true))
		resumeStore = ResumeStore(fileURL: root.appendingPathComponent("resume.json"))
		stream = SyntheticStream(fps: options.fps, bytesPerFrame: max(64, Int(options.bitrateMbps * 1_000_000 / 8 / options.fps)))
		if let every = options.stallEvery { stream.stall = (every, options.stallMs / 1000) }
		router = ControlRouter(defaults: defaults, storage: storage)

		tee.downstream = pipeline
		tee.keyframeRequester = stream
		tee.notesProvider = { [defaults] in ["settings": SettingsCatalog.snapshot(defaults), "build": "ps-core-harness", "source": "synthetic stream"] }
		tee.logHandler = { CoreLog.note($0) }
		stream.sink = tee
		activity.downstream = nil
		applyFlightRecorderSettings()

		router.hooks = makeHooks()
		server = ControlServer(socketURL: socketURL) { [router] request in await router.handle(request) }
	}

	func removeDefaults() {
		defaults.reset()
	}

	/// The fake player holds a button for the next `seconds`.
	func simulateInput(for seconds: Double) {
		lock.withLock { busyUntil = Date().addingTimeInterval(seconds) }
		// The fake controller only reports every 50 ms; a real one reports a press at once.
		if seconds > 0 { activity.noteActivity() }
	}

	// MARK: Lifecycle

	func start() throws {
		try server.start()
		CoreLog.note("Harness host up: socket \(socketURL.path)")
		startFakeController()
		let timer = DispatchSource.makeTimerSource(queue: work)
		timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
		timer.setEventHandler { [weak self] in self?.statsTick() }
		statsTimer = timer
		timer.resume()

		// The same decision the app makes at launch.
		let record = resumeStore.load()
		let decision = ResumePolicy.decide(
			record: record, enabled: SettingsCatalog.bool("resume.autoReconnect", in: defaults),
			windowSeconds: SettingsCatalog.double("resume.windowSeconds", in: defaults), hasAccount: true, hostIsRegistered: true)
		resumeStore.clear()
		switch decision {
		case .resume(let record, let delay):
			CoreLog.note("Resume: reconnecting to \(record.hostName) (\(record.reason.rawValue)), first attempt in \(String(format: "%.1f", delay)) s")
			work.asyncAfter(deadline: .now() + delay) { [self] in connect(origin: "resume") }
		case .skip(let reason, _):
			if record != nil { CoreLog.note("Resume: not reconnecting: \(reason)") }
			if options.startSession { work.async { [self] in connect(origin: "start") } }
		}
	}

	func shutdown() {
		statsTimer?.cancel()
		statsTimer = nil
		idleWait?.cancel()
		stream.stop()
		server.stop()
		lock.withLock { sessionPhase = "idle" }
		CoreLog.flush()
	}

	/// Opens the synthetic session, going through "already in use" refusals first when asked to.
	private func connect(origin: String, attempt: Int = 1) {
		let refused: Bool = lock.withLock {
			connectAttempts += 1
			sessionPhase = "connecting"
			return connectAttempts <= options.busyAttempts
		}
		if refused {
			let reason = "Remote Play on Console is already in use"
			CoreLog.note("Session ended: \(reason) (error: true)")
			guard ReconnectPolicy.isConsoleBusy(reason), let delay = ReconnectPolicy.delay(afterBusyAttempt: attempt) else {
				CoreLog.note("Reconnect: giving up after \(attempt) attempts")
				lock.withLock { sessionPhase = "idle" }
				return
			}
			CoreLog.note("Reconnect: console still busy, attempt \(attempt + 1) in \(Int(delay)) s")
			// The harness keeps its waits short; the real delays are checked in the self-test.
			work.asyncAfter(deadline: .now() + delay / 10) { [self] in connect(origin: origin, attempt: attempt + 1) }
			return
		}
		stream.start()
		lock.withLock {
			sessionStartedAt = Date()
			sessionPhase = "streaming"
			detector.reset()
		}
		CoreLog.note("Session started (\(origin)): synthetic \(Int(stream.fps)) fps, \(stream.bytesPerFrame * 8 * Int(stream.fps) / 1000) kbit/s")
	}

	private func disconnect(reason: String) {
		stream.stop()
		lock.withLock {
			sessionStartedAt = nil
			sessionPhase = "idle"
		}
		CoreLog.note("Session ended: \(reason) (error: false)")
	}

	var sessionRunning: Bool { stream.isRunning }

	// MARK: Fake controller

	/// Pushes controller snapshots like the input module would: a held button while "busy",
	/// then everything at rest, with the motion sensors changing all the time.
	private func startFakeController() {
		simulateInput(for: options.busySeconds)
		let thread = Thread { [self] in
			var tick = 0
			while true {
				var state = ControllerState()
				state.gyroX = Float(tick % 7) * 0.01
				if Date() < lock.withLock({ busyUntil }) {
					state.buttons = tick % 2 == 0 ? [.cross] : []
					state.leftX = 20_000
				}
				activity.controllerStateDidChange(state)
				tick += 1
				usleep(50_000)
			}
		}
		thread.name = "synthetic.controller"
		thread.start()
		controllerThread = thread
	}

	// MARK: Stats and hitch notes

	private func statsTick() {
		let s = pipeline.snapshot
		var sample = HitchSample(time: ProcessInfo.processInfo.systemUptime)
		sample.streaming = s.streaming
		sample.framesReceived = s.framesReceived
		sample.arrivalIntervalsMs = s.recentArrivalIntervalsMs
		sample.streamFPS = stream.fps
		sample.presentedFPS = stream.fps
		sample.bitrateMbps = Double(stream.bytesPerFrame * 8) * stream.fps / 1_000_000
		let line: String? = lock.withLock {
			detector.configuration.longFrameFactor = SettingsCatalog.double("debug.hitchFrameFactor", in: defaults)
			return detector.ingest(sample)
		}
		if let line, SettingsCatalog.bool("debug.hitchNotes", in: defaults) { CoreLog.note(line) }
	}

	private func applyFlightRecorderSettings() {
		tee.limits = StreamCaptureTee.Limits(
			seconds: SettingsCatalog.double("debug.flightRecorderSeconds", in: defaults),
			bytes: SettingsCatalog.int("debug.flightRecorderMegabytes", in: defaults) * 1024 * 1024)
		tee.keyframeIntervalSeconds = SettingsCatalog.double("debug.flightRecorderKeyframeSeconds", in: defaults)
	}

	// MARK: Hooks

	private func makeHooks() -> ControlRouter.Hooks {
		var hooks = ControlRouter.Hooks()
		hooks.status = { [self] in
			let (phase, started, pending, last, attempts): (String, Date?, [String: Any]?, [String: Any]?, Int) = lock.withLock {
				(sessionPhase, sessionStartedAt, pendingRelaunch, lastRelaunch, connectAttempts)
			}
			return [
				"app": [
					"name": "ps-core-harness", "version": "harness", "build": "0",
					"gitCommit": "harness", "buildTime": NSNull(),
					"bundlePath": Bundle.main.bundlePath, "executable": CommandLine.arguments[0],
				] as [String: Any],
				"uptimeSeconds": (Date().timeIntervalSince(startedAt) * 10).rounded() / 10,
				"session": [
					"running": stream.isRunning, "phase": phase,
					"console": ["name": "Synthetic PS5", "id": "000000000000", "address": "synthetic"],
					"profile": JSONValue.reflect(stream.profile),
					"renderer": "fake",
					"uptimeSeconds": started.map { (Date().timeIntervalSince($0) * 10).rounded() / 10 } ?? NSNull(),
					"connectAttempts": attempts,
				] as [String: Any],
				"controlSocket": socketURL.path,
				"controllerIdleSeconds": (activity.idleSeconds * 10).rounded() / 10,
				"pendingRelaunch": pending ?? NSNull(),
				"lastRelaunch": last ?? NSNull(),
			]
		}
		hooks.stats = { [self] in
			[
				"video": JSONValue.reflect(pipeline.snapshot),
				"session": ["measuredBitrate": Double(stream.bytesPerFrame * 8) * stream.fps, "packetLoss": 0, "rttMilliseconds": 0.5] as [String: Any],
				"audio": NSNull(),
				"recorder": ["state": lock.withLock { recording } ? "recording" : "idle"],
				"flightRecorder": tee.status,
				"input": ["idleSeconds": activity.idleSeconds, "snapshots": activity.snapshotCount] as [String: Any],
				"hitchNotes": lock.withLock { detector.notesWritten },
				"keyframeRequests": stream.keyframeRequests,
			]
		}
		hooks.sessionActive = { [self] in stream.isRunning }
		hooks.videoDebug = { [self] in stream.isRunning ? pipeline : nil }
		hooks.flightRecorder = { [self] in tee }
		hooks.applySettings = { [self] write in
			let keys = try write()
			var applied: [String] = []
			if keys.contains(where: { $0.hasPrefix("debug.flightRecorder") }) {
				applyFlightRecorderSettings()
				applied.append("flight recorder \(tee.limits.seconds) s / \(tee.limits.bytes / 1024 / 1024) MiB, keyframe every \(tee.keyframeIntervalSeconds) s")
			}
			for key in keys where SettingsCatalog.descriptor(for: key)?.applies == .live && !key.hasPrefix("debug.flightRecorder") {
				applied.append("\(key) (synthetic host: recorded only)")
			}
			lock.withLock { appliedSettings.append(keys) }
			if keys.contains("debug.controlChannel"), !SettingsCatalog.bool("debug.controlChannel", in: defaults) {
				// Let the response out first.
				work.asyncAfter(deadline: .now() + 0.3) { [self] in server.stop() }
			}
			return applied
		}
		hooks.record = { [self] action in
			guard stream.isRunning || action == "status" else { throw ControlError("no session is running") }
			return lock.withLock {
				if action == "start" { recording = true }
				if action == "stop" { recording = false }
				return ["state": recording ? "recording" : "idle", "note": "synthetic host: no movie is written"]
			}
		}
		hooks.disconnect = { [self] in
			guard stream.isRunning else { throw ControlError("no session is running") }
			disconnect(reason: "Stopped")
			return ["disconnected": true]
		}
		hooks.reconnect = { [self] _ in
			if stream.isRunning { disconnect(reason: "Stopped") }
			lock.withLock { connectAttempts = 0 }
			work.asyncAfter(deadline: .now() + 0.2) { [self] in connect(origin: "reconnect") }
			return ["reconnecting": true]
		}
		hooks.relaunch = { [self] request in try relaunch(request) }
		// Test host only: `simulate input <seconds>` makes the fake player busy,
		// `simulate stall <ms>` delays the next frame like a network stall.
		hooks.custom = { [self] request in
			guard request.command == "simulate" else { return nil }
			switch (request.arg(0), Double(request.arg(1) ?? "")) {
			case ("input", let seconds?):
				simulateInput(for: seconds)
				return ["simulating": "controller input for \(seconds) s"]
			case ("stall", let ms?):
				stream.stallOnce(seconds: ms / 1000)
				return ["simulating": "one network stall of \(ms) ms"]
			default:
				throw ControlError("usage: simulate input <seconds> | simulate stall <milliseconds>")
			}
		}
		return hooks
	}

	// MARK: Relaunch

	private func relaunch(_ request: ControlRouter.RelaunchRequest) throws -> [String: Any] {
		if request.cancel {
			let had: Bool = lock.withLock {
				let had = pendingRelaunch != nil
				pendingRelaunch = nil
				return had
			}
			idleWait?.cancel()
			idleWait = nil
			guard had else { throw ControlError("no relaunch is waiting") }
			CoreLog.note("Relaunch: cancelled")
			return ["cancelled": true]
		}
		guard lock.withLock({ pendingRelaunch == nil }) else { throw ControlError("a relaunch is already waiting for the controller to go idle; `relaunch cancel` stops it") }

		var bundle: Relauncher.BundleInfo?
		if let path = request.bundlePath {
			bundle = try Relauncher.inspectBundle(at: URL(fileURLWithPath: path), expectedIdentifier: nil)
		} else if !options.relaunchLauncher.isEmpty {
			throw ControlError("the harness has no bundle of its own: give the bundle to start")
		}
		let target = bundle?.url.path ?? "(same bundle)"

		if request.whenIdle, stream.isRunning {
			let description: [String: Any] = [
				"bundle": target, "idleSeconds": request.idleSeconds, "timeoutSeconds": request.timeoutSeconds,
				"onTimeout": request.relaunchOnTimeout ? "relaunch" : "cancel", "requestedAt": JSONValue.string(from: Date()),
			]
			lock.withLock { pendingRelaunch = description }
			CoreLog.note("Relaunch: waiting for \(request.idleSeconds) s without controller input (timeout \(Int(request.timeoutSeconds)) s) before starting \(target)")
			idleWait = IdleWait(requiredIdleSeconds: request.idleSeconds, timeoutSeconds: request.timeoutSeconds, queue: work, idleSeconds: { [activity] in activity.idleSeconds }) { [self] outcome in
				lock.withLock { pendingRelaunch = nil }
				idleWait = nil
				switch outcome {
				case .idle(let waited):
					CoreLog.note("Relaunch: controller idle after \(String(format: "%.1f", waited)) s")
					performRelaunch(bundle: bundle)
				case .timedOut where request.relaunchOnTimeout:
					CoreLog.note("Relaunch: controller never went idle within \(Int(request.timeoutSeconds)) s, relaunching anyway")
					performRelaunch(bundle: bundle)
				case .timedOut:
					CoreLog.note("Relaunch: controller never went idle within \(Int(request.timeoutSeconds)) s, not relaunching")
					lock.withLock { lastRelaunch = ["bundle": target, "outcome": "timed out waiting for idle"] }
				case .cancelled:
					break
				}
			}
			return ["scheduled": true, "waitingForIdle": true, "bundle": target, "idleSeconds": request.idleSeconds, "timeoutSeconds": request.timeoutSeconds]
		}
		work.asyncAfter(deadline: .now() + 0.2) { [self] in performRelaunch(bundle: bundle) }
		return ["scheduled": true, "waitingForIdle": false, "bundle": target]
	}

	private func performRelaunch(bundle: Relauncher.BundleInfo?) {
		let target = bundle?.url.path ?? "(same bundle)"
		let wasStreaming = stream.isRunning
		if wasStreaming {
			resumeStore.save(ResumeRecord(hostID: "000000000000", hostName: "Synthetic PS5", reason: .relaunch, wasFullScreen: true, sessionEndedAt: Date(), build: "harness"))
			disconnect(reason: "Stopped")
		}
		guard let bundle, !options.relaunchLauncher.isEmpty else {
			// Dry run: say what would happen and carry on.
			CoreLog.note("Relaunch (dry run): would start \(target) and exit; the next launch would resume: \(wasStreaming)")
			lock.withLock { lastRelaunch = ["bundle": target, "outcome": "dry run", "wouldResume": wasStreaming] }
			resumeStore.clear()
			if wasStreaming { work.asyncAfter(deadline: .now() + 0.3) { [self] in connect(origin: "dry-run relaunch") } }
			return
		}
		var plan = Relauncher.Plan(bundle: bundle.url, logURL: root.appendingPathComponent("relaunch.log"))
		plan.launcher = options.relaunchLauncher
		plan.verifyAfterSeconds = 2
		do {
			let helper = try Relauncher.spawn(plan)
			CoreLog.note("Relaunch: session closed, helper \(helper) starts \(target) once this process (\(getpid())) has exited")
		} catch {
			CoreLog.note("Relaunch failed: \(error)")
			resumeStore.clear()
			if wasStreaming { connect(origin: "failed relaunch") }
			return
		}
		shutdown()
		onExit(0)
	}
}
