import Combine
import Foundation
import PSContracts
import PSCore
import PSInput
import PSPairing
import SwiftUI

/// App-wide state: the paired consoles, discovery, the controller, and the running stream.
///
/// It also owns the parts that let a session survive an app restart without anyone clicking:
/// the resume record, the reconnect-with-backoff logic and the relaunch command.
@MainActor
final class AppModel: ObservableObject {
	let settings = AppSettings()
	let discovery = DiscoveryService()
	let store = HostStore()
	let input = ControllerInput()
	let launchedAt = Date()

	@Published var stream: StreamController?
	@Published var connectingHostID: String?
	@Published var connectProgress: String?
	@Published var lastError: String?
	/// Set while the app is getting a session back on its own (resume at launch, reconnect,
	/// retry after "already in use"). The window shows this instead of the console list and
	/// stays in full screen.
	@Published private(set) var reconnectStatus: ReconnectStatus?
	/// A relaunch that is waiting for the player to pause.
	@Published private(set) var pendingRelaunch: PendingRelaunch?
	/// Full-screen state to use for the next session start instead of the setting (a resumed
	/// session comes back the way it was left). Consumed by the window logic.
	var fullScreenOverride: Bool?

	struct ReconnectStatus: Equatable {
		var consoleName: String
		var message: String
	}

	struct PendingRelaunch: Equatable {
		var bundlePath: String
		var build: String
		var idleSeconds: Double
		var deadline: Date
		var relaunchOnTimeout: Bool
		var requestedAt = Date()
	}

	/// One attempt to open a session, and who asked for it.
	private struct ConnectPlan {
		enum Origin: String {
			/// The owner pressed Connect.
			case user
			/// Picking up the session of the previous run at launch.
			case resume
			/// `psctl reconnect`, or coming back after a failed relaunch.
			case reconnect
		}

		var hostID: String
		var origin: Origin
		/// Whether a console in rest mode may be woken for this.
		var allowWake: Bool
		var attempt = 1
	}

	/// Why the running session is being closed by us (not set when it ends by itself).
	private enum EndIntent {
		case none
		case userDisconnect
		case reconnect(allowWake: Bool)
		/// Quit or relaunch: whoever closes the session is waiting for it to be over.
		case handover
	}

	private struct ConnectFailure: LocalizedError {
		var errorDescription: String?
		init(_ text: String) { errorDescription = text }
	}

	private var connectTask: Task<Void, Never>?
	private var observers: Set<AnyCancellable> = []
	private var endIntent = EndIntent.none
	private var endWaiters: [CheckedContinuation<Void, Never>] = []
	private let resumeStore = ResumeStore()
	/// Every access to the resume file goes through here, so a late heartbeat can never bring
	/// back a record that was removed after it.
	private let resumeQueue = DispatchQueue(label: "playstream.resume", qos: .utility)
	private var lastHeartbeat = Date.distantPast
	private var didCheckResume = false
	private var lastHostID: String?
	private var isRelaunching = false
	private var idleWait: IdleWait?
	private var lastRelaunch: [String: Any]?
	private var debugControl: DebugControl?
	/// The flight recorder of the session that ended last, kept for a while so that what led up
	/// to a dropped session can still be written out (`psctl capture`).
	private var retiredRecorder: (tee: StreamCaptureTee, until: Date)?
	private static let retiredRecorderSeconds: TimeInterval = 600
	private var settingsFingerprint = ""
	private var housekeeping: Timer?

