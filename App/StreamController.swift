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
		self.video = VideoPipeline(displayMode: settings.lowLatencyRenderer ? .metal : .sampleBufferLayer)
		var audioConfiguration = AudioPipelineConfiguration()
		// Wi-Fi delivers audio in bursts; 35 ms glitches on every 30 ms+ gap. 55 ms rides most of them.
		audioConfiguration.targetBufferMs = 55
		self.audio = AudioPipeline(configuration: audioConfiguration)
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
		CoreLog.note("Session started: \(configuration.profile.width)x\(configuration.profile.height)@\(configuration.profile.fps) \(configuration.profile.codec) \(configuration.profile.bitrateKbps) kbit/s, renderer \(video.displayMode.rawValue)")
	}

	func stop() {
		session.stop()
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

	private func refreshStats() {
		var stats = LiveStats()
		stats.video = video.stats
		stats.audio = audio.stats
		stats.session = session.stats()
		liveStats = stats
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
