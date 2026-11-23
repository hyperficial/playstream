import Foundation
import PSAudio
import PSContracts
import PSCore
import PSInput
import PSRecording
import PSVideo
import SwiftUI

/// Owns one running stream: the session plus the video, audio, input and recording pipelines
/// wired to it.
@MainActor
final class StreamController: ObservableObject {
	enum Phase: Equatable {
		case connecting
		case streaming
		case ended
	}

	struct LiveStats {
		var video = VideoStats()
		var audio: AudioPipelineStats?
		var session = SessionStats()
	}

	let configuration: SessionConfiguration
	let video: VideoPipeline
	let audio: AudioPipeline
	let recorder = StreamRecorder()
	/// Flight recorder: sits between the session and the video pipeline and keeps the last
	/// seconds of the encoded stream for `psctl capture`.
	let captureTee = StreamCaptureTee()
	/// Sees the controller snapshots on their way to the session, to know when the player pauses.
	let inputActivity = ControllerActivityMonitor()
	let startedAt = Date()
	/// When the stream came up (nil while connecting).
	private(set) var streamingSince: Date?
	/// The session reached the streaming phase at some point.
	var everStreamed: Bool { streamingSince != nil }

	@Published private(set) var phase: Phase = .connecting
	@Published private(set) var liveStats = LiveStats()
	/// Recent samples for the overlay graphs, oldest first.
	@Published private(set) var history: [StatsSample] = []
	static let historyLength = 160
	private static let statsInterval: TimeInterval = 0.25
	@Published private(set) var cantDisplay = false
	@Published var pinRequest: PINRequest?
	@Published private(set) var consoleName: String

	struct PINRequest: Identifiable, Equatable {
		let id = UUID()
		var incorrect: Bool
	}

	/// Called once, on the main thread, when the session is over.
	var onEnded: ((_ reason: String, _ isError: Bool) -> Void)?
	/// Called on the main thread when the stream is up.
	var onStreaming: (() -> Void)?

	private let session: StreamSession
	private let input: ControllerInput
	private let settings: AppSettings
	private var statsTimer: Timer?
	private var activity: NSObjectProtocol?
	private var hitches = HitchDetector()

	init(configuration: SessionConfiguration, settings: AppSettings, input: ControllerInput) {
		self.configuration = configuration
		self.settings = settings
		self.input = input
		self.consoleName = configuration.host.nickname
		self.session = StreamSession(configuration: configuration)
		let wanted = Self.videoConfiguration(for: settings)
		self.video = VideoPipeline(displayMode: wanted.display, pacingMode: wanted.pacing)
		self.video.upscaler = wanted.upscaler
		self.video.frameGeneration = wanted.frameGeneration
		self.video.upscalerSharpness = settings.upscalerSharpness
		self.video.frameGenerationMaxAddedLatencyMs = settings.frameGenerationMaxDelay
		self.video.frameGenerationMethod = settings.frameGenerationMethod == 1 ? .interpolate : .extrapolate
		// Adaptive jitter buffer: 40 ms on a clean link, growing by itself when the link stalls.
		self.audio = AudioPipeline(configuration: AudioPipelineConfiguration())
	}

