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

	@Published private(set) var phase: Phase = .connecting
	@Published private(set) var liveStats = LiveStats()
	@Published private(set) var cantDisplay = false
	@Published var pinRequest: PINRequest?
	@Published private(set) var consoleName: String

	struct PINRequest: Identifiable, Equatable {
		let id = UUID()
		var incorrect: Bool
	}

	/// Called once, on the main thread, when the session is over.
	var onEnded: ((_ reason: String, _ isError: Bool) -> Void)?

	private let session: StreamSession
	private let input: ControllerInput
	private let settings: AppSettings
	private var statsTimer: Timer?
	private var activity: NSObjectProtocol?

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
		self.video.frameGenerationMaxAddedLatencyMs = settings.frameGenerationMaxDelay
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

		// Deliberately not wiring session.onVideoLoss to recorder.noteVideoLoss(): the core only
		// delivers frames whose references we hold, so the recorded bitstream stays decodable
		// after a loss, and forcing a keyframe on every lost frame would spike the bitrate on
		// exactly the links that are already struggling.
		session.videoSink = video
		session.audioSink = audio
		session.hapticsSink = input
		session.feedbackSink = input
		session.onEvent = { [weak self] event in
			MainActor.assumeIsolated { self?.handle(event) }
		}

		input.hapticsToRumbleEnabled = settings.hapticsAsRumble && configuration.enableDualSense

		try session.start()

		input.receiver = session
		// Keep the display awake and tell the scheduler this is latency-sensitive work.
		activity = ProcessInfo.processInfo.beginActivity(
			options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated, .latencyCritical],
			reason: "Streaming from \(configuration.host.nickname)"
		)
		statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			MainActor.assumeIsolated { self?.refreshStats() }
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
		let upscaler: VideoUpscaler = [.off, .bicubic, .metalFXSpatial][min(max(settings.upscaler, 0), 2)]
		let frameGeneration: VideoFrameGeneration = [.off, .to60, .to120][min(max(settings.frameGeneration, 0), 2)]
		let needsMetal = settings.lowLatencyRenderer || upscaler != .off || frameGeneration != .off
		let pacing: VideoPacingMode = (settings.framePacing || frameGeneration != .off) ? .adaptive : .off
		return (needsMetal ? .metal : .sampleBufferLayer, pacing, upscaler, frameGeneration)
	}

	/// Settings that can change in the middle of a session.
	func applyLiveSettings() {
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
		if video.frameGenerationMaxAddedLatencyMs != settings.frameGenerationMaxDelay {
			video.frameGenerationMaxAddedLatencyMs = settings.frameGenerationMaxDelay
			changes.append("frame generation budget \(Int(settings.frameGenerationMaxDelay)) ms")
		}
		if !changes.isEmpty { CoreLog.note("Video settings changed: " + changes.joined(separator: ", ")) }
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

	private func refreshStats() {
		var stats = LiveStats()
		stats.video = video.stats
		stats.audio = audio.stats
		stats.session = session.stats()
		liveStats = stats

		// Every 5 s leave a line in the log, so stutter reports can be diagnosed after the fact.
		statsTick += 1
		guard statsTick % 10 == 0, phase == .streaming else { return }
		let v = stats.video
		let audioText = stats.audio.map { String(format: "audio buf %.0f ms target %.0f ms gap max %.0f ms underruns %d", $0.bufferedMs, $0.targetMs, $0.longestGapMs, $0.underruns) } ?? "audio -"
		let layerDelay = v.layerFrameDelayMs.map { String(format: "%.1f", $0) } ?? "-"
		func ms(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "-" }
		if v.displayMode == .metal {
			// Second line: what actually happened at the display, the only on-screen evidence we get.
			CoreLog.note(
				"Present: drops kf \(v.dropsAwaitingKeyframe) dec \(v.dropsDecodeError) superseded \(v.dropsSuperseded) overflow \(v.dropsQueueOverflow) nodrawable \(v.dropsNoDrawable)"
					+ " | ontime \(v.presentsOnTime) late1 \(v.presentsLate1) late2+ \(v.presentsLate2Plus) lategen \(v.presentsLateGenerated) notshown \(v.presentsNotShown) err \(ms(v.presentErrorAvgMs))/\(ms(v.presentErrorMaxMs)) ms commitahead \(ms(v.commitAheadMinMs)) ms"
					+ " | refreshes \(v.presentedRefreshHistogram) offcadence \(v.presentedOffCadence) panel \(ms(v.displayRefreshHz)) Hz"
					+ " | queue \(v.pacedQueueDepthMax) drawablewait \(ms(v.drawableWaitMaxMs)) ms glass \(ms(v.glassAvgMs)) ms"
					+ " | upscaler \(v.activeUpscaler.rawValue) \(v.upscaleOutputWidth)x\(v.upscaleOutputHeight) gpu \(ms(v.renderGPUTimeAvgMs))/\(ms(v.renderGPUTimeMaxMs)) ms scaler \(ms(v.scalerGPUTimeAvgMs)) ms"
					+ " | framegen \(v.frameGeneration.rawValue) state \(v.frameGenerationState) content \(String(format: "%.0f", v.contentFPS)) fps generated \(String(format: "%.0f", v.generatedFPS))/s total \(v.framesGenerated) fallbacks \(v.frameGenerationFallbacks) cuts \(v.frameGenerationCutsSkipped) hold \(ms(v.frameGenerationAddedLatencyMs))/\(ms(v.frameGenerationMaxAddedLatencyMs)) ms time \(ms(v.frameGenerationTimeMs)) ms convert \(ms(v.frameGenerationConvertMs)) ms guard \(ms(v.frameGenerationGuardMs)) ms slotshifts \(v.frameGenerationSlotShifts) latereal \(v.frameGenerationLateReal)"
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
	}

	private func handle(_ event: SessionEvent) {
		switch event {
		case .connected:
			phase = .streaming
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
			input.silenceFeedback()
			recorder.sessionDidEnd()
			if let activity { ProcessInfo.processInfo.endActivity(activity) }
			activity = nil
			onEnded?(reason, isError)
		}
	}
}