	init() {
		// One owner for the core's process-wide log callback: BridgeLog (pairing reads the lines
		// to explain failures). Everything is mirrored into ~/Library/Logs/PlayStream/core.log.
		CoreLog.install(ownCoreCallback: false)
		BridgeLog.shared.install()
		_ = BridgeLog.shared.addObserver { line in
			CoreLog.record(level: line.level, message: line.message)
		}
		CoreLog.note("PlayStream \(BuildInfo.summary), pid \(ProcessInfo.processInfo.processIdentifier)")
		store.track(discovery)
		// Leave a trail of what discovery sees, so a "console not found" report can be diagnosed.
		discovery.$hosts
			.map { hosts in hosts.map { "\($0.name) \($0.address) \($0.state.rawValue)" }.sorted() }
			.removeDuplicates()
			.sink { CoreLog.note("Discovery: \($0.isEmpty ? "no consoles" : $0.joined(separator: ", "))") }
			.store(in: &observers)
		discovery.start()
		input.diagnosticHandler = { CoreLog.note($0) }
		input.start()
		input.installKeyboardMonitor()

		debugControl = DebugControl(model: self)
		applyControllerSettings()
		// Settings take effect immediately, also in the middle of a session. Delivered on the
		// main queue (not the run loop's default mode), so they also apply while a slider in the
		// settings panel is being dragged.
		NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
			.receive(on: DispatchQueue.main)
			.sink { [weak self] _ in self?.applyControllerSettings() }
			.store(in: &observers)
		// That notification only fires for changes made inside this process. A value written from
		// outside (`defaults write`) arrives silently, so look for changes once a second as well.
		// The same timer keeps the resume record fresh while a session is streaming.
		let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.housekeepingTick() }
		}
		RunLoop.main.add(timer, forMode: .common)
		housekeeping = timer
	}

	// MARK: Settings

	/// Pushes the current settings to the controller, the running stream and the control
	/// channel. Cheap and idempotent. Returns what changed in the stream, in words.
	@discardableResult
	func applyControllerSettings() -> [String] {
		settingsFingerprint = SettingsCatalog.fingerprint(.standard)
		input.lightBrightness = Float(settings.lightBrightness)
		input.playerLEDsEnabled = settings.playerLEDs
		input.rumbleGain = Float(settings.rumbleStrength)
		input.hapticsRumbleGain = Float(settings.rumbleStrength)
		input.motionEnabled = settings.motionSensors
		if input.keyboardEnabled != settings.keyboardFallback { input.keyboardEnabled = settings.keyboardFallback }
		var changes = stream?.applyLiveSettings() ?? []
		if let change = debugControl?.setEnabled(settings.controlChannel) { changes.append(change) }
		return changes
	}

	/// Settings were written through the control channel: apply them now and say what happened.
	func settingsChangedByControlChannel(_ keys: [String]) -> [String] {
		var applied = applyControllerSettings()
		for key in keys {
			if key.hasPrefix("controller.") { applied.append("\(key) sent to the controller") }
			if key == "stream.statsLevel" { applied.append("stats overlay level \(settings.statsLevel)") }
			if key == "debug.hitchNotes" { applied.append("hitch notes \(settings.hitchNotes ? "on" : "off")") }
		}
		// Views that show settings re-read them.
		settings.objectWillChange.send()
		return applied
	}

	private func housekeepingTick() {
		if SettingsCatalog.fingerprint(.standard) != settingsFingerprint {
			let changes = applyControllerSettings()
			CoreLog.note("Settings change picked up by the periodic check" + (changes.isEmpty ? "" : ": " + changes.joined(separator: ", ")))
			settings.objectWillChange.send()
		}
		if let stream, stream.phase == .streaming, !isRelaunching, Date().timeIntervalSince(lastHeartbeat) >= 20 {
			saveResumeRecord(for: stream, reason: .streaming)
		}
		if let retired = retiredRecorder, Date() > retired.until { retiredRecorder = nil }
	}

	// MARK: Connecting

	func connect(to entry: ConsoleEntry) {
		guard stream == nil, connectingHostID == nil, !isRelaunching else { return }
		guard entry.registered != nil else { return }
		begin(ConnectPlan(hostID: entry.id, origin: .user, allowWake: true))
	}

	private func begin(_ plan: ConnectPlan, after delay: TimeInterval = 0, message: String? = nil) {
		connectTask?.cancel()
		lastError = nil
		let name = consoleName(plan.hostID)
		connectingHostID = plan.hostID
		connectProgress = message ?? "Connecting…"
		// Anything but a first attempt the owner asked for is the app getting a session back by
		// itself: show that instead of the console list.
		if plan.origin != .user || plan.attempt > 1 {
			reconnectStatus = ReconnectStatus(consoleName: name, message: message ?? "Reconnecting to \(name)…")
		}
		connectTask = Task { [weak self] in await self?.run(plan, delay: delay) }
	}

	private func consoleName(_ hostID: String) -> String {
		let name = store.host(id: hostID)?.nickname ?? ""
		return name.isEmpty ? "the console" : name
	}

	private func progress(_ text: String) {
		connectProgress = text
		if reconnectStatus != nil { reconnectStatus?.message = text }
	}

	private func run(_ plan: ConnectPlan, delay: TimeInterval) async {
		do {
			if delay > 0 {
				// Use the wait to find the console again (discovery is off while streaming).
				discovery.start()
				try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
			}
			guard let host = store.host(id: plan.hostID) else {
				throw ConnectFailure("This console is no longer paired with this Mac.")
			}
			guard let account = store.account else {
				throw ConnectFailure("Sign in to PSN first (person icon in the toolbar). The console only accepts sessions from the account it was paired with.")
			}
			let name = consoleName(host.id)
			let connecting = plan.origin == .user && plan.attempt == 1 ? "Connecting…" : "Reconnecting to \(name)…"
			progress(connecting)

			discovery.start()
			var found = discovery.host(id: host.id)
			if found == nil, plan.origin != .user {
				// Just launched, or discovery was off while streaming: give it a moment to see
				// the console, so we know its address and whether it is awake.
				progress("Looking for \(name)…")
				found = await discovery.waitForHost(timeout: 8) { $0.id == host.id }
				try Task.checkCancellation()
			}
			guard var address = found?.address ?? host.lastKnownAddress else {
				throw ConnectFailure("\(name) was not found on this network.")
			}
			if found?.state == .standby {
				// Waking a console is the owner's call: a resumed session never does it.
				guard plan.allowWake else {
					throw ConnectFailure("\(name) is in rest mode, so the session was not resumed. Connect to wake it.")
				}
				progress("Waking console…")
				let ready = try await discovery.wakeAndWaitUntilReady(host, timeout: 75)
				address = ready.address
				// The console answers discovery a little before it accepts sessions.
				try await Task.sleep(nanoseconds: 2_000_000_000)
			}
			try Task.checkCancellation()
			progress(connecting)
			var configuration = SessionConfiguration(
				host: host,
				address: address,
				account: account,
				profile: settings.profile(isPS5: host.isPS5),
				enableDualSense: settings.dualSenseFeatures && host.isPS5
			)
			configuration.startBitrateHint = SessionConfiguration.StartBitrateHint(rawValue: settings.startBitrateHint) ?? .off
			let controller = StreamController(configuration: configuration, settings: settings, input: input)
			controller.onStreaming = { [weak self, weak controller] in
				guard let self, let controller, self.stream === controller else { return }
				self.sessionIsStreaming(controller, plan: plan)
			}
			controller.onEnded = { [weak self, weak controller] reason, isError in
				guard let self, let controller, self.stream === controller else { return }
				self.sessionEnded(controller, plan: plan, reason: reason, isError: isError)
			}
			try controller.start()
			if plan.origin != .user || plan.attempt > 1 {
				CoreLog.note("Connect (\(plan.origin.rawValue), attempt \(plan.attempt)): session opened with \(name) at \(address)")
			}
			lastHostID = host.id
			endIntent = .none
			stream = controller
			connectingHostID = nil
			connectProgress = nil
			reconnectStatus = nil
			// No broadcasts while playing: discovery has done its job and the air should be quiet.
			discovery.stop()
		} catch is CancellationError {
			connectFinished(plan, failure: nil)
		} catch {
			connectFinished(plan, failure: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
		}
	}

	/// A connection attempt ended without a session (cancelled or failed before it started).
	private func connectFinished(_ plan: ConnectPlan, failure: String?) {
		// A relaunch cancels the attempt on purpose and has already decided what the next
		// launch should do.
		guard !isRelaunching else { return }
		connectingHostID = nil
		connectProgress = nil
		reconnectStatus = nil
		clearResumeRecord()
		if let failure {
			lastError = plan.origin == .resume ? "Did not reconnect: \(failure)" : failure
			CoreLog.note("Connect (\(plan.origin.rawValue), attempt \(plan.attempt)) failed: \(failure)")
		} else if plan.origin != .user {
			CoreLog.note("Connect (\(plan.origin.rawValue)) cancelled")
		}
		if stream == nil { discovery.start() }
	}

	func cancelConnect() {
		connectTask?.cancel()
	}

	/// The flight recorder `psctl capture` works on: the running session's, or for a few
	/// minutes after a session ended, that session's.
	var flightRecorder: StreamCaptureTee? { stream?.captureTee ?? retiredRecorder?.tee }

	private func sessionIsStreaming(_ controller: StreamController, plan: ConnectPlan) {
		// The new session's recorder takes over; the old one's memory is released.
		retiredRecorder = nil
		if plan.origin != .user || plan.attempt > 1 {
			CoreLog.note("Connect (\(plan.origin.rawValue)): streaming again after \(plan.attempt) attempt\(plan.attempt == 1 ? "" : "s")")
		}
		saveResumeRecord(for: controller, reason: .streaming)
	}

	private func sessionEnded(_ controller: StreamController, plan: ConnectPlan, reason: String, isError: Bool) {
		let intent = endIntent
		endIntent = .none
		if case .handover = intent {
			// Quit or relaunch is waiting for exactly this and decides what happens next. The
			// (ended) stream stays on screen: the app is on its way out, and switching to the
			// console list or leaving full screen now would only be a flicker.
			resumeEndWaiters()
			return
		}
		stream = nil
		if controller.everStreamed {
			retiredRecorder = (controller.captureTee, Date().addingTimeInterval(AppModel.retiredRecorderSeconds))
			if isError, case .none = intent {
				CoreLog.note("The flight recorder keeps the end of this session for \(Int(AppModel.retiredRecorderSeconds / 60)) minutes: `psctl capture` writes it out")
			}
		}

		switch intent {
		case .handover:
			return
		case .reconnect(let allowWake):
			let name = consoleName(plan.hostID)
			begin(ConnectPlan(hostID: plan.hostID, origin: .reconnect, allowWake: allowWake),
			      after: ResumePolicy.settleSeconds, message: "Reconnecting to \(name)…")
			return
		case .userDisconnect:
			clearResumeRecord()
			discovery.start()
			return
		case .none:
			break
		}

		// The session ended by itself. Right after a disconnect the console refuses a new session
		// for a few seconds ("Remote Play already in use"); that passes, so wait and try again
		// instead of making the owner click Connect until it works.
		if isError, !controller.everStreamed, ReconnectPolicy.isConsoleBusy(reason), !isRelaunching {
			if let wait = ReconnectPolicy.delay(afterBusyAttempt: plan.attempt) {
				var next = plan
				next.attempt += 1
				let name = consoleName(plan.hostID)
				CoreLog.note("Connect (\(plan.origin.rawValue)): console still holds the previous session, attempt \(next.attempt) in \(Int(wait)) s")
				begin(next, after: wait, message: "\(name) is still closing the previous session. Trying again in \(Int(wait)) s…")
				return
			}
			CoreLog.note("Connect (\(plan.origin.rawValue)): console still busy after \(plan.attempt) attempts, giving up")
		}
		clearResumeRecord()
		discovery.start()
		if isError { lastError = "Session ended: \(reason)" }
	}

	func wake(_ entry: ConsoleEntry) {
		guard let host = entry.registered else { return }
		do {
			try PSPairing.wake(host: host, address: entry.address)
		} catch {
			lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}

	/// The owner (or `psctl disconnect`) ends the session: nothing is resumed afterwards.
	func disconnect() {
		if let stream {
			endIntent = .userDisconnect
			stream.stop()
		} else {
			cancelConnect()
		}
	}

	/// `psctl reconnect`: close the session and open it again with the current settings.
	func reconnect(allowWake: Bool) throws -> [String: Any] {
		guard !isRelaunching else { throw ControlError("the app is relaunching") }
		if let stream {
			let name = stream.consoleName
			CoreLog.note("Reconnect requested via control channel")
			endIntent = .reconnect(allowWake: allowWake)
			stream.stop()
			return ["reconnecting": true, "console": name, "note": "the session is closing; the new one opens about \(Int(ResumePolicy.settleSeconds)) s later (the console needs that long)"]
		}
		guard connectingHostID == nil else { throw ControlError("already connecting") }
		guard let host = lastHostID.flatMap({ store.host(id: $0) }) ?? (store.hosts.count == 1 ? store.hosts.first : nil) else {
			throw ControlError("no session is running and it is not clear which console to connect to")
		}
		CoreLog.note("Connect requested via control channel: \(host.nickname)")
		begin(ConnectPlan(hostID: host.id, origin: .reconnect, allowWake: allowWake))
		return ["connecting": true, "console": host.nickname]
	}

	/// Asks the session to close and waits until it has (or `timeout` passed).
	private func endSession(intent: EndIntent, timeout: TimeInterval) async {
		guard let stream, stream.phase != .ended else { return }
		endIntent = intent
		stream.stop()
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			endWaiters.append(continuation)
			DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
				MainActor.assumeIsolated { self?.resumeEndWaiters() }
			}
		}
	}

	private func resumeEndWaiters() {
		let waiters = endWaiters
		endWaiters = []
		for waiter in waiters { waiter.resume() }
	}

	/// Lets a running recording close its file, for at most `timeout` seconds.
	private func finishRecording(of stream: StreamController, timeout: TimeInterval) async {
		guard stream.recorder.isRecording else { return }
		CoreLog.note("Finishing the recording before the session closes")
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			var resumed = false
			let finish = {
				guard !resumed else { return }
				resumed = true
				continuation.resume()
			}
			stream.recorder.stop { _ in finish() } // completion runs on the main thread
			DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish() }
		}
	}

	// MARK: Resume at launch

	/// The stream window, for reading and restoring its full-screen state.
	static var streamWindow: NSWindow? {
		NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true } ?? NSApp.keyWindow
	}

	private var isFullScreen: Bool {
		AppModel.streamWindow?.styleMask.contains(.fullScreen) ?? false
	}

	private func saveResumeRecord(for stream: StreamController, reason: ResumeRecord.Reason, sessionEndedAt: Date? = nil, wait: Bool = false) {
		saveResumeRecord(hostID: stream.configuration.host.id, name: stream.consoleName, reason: reason, sessionEndedAt: sessionEndedAt, wait: wait)
	}

	private func saveResumeRecord(hostID: String, name: String, reason: ResumeRecord.Reason, sessionEndedAt: Date? = nil, fullScreen: Bool? = nil, wait: Bool = false) {
		let record = ResumeRecord(hostID: hostID, hostName: name, reason: reason, wasFullScreen: fullScreen ?? isFullScreen, sessionEndedAt: sessionEndedAt, build: BuildInfo.gitCommit)
		lastHeartbeat = Date()
		let store = resumeStore
		if wait {
			resumeQueue.sync { store.save(record) }
		} else {
			resumeQueue.async { store.save(record) }
		}
	}

	private func clearResumeRecord() {
		let store = resumeStore
		resumeQueue.async { store.clear() }
	}

	/// Called once when the window is up: reconnect to the console the previous run was
	/// streaming from, if that run ended in a way that calls for it (see `ResumePolicy`).
	func resumeIfNeeded() {
		guard !didCheckResume else { return }
		didCheckResume = true
		let resume = resumeStore
		// The record is used once: whatever happens next, a launch never loops on it.
		let record: ResumeRecord? = resumeQueue.sync {
			let record = resume.load()
			resume.clear()
			return record
		}
		let decision = ResumePolicy.decide(
			record: record,
			enabled: settings.autoReconnect,
			windowSeconds: SettingsCatalog.double("resume.windowSeconds", in: .standard),
			hasAccount: self.store.account != nil,
			hostIsRegistered: record.map { self.store.host(id: $0.hostID) != nil } ?? false,
			suppressed: NSEvent.modifierFlags.contains(.option)
		)
		switch decision {
		case .resume(let record, let delay):
			guard stream == nil, connectingHostID == nil else { return }
			CoreLog.note("Resume: previous run (\(record.build ?? "?")) left a session with \(record.hostName) (\(record.reason.rawValue)); reconnecting\(delay > 0 ? String(format: " in %.1f s", delay) : "")")
			fullScreenOverride = record.wasFullScreen
			begin(ConnectPlan(hostID: record.hostID, origin: .resume, allowWake: false), after: delay, message: "Reconnecting to \(record.hostName)…")
		case .skip(let reason, let tellUser):
			guard record != nil else { return }
			CoreLog.note("Resume: not reconnecting: \(reason)")
			if tellUser { lastError = "Did not reconnect: \(reason)." }
		}
	}

	// MARK: Relaunch

	/// `psctl relaunch`: close the session cleanly, start the given bundle (default: this one)
	/// and exit. The new instance resumes the session by itself. With `whenIdle`, waits until
	/// the player has not touched the controller for a few seconds first.
	func requestRelaunch(_ request: ControlRouter.RelaunchRequest) throws -> [String: Any] {
		if request.cancel {
			guard pendingRelaunch != nil else { throw ControlError("no relaunch is waiting") }
			idleWait?.cancel()
			idleWait = nil
			pendingRelaunch = nil
			CoreLog.note("Relaunch: cancelled")
			return ["cancelled": true]
		}
		guard !isRelaunching else { throw ControlError("the app is already relaunching") }
		guard pendingRelaunch == nil else {
			throw ControlError("a relaunch is already waiting for the controller to go idle; `psctl relaunch cancel` stops it")
		}
		// Refuse anything that is not a complete build of this app before touching the session.
		let current = Bundle.main.bundleURL.standardizedFileURL
		let target = try Relauncher.inspectBundle(
			at: request.bundlePath.map { URL(fileURLWithPath: $0) } ?? current,
			expectedIdentifier: Bundle.main.bundleIdentifier)
		let build = "\(target.version) \(target.gitCommit ?? "unknown commit") built \(target.buildTime ?? "at an unknown time")"
		var response: [String: Any] = [
			"scheduled": true,
			"bundle": target.url.path,
			"newBuild": ["version": target.version, "gitCommit": target.gitCommit ?? NSNull(), "buildTime": target.buildTime ?? NSNull()] as [String: Any],
			"runningBuild": BuildInfo.json,
			"willResume": stream != nil || connectingHostID != nil,
		]

		if request.whenIdle, let stream, stream.phase == .streaming {
			let monitor = stream.inputActivity
			pendingRelaunch = PendingRelaunch(
				bundlePath: target.url.path, build: build, idleSeconds: request.idleSeconds,
				deadline: Date().addingTimeInterval(request.timeoutSeconds), relaunchOnTimeout: request.relaunchOnTimeout)
			CoreLog.note("Relaunch: waiting for \(request.idleSeconds) s without controller input (at most \(Int(request.timeoutSeconds)) s) before starting \(target.url.path) [\(build)]")
			idleWait = IdleWait(
				requiredIdleSeconds: request.idleSeconds, timeoutSeconds: request.timeoutSeconds, queue: .main,
				idleSeconds: { monitor.idleSeconds }
			) { [weak self] outcome in
				MainActor.assumeIsolated { self?.idleWaitFinished(outcome, target: target, build: build) }
			}
			response["waitingForIdle"] = true
			response["idleSeconds"] = request.idleSeconds
			response["timeoutSeconds"] = request.timeoutSeconds
			response["onTimeout"] = request.relaunchOnTimeout ? "relaunch" : "cancel"
			return response
		}
		response["waitingForIdle"] = false
		// Answer first, then go.
		Task { [weak self] in
			try? await Task.sleep(nanoseconds: 150_000_000)
			await self?.performRelaunch(target, build: build)
		}
		return response
	}

	private func idleWaitFinished(_ outcome: IdleWait.Outcome, target: Relauncher.BundleInfo, build: String) {
		idleWait = nil
		guard let pending = pendingRelaunch else { return }
		pendingRelaunch = nil
		switch outcome {
		case .idle(let waited):
			CoreLog.note(String(format: "Relaunch: controller idle for %.1f s after waiting %.1f s", pending.idleSeconds, waited))
			Task { [weak self] in await self?.performRelaunch(target, build: build) }
		case .timedOut where pending.relaunchOnTimeout:
			CoreLog.note("Relaunch: the controller never went idle; relaunching anyway as asked")
			Task { [weak self] in await self?.performRelaunch(target, build: build) }
		case .timedOut:
			CoreLog.note("Relaunch: the controller never went idle for \(pending.idleSeconds) s; not relaunching")
			lastRelaunch = ["bundle": pending.bundlePath, "outcome": "timed out waiting for idle", "at": JSONValue.string(from: Date())]
		case .cancelled:
			break
		}
	}

	private func performRelaunch(_ target: Relauncher.BundleInfo, build: String) async {
		guard !isRelaunching else { return }
		isRelaunching = true
		let current = Bundle.main.bundleURL.standardizedFileURL
		let fullScreen = isFullScreen

		// What the next launch should come back to: the running session, or the one being opened.
		var resumeHost: (id: String, name: String)?
		if let stream {
			resumeHost = (stream.configuration.host.id, stream.consoleName)
		} else if let connecting = connectingHostID {
			resumeHost = (connecting, consoleName(connecting))
		}
		CoreLog.note("Relaunch: starting \(target.url.path) [\(build)]; " + (resumeHost.map { "the session with \($0.name) resumes there" } ?? "no session to resume"))
		if let resumeHost {
			saveResumeRecord(hostID: resumeHost.id, name: resumeHost.name, reason: .relaunch, fullScreen: fullScreen, wait: true)
		}
		connectTask?.cancel()
		if let stream {
			await finishRecording(of: stream, timeout: 8)
			await endSession(intent: .handover, timeout: 3)
			if let resumeHost {
				// Now the console starts counting; the new instance waits out the rest.
				saveResumeRecord(hostID: resumeHost.id, name: resumeHost.name, reason: .relaunch, sessionEndedAt: Date(), fullScreen: fullScreen, wait: true)
			}
		}
		debugControl?.stop()

		let plan = Relauncher.Plan(
			bundle: target.url,
			fallbackBundle: target.url == current ? nil : current,
			logURL: CoreLog.defaultDirectory.appendingPathComponent("relaunch.log"))
		do {
			let helper = try Relauncher.spawn(plan)
			CoreLog.note("Relaunch: session closed, helper \(helper) starts the new instance once this one (pid \(ProcessInfo.processInfo.processIdentifier)) has exited")
		} catch {
			// Could not hand over: stay, and get the session back ourselves.
			CoreLog.note("Relaunch failed: \(error)")
			isRelaunching = false
			lastRelaunch = ["bundle": target.url.path, "outcome": "failed: \(error)", "at": JSONValue.string(from: Date())]
			lastError = "Relaunch failed: \(error)"
			endIntent = .none
			stream = nil
			clearResumeRecord()
			_ = debugControl?.setEnabled(settings.controlChannel)
			if let resumeHost {
				begin(ConnectPlan(hostID: resumeHost.id, origin: .reconnect, allowWake: false), after: ResumePolicy.settleSeconds)
			}
			return
		}
		CoreLog.flush()
		NSApp.terminate(nil)
	}

	// MARK: Quitting

	/// True when quitting right now would cut a session or a recording off.
	var needsGracefulTermination: Bool { !isRelaunching && stream != nil && stream?.phase != .ended }

	/// Quit was requested while a session is open: remember it for the next launch, let a
	/// recording finish and say goodbye to the console properly, so that it frees the session at
	/// once instead of answering "already in use" to whoever connects next.
	func prepareForTermination() async {
		idleWait?.cancel()
		idleWait = nil
		pendingRelaunch = nil
		connectTask?.cancel()
		guard let stream else { return }
		if stream.phase == .streaming {
			saveResumeRecord(for: stream, reason: .quit, sessionEndedAt: Date(), wait: true)
			CoreLog.note("Quit while streaming: launching again within \(Int(SettingsCatalog.double("resume.windowSeconds", in: .standard))) s resumes the session")
		} else {
			clearResumeRecord()
		}
		await finishRecording(of: stream, timeout: 8)
		await endSession(intent: .handover, timeout: 2.5)
		debugControl?.stop()
		CoreLog.flush()
	}

	func shutdown() {
		stream?.stop()
		housekeeping?.invalidate()
		debugControl?.stop()
		input.stop()
		discovery.stop()
		resumeQueue.sync {} // let a pending write of the resume record finish
		CoreLog.flush()
	}

	// MARK: Control channel views of the state

	/// `psctl status`.
	func statusJSON() -> [String: Any] {
		var session: [String: Any]
		if let stream {
			session = stream.statusJSON
		} else {
			session = ["running": false, "phase": connectingHostID != nil ? "connecting" : "idle"]
			if let connecting = connectingHostID { session["console"] = ["name": consoleName(connecting), "id": connecting] }
		}
		session["progress"] = reconnectStatus?.message ?? connectProgress ?? NSNull()
		var app = BuildInfo.json
		app["launchedAt"] = JSONValue.string(from: launchedAt)
		// Things that are set up in a way worth knowing about when reading numbers.
		var notices: [String] = []
		let defaults = UserDefaults.standard
		let keyframeSeconds = SettingsCatalog.double("debug.flightRecorderKeyframeSeconds", in: defaults)
		if keyframeSeconds > 0 { notices.append("a keyframe is requested every \(Int(keyframeSeconds)) s for the flight recorder (`psctl capture disarm` stops that)") }
		if SettingsCatalog.double("debug.flightRecorderSeconds", in: defaults) <= 0 { notices.append("the flight recorder is off (debug.flightRecorderSeconds is 0)") }
		if !settings.hitchNotes { notices.append("hitch notes are off (debug.hitchNotes)") }
		if stream?.recorder.isRecording == true { notices.append("a movie recording is running") }
		if stream?.captureTee.isCapturing == true { notices.append("a stream capture to disk is running (`psctl capture stop` ends it)") }
		if let stream, stream.videoDebug == nil { notices.append("the video pipeline of this build has no debug control: tunables, tune, trace and frames are unavailable") }
		return [
			"notices": notices,
			"app": app,
			"uptimeSeconds": (Date().timeIntervalSince(launchedAt) * 10).rounded() / 10,
			"session": session,
			"controlSocket": ControlServer.defaultSocketURL.path,
			"controller": input.activeController?.name ?? NSNull(),
			"controllerIdleSeconds": stream.map { ($0.inputActivity.idleSeconds * 10).rounded() / 10 } ?? NSNull(),
			"fullScreen": isFullScreen,
			"psnAccount": store.account != nil,
			"pairedConsoles": store.hosts.map { ["name": $0.nickname, "id": $0.id, "address": $0.lastKnownAddress ?? NSNull()] as [String: Any] },
			"discovered": discovery.hosts.map { ["name": $0.name, "id": $0.id, "address": $0.address, "state": $0.state.rawValue] },
			"pendingRelaunch": pendingRelaunch.map { pending -> Any in
				[
					"bundle": pending.bundlePath, "build": pending.build, "idleSeconds": pending.idleSeconds,
					"secondsLeft": max(0, pending.deadline.timeIntervalSinceNow).rounded(),
					"onTimeout": pending.relaunchOnTimeout ? "relaunch" : "cancel",
					"requestedAt": JSONValue.string(from: pending.requestedAt),
				] as [String: Any]
			} ?? NSNull(),
			"lastRelaunch": lastRelaunch ?? NSNull(),
			"lastError": lastError ?? NSNull(),
			"autoReconnect": settings.autoReconnect,
		]
	}

	/// `psctl stats`.
	func statsJSON() -> [String: Any] {
		guard let stream else {
			return ["session": NSNull(), "note": "no session is running"]
		}
		return stream.statsJSON
	}
}