	func start() throws {
		audio.volume = Float(settings.volume)

		video.keyframeRequester = session
		video.encodedTap = recorder
		audio.pcmTap = recorder
		recorder.keyframeRequester = session
		if configuration.profile.codec.isHDR {
			// Safety net so recordings are tagged HDR even if the stream's own tags are missing.
			recorder.options.fallbackColorTags = .hdr10
		}

		// The video stream passes through the flight recorder on its way to the pipeline. The
		// recorder hands every buffer on first and copies it afterwards (see StreamCaptureTee).
		captureTee.downstream = video
		captureTee.keyframeRequester = session
		captureTee.logHandler = { CoreLog.note($0) }
		let build = BuildInfo.summary
		let console = configuration.host.nickname
		captureTee.notesProvider = {
			// Runs on the capture queue: only thread-safe sources.
			["settings": SettingsCatalog.snapshot(.standard), "build": build, "console": console]
		}
		applyDebugSettings()

		// Deliberately not wiring session.onVideoLoss to recorder.noteVideoLoss(): the core only
		// delivers frames whose references we hold, so the recorded bitstream stays decodable
		// after a loss, and forcing a keyframe on every lost frame would spike the bitrate on
		// exactly the links that are already struggling.
		session.videoSink = captureTee
		session.audioSink = audio
		session.hapticsSink = input
		session.feedbackSink = input
		session.onEvent = { [weak self] event in
			MainActor.assumeIsolated { self?.handle(event) }
		}

		input.hapticsToRumbleEnabled = settings.hapticsAsRumble && configuration.enableDualSense

		applyTunableOverrides()
		try session.start()

		// Controller snapshots go to the session through the activity monitor, which only looks.
		inputActivity.downstream = session
		input.receiver = inputActivity
		// Keep the display awake and tell the scheduler this is latency-sensitive work.
		activity = ProcessInfo.processInfo.beginActivity(
			options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated, .latencyCritical],
			reason: "Streaming from \(configuration.host.nickname)"
		)
		statsTimer = Timer.scheduledTimer(withTimeInterval: Self.statsInterval, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshStats() }
		}
		if captureTee.keyframeIntervalSeconds > 0 {
			CoreLog.note("Flight recorder: requesting a keyframe every \(Int(captureTee.keyframeIntervalSeconds)) s (debug.flightRecorderKeyframeSeconds); set it to 0 to stop")
		}
		CoreLog.note("Session started: \(configuration.profile.width)x\(configuration.profile.height)@\(configuration.profile.fps) \(configuration.profile.codec) \(configuration.profile.bitrateKbps) kbit/s, renderer \(video.displayMode.rawValue), start bitrate hint \(configuration.startBitrateHint)")
	}

	func stop() {
		session.stop()
	}

	/// What the video pipeline should be doing for the current settings. Upscaling and frame
	/// generation only exist on the Metal path, and frame generation also needs pacing, so
	/// turning either on implies those.
	static func videoConfiguration(for settings: AppSettings) -> (display: VideoDisplayMode, pacing: VideoPacingMode, upscaler: VideoUpscaler, frameGeneration: VideoFrameGeneration) {
		let upscaler: VideoUpscaler = [.off, .bicubic, .metalFXSpatial, .fsr1][min(max(settings.upscaler, 0), 3)]
		let frameGeneration: VideoFrameGeneration = [.off, .to60, .to120][min(max(settings.frameGeneration, 0), 2)]
		let needsMetal = settings.lowLatencyRenderer || upscaler != .off || frameGeneration != .off
		let pacing: VideoPacingMode = (settings.framePacing || frameGeneration != .off) ? .adaptive : .off
		return (needsMetal ? .metal : .sampleBufferLayer, pacing, upscaler, frameGeneration)
	}

	/// Settings that can change in the middle of a session. Returns what was changed, in words
	/// (empty when everything already matched), so a caller can report it.
	@discardableResult
	func applyLiveSettings() -> [String] {
		guard phase != .ended else { return [] }
		let wanted = Self.videoConfiguration(for: settings)
		var changes: [String] = []
		if video.displayMode != wanted.display {
			video.displayMode = wanted.display
			changes.append("renderer \(wanted.display.rawValue)")
		}
		if video.pacingMode != wanted.pacing {
			video.pacingMode = wanted.pacing
			changes.append("pacing \(wanted.pacing.rawValue)")
		}
		if video.upscaler != wanted.upscaler {
			video.upscaler = wanted.upscaler
			changes.append("upscaler \(wanted.upscaler.rawValue)")
		}
		if video.frameGeneration != wanted.frameGeneration {
			video.frameGeneration = wanted.frameGeneration
			changes.append("frame generation \(wanted.frameGeneration.rawValue)")
		}
		if video.upscalerSharpness != settings.upscalerSharpness {
			video.upscalerSharpness = settings.upscalerSharpness
			changes.append(String(format: "sharpness %.2f", settings.upscalerSharpness))
		}
		let method: VideoFrameGenerationMethod = settings.frameGenerationMethod == 1 ? .interpolate : .extrapolate
		if video.frameGenerationMethod != method {
			video.frameGenerationMethod = method
			changes.append("frame generation method \(method)")
		}
		if video.frameGenerationMaxAddedLatencyMs != settings.frameGenerationMaxDelay {
			video.frameGenerationMaxAddedLatencyMs = settings.frameGenerationMaxDelay
			changes.append("frame generation budget \(Int(settings.frameGenerationMaxDelay)) ms")
		}
		if !changes.isEmpty { CoreLog.note("Video settings changed: " + changes.joined(separator: ", ")) }

		// The volume slider in the stream view sets the pipeline directly; a value written to
		// the setting from elsewhere (the control channel) is picked up here.
		let wantedVolume = Float(min(max(settings.volume, 0), 1))
		if abs(audio.volume - wantedVolume) > 0.001 {
			audio.volume = wantedVolume
			changes.append(String(format: "volume %.2f", wantedVolume))
		}
		changes += applyDebugSettings()
		return changes
	}

	/// Flight recorder limits and hitch-note threshold, from the settings. Returns what changed.
	@discardableResult
	private func applyDebugSettings() -> [String] {
		let defaults = UserDefaults.standard
		var changes: [String] = []
		let megabytes = SettingsCatalog.int("debug.flightRecorderMegabytes", in: defaults)
		let limits = StreamCaptureTee.Limits(seconds: SettingsCatalog.double("debug.flightRecorderSeconds", in: defaults), bytes: megabytes * 1024 * 1024)
		if captureTee.limits != limits {
			captureTee.limits = limits
			changes.append(limits.seconds > 0 ? "flight recorder \(Int(limits.seconds)) s / \(megabytes) MiB" : "flight recorder off")
		}
		let keyframeInterval = SettingsCatalog.double("debug.flightRecorderKeyframeSeconds", in: defaults)
		if abs(captureTee.keyframeIntervalSeconds - (keyframeInterval > 0 ? max(0.5, keyframeInterval) : 0)) > 0.001 {
			captureTee.keyframeIntervalSeconds = keyframeInterval
			changes.append(keyframeInterval > 0 ? "flight recorder keyframe every \(Int(keyframeInterval)) s" : "flight recorder keyframe requests off")
		}
		hitches.configuration.longFrameFactor = SettingsCatalog.double("debug.hitchFrameFactor", in: defaults)
		return changes
	}

	// MARK: Debugging (control channel)

	/// The pipeline's debug interface, once the pipeline offers it.
	var videoDebug: VideoDebugControlling? { (video as AnyObject) as? VideoDebugControlling }

	/// Session part of `psctl status`.
	var statusJSON: [String: Any] {
		let phaseName: String
		switch phase {
		case .connecting: phaseName = "connecting"
		case .streaming: phaseName = "streaming"
		case .ended: phaseName = "ended"
		}
		var profile = JSONValue.reflect(configuration.profile) as? [String: Any] ?? [:]
		profile["codecName"] = "\(configuration.profile.codec)"
		return [
			"running": phase != .ended,
			"phase": phaseName,
			"console": ["name": consoleName, "id": configuration.host.id, "address": configuration.address, "isPS5": configuration.host.isPS5] as [String: Any],
			"profile": profile,
			"renderer": video.displayMode.rawValue,
			"pacing": video.pacingMode.rawValue,
			"upscaler": video.upscaler.rawValue,
			"frameGeneration": video.frameGeneration.rawValue,
			"dualSense": configuration.enableDualSense,
			"startBitrateHint": "\(configuration.startBitrateHint)",
			"uptimeSeconds": (Date().timeIntervalSince(startedAt) * 10).rounded() / 10,
			"streamingSeconds": streamingSince.map { (Date().timeIntervalSince($0) * 10).rounded() / 10 } ?? NSNull(),
			"cantDisplay": cantDisplay,
			"waitingForPIN": pinRequest != nil,
			"recording": recorder.isRecording,
			"videoDebugControl": videoDebug != nil,
		]
	}

	/// Everything we measure, for `psctl stats`. Read fresh, not from the last quarter-second poll.
	var statsJSON: [String: Any] {
		[
			"video": JSONValue.reflect(video.stats),
			"audio": JSONValue.reflect(audio.stats),
			"session": JSONValue.reflect(session.stats()),
			"recorder": recorderJSON,
			"flightRecorder": captureTee.status,
			"input": [
				"idleSeconds": (inputActivity.idleSeconds * 100).rounded() / 100,
				"snapshots": inputActivity.snapshotCount,
				"controller": input.activeController?.name ?? NSNull(),
			] as [String: Any],
			"hitchNotes": hitches.notesWritten,
		]
	}

	var recorderJSON: [String: Any] {
		[
			"state": "\(recorder.state)",
			"elapsedSeconds": recorder.elapsed,
			"bytesWritten": recorder.bytesWritten,
			"file": recorder.outputURL?.path ?? NSNull(),
			"finishedFiles": recorder.finishedURLs.map(\.path),
			"stats": JSONValue.reflect(recorder.stats),
		]
	}

	/// `psctl record start|stop|status`.
	func record(_ action: String) async throws -> [String: Any] {
		switch action {
		case "start":
			guard phase == .streaming else { throw ControlError("the stream is not up yet") }
			guard recorder.start() else { throw ControlError("a recording is already running") }
			CoreLog.note("Recording started via control channel")
			return ["state": "starting", "directory": recorder.options.directory.path, "note": "the file begins at the next keyframe (one was requested)"]
		case "stop":
			guard recorder.isRecording else { throw ControlError("no recording is running") }
			let files = await recorder.stop()
			CoreLog.note("Recording stopped via control channel: \(files.map(\.lastPathComponent).joined(separator: ", "))")
			return ["state": "idle", "files": files.map(\.path)]
		default:
			return recorderJSON
		}
	}

	func submitPIN(_ pin: String) {
		pinRequest = nil
		session.setLoginPIN(pin)
	}

	func putConsoleToSleep() {
		session.putConsoleToSleep()
	}

	func toggleRecording() {
		if recorder.isRecording {
			recorder.stop()
		} else {
			recorder.start()
		}
	}

	var volume: Double {
		get { Double(audio.volume) }
		set {
			audio.volume = Float(newValue)
			settings.volume = newValue
		}
	}

	private var statsTick = 0

	/// Internal pipeline values that have been tuned on this machine and should survive a
	/// reconnect or restart. Stored as a name-to-number dictionary under `debug.tunableOverrides`
	/// (set with `defaults write dev.playstream.PlayStream debug.tunableOverrides -dict ...`).
	private func applyTunableOverrides() {
		guard let overrides = UserDefaults.standard.dictionary(forKey: "debug.tunableOverrides"), !overrides.isEmpty,
		      let debug = (video as AnyObject) as? VideoDebugControlling else { return }
		var applied: [String] = []
		var refused: [String] = []
		for (name, value) in overrides.sorted(by: { $0.key < $1.key }) {
			guard let number = (value as? NSNumber)?.doubleValue else { refused.append(name); continue }
			if debug.setDebugTunable(name, to: number) { applied.append("\(name)=\(number)") } else { refused.append(name) }
		}
		CoreLog.note("Tunable overrides applied: \(applied.joined(separator: ", "))" + (refused.isEmpty ? "" : " | refused: \(refused.joined(separator: ", "))"))
	}

	/// True while the stats overlay is composited into the video frame by the pipeline.
	@Published private(set) var drawsOverlayInFrame = false
	private var overlayInFrameShown = false

	/// Renders the stats overlay to an image and hands it to the pipeline, which draws it into
	/// the video frame. Called at the stats rate; costs nothing on the frame path.
	private func updateInFrameOverlay() {
		let level = StatsLevel(rawValue: settings.statsLevel) ?? .off
		let inFrame = video.displayMode == .metal
		if drawsOverlayInFrame != inFrame { drawsOverlayInFrame = inFrame }
		guard inFrame, level != .off else {
			if overlayInFrameShown {
				video.removeOverlay()
				overlayInFrameShown = false
			}
			return
		}
		let renderer = ImageRenderer(content: StatsOverlay(stats: liveStats, history: history, profile: configuration.profile, level: level))
		renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
		renderer.isOpaque = false
		guard let image = renderer.cgImage else { return }
		// The origin is in the video view's coordinates, and the view is taller than a 16:9
		// picture on this display, so start below the black bar or the top gets cut off.
		var origin = CGPoint(x: 16, y: 16)
		if let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView, view.bounds.width > 0 {
			let pictureHeight = view.bounds.width * CGFloat(configuration.profile.height) / CGFloat(max(configuration.profile.width, 1))
			origin.y += max(0, (view.bounds.height - pictureHeight) / 2)
		}
		video.setOverlay(image, origin: origin)
		overlayInFrameShown = true
	}

	private func refreshStats() {
		var stats = LiveStats()
		stats.video = video.stats
		stats.audio = audio.stats
		stats.session = session.stats()
		liveStats = stats

		// Pictures reaching the screen per second: real ones plus generated ones.
		let generating = stats.video.frameGeneration != .off
		let estimatedFPS = stats.video.decodedFPS + (generating ? stats.video.generatedFPS : 0)
		// The pipeline counts pictures that really reached the screen; fall back to the estimate until it has data.
		let outputFPS = stats.video.presentedFPS > 1 ? stats.video.presentedFPS : estimatedFPS
		let nominalFrameTime = outputFPS > 1 ? 1000 / outputFPS : 0
		history.append(StatsSample(
			outputFPS: outputFPS,
			frameTimeMs: stats.video.presentedIntervalAvgMs ?? nominalFrameTime,
			frameTimeMaxMs: stats.video.presentedIntervalMaxMs ?? nominalFrameTime,
			latencyMs: stats.video.glassAvgMs,
			bitrateMbps: stats.session.measuredBitrate / 1_000_000,
			arrivalGapMs: stats.video.arrivalMaxGapMs
		))
		if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
		updateInFrameOverlay()

		noteHitches(stats, outputFPS: outputFPS)

		// Every 5 s leave a line in the log, so stutter reports can be diagnosed after the fact.
		statsTick += 1
		guard statsTick % Int(5 / Self.statsInterval) == 0, phase == .streaming else { return }
		let v = stats.video
		let audioText = stats.audio.map { String(format: "audio buf %.0f ms target %.0f ms gap max %.0f ms underruns %d", $0.bufferedMs, $0.targetMs, $0.longestGapMs, $0.underruns) } ?? "audio -"
		let layerDelay = v.layerFrameDelayMs.map { String(format: "%.1f", $0) } ?? "-"
		func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
		if v.displayMode == .metal {
			// Second line: what actually happened at the display, the only on-screen evidence we get.
			CoreLog.note(
				"Present: drops kf \(v.dropsAwaitingKeyframe) dec \(v.dropsDecodeError) superseded \(v.dropsSuperseded) overflow \(v.dropsQueueOverflow) nodrawable \(v.dropsNoDrawable)"
					+ " | ontime \(v.presentsOnTime) late1 \(v.presentsLate1) late2+ \(v.presentsLate2Plus) lategen \(v.presentsLateGenerated) notshown \(v.presentsNotShown) err \(ms(v.presentErrorAvgMs))/\(ms(v.presentErrorMaxMs)) ms commitahead \(ms(v.commitAheadMinMs)) ms"
					+ " | presented \(String(format: "%.0f", v.presentedFPS)) fps frametime p99 \(ms(v.frameTimeP99Ms)) max \(ms(v.frameTimeMaxMs)) ms refreshes \(v.presentedRefreshHistogram) offcadence \(v.presentedOffCadence) panel \(ms(v.displayRefreshHz)) Hz"
					+ " | queue \(v.pacedQueueDepthMax) drawablewait \(ms(v.drawableWaitMaxMs)) ms glass \(ms(v.glassAvgMs)) ms"
					+ " | upscaler \(v.activeUpscaler.rawValue) \(v.upscaleOutputWidth)x\(v.upscaleOutputHeight) gpu \(ms(v.renderGPUTimeAvgMs))/\(ms(v.renderGPUTimeMaxMs)) ms scaler \(ms(v.scalerGPUTimeAvgMs)) ms"
					+ " | framegen \(v.frameGeneration.rawValue) \(v.frameGenerationMethod) state \(v.frameGenerationState) content \(String(format: "%.0f", v.contentFPS)) fps generated \(String(format: "%.0f", v.generatedFPS))/s total \(v.framesGenerated) fallbacks \(v.frameGenerationFallbacks) cuts \(v.frameGenerationCutsSkipped) hold \(ms(v.frameGenerationAddedLatencyMs))/\(ms(v.frameGenerationMaxAddedLatencyMs)) ms time \(ms(v.frameGenerationTimeMs)) ms convert \(ms(v.frameGenerationConvertMs)) ms guard \(ms(v.frameGenerationGuardMs)) ms slotshifts \(v.frameGenerationSlotShifts) latereal \(v.frameGenerationLateReal) rejectedmotion \(v.frameGenerationRejectedMotion) motion \(ms(v.frameGenerationMotionMs)) ms warp \(ms(v.frameGenerationWarpMs)) ms | pacer rebases \(v.pacerRebases)"
			)
		}
		CoreLog.note(String(
			format: "Stats: %.0f fps %dx%d %@ | %.1f Mbit/s loss %.2f%% rtt %.1f ms | frames rx %d decoded %d dropped %d netlost %d recovered %d rejected %d layerdrop %d | arrival jitter p95 %.1f ms max gap %.0f ms | pacing %@ delay %.1f/%.1f ms lead %.1f ms late %d skipped %d layerdelay %@ ms | %@",
			v.decodedFPS, v.width, v.height, v.hdrActive ? "HDR" : "SDR",
			stats.session.measuredBitrate / 1_000_000, stats.session.packetLoss * 100, stats.session.rttMilliseconds,
			v.framesReceived, v.framesDecoded, v.framesDropped, v.framesLostInNetwork, v.framesRecovered, v.framesRejected, v.layerDroppedFrames,
			v.arrivalJitterP95Ms, v.arrivalMaxGapMs,
			v.pacingMode.rawValue, v.playoutDelayMs, v.playoutTargetDelayMs, v.presentationLeadMs, v.framesLate, v.framesSkipped, layerDelay,
			audioText
		))
		let c = stats.session
		CoreLog.note(String(
			format: "Console: target %.1f Mbit/s (asked %.0f) rtt %.1f loss %llu reports %llu | corrupt reports sent %llu keyframe requests %llu",
			c.consoleTargetBitrate / 1_000_000, Double(configuration.profile.bitrateKbps) / 1000,
			c.consoleRTT, c.consoleLoss, c.consoleReports, c.corruptReportsSent, c.keyframeRequestsSent
		))
	}

	/// Writes a `Hitch:` line when the stats show something the player will have seen or heard:
	/// a picture held far too long, a burst of late frames, an audio underrun, a gap in the
	/// network arrivals, lost or dropped frames. Rate-limited inside the detector.
	private func noteHitches(_ stats: LiveStats, outputFPS: Double) {
		let v = stats.video
		var sample = HitchSample(time: ProcessInfo.processInfo.systemUptime)
		sample.streaming = phase == .streaming
		sample.framesReceived = v.framesReceived
		sample.framesLostInNetwork = v.framesLostInNetwork
		sample.framesDropped = v.framesDropped
		// Presents one refresh late are routine on some paths; two or more are what shows.
		sample.framesLate = v.framesLate + v.presentsLate2Plus
		sample.framesSkipped = v.framesSkipped
		sample.decodeErrors = v.decodeErrors
		sample.gridShifts = v.frameGenerationSlotShifts + v.pacerRebases
		sample.audioUnderruns = stats.audio?.underruns
		sample.presentedIntervalsMs = v.recentPresentedIntervalsMs
		sample.arrivalIntervalsMs = v.recentArrivalIntervalsMs
		sample.presentedFPS = outputFPS
		sample.streamFPS = v.streamFPS > 1 ? v.streamFPS : Double(configuration.profile.fps)
		sample.bitrateMbps = stats.session.measuredBitrate / 1_000_000
		sample.packetLossPercent = stats.session.packetLoss * 100
		sample.rttMs = stats.session.rttMilliseconds
		sample.audioBufferedMs = stats.audio?.bufferedMs
		sample.playoutDelayMs = v.pacingMode == .off ? nil : v.playoutDelayMs
		guard let line = hitches.ingest(sample), settings.hitchNotes else { return }
		CoreLog.note(line)
	}

	private func handle(_ event: SessionEvent) {
		switch event {
		case .connected:
			phase = .streaming
			streamingSince = Date()
			onStreaming?()
		case .loginPINRequested(let incorrect):
			pinRequest = PINRequest(incorrect: incorrect)
		case .nicknameReceived(let name):
			if !name.isEmpty { consoleName = name }
		case .cantDisplay(let value):
			cantDisplay = value
		case .keyboardOpened, .keyboardTextChanged, .keyboardClosed:
			break
		case .ended(let reason, let isError):
			CoreLog.note("Session ended: \(reason) (error: \(isError))")
			phase = .ended
			statsTimer?.invalidate()
			statsTimer = nil
			input.receiver = nil
			inputActivity.downstream = nil
			input.silenceFeedback()
			recorder.sessionDidEnd()
			if let activity { ProcessInfo.processInfo.endActivity(activity) }
			activity = nil
			onEnded?(reason, isError)
		}
	}
}
