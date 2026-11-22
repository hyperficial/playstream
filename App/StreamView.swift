import PSContracts
import PSRecording
import PSVideo
import SwiftUI

struct StreamView: View {
	@ObservedObject var controller: StreamController
	@ObservedObject var settings: AppSettings
	@ObservedObject var recorder: StreamRecorder
	let onDisconnect: () -> Void

	@State private var showControls = false
	@State private var hideTask: Task<Void, Never>?
	@State private var pin = ""

	init(controller: StreamController, settings: AppSettings, onDisconnect: @escaping () -> Void) {
		self.controller = controller
		self.settings = settings
		self.recorder = controller.recorder
		self.onDisconnect = onDisconnect
	}

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()
			VideoPlayerView(pipeline: controller.video)
				.ignoresSafeArea()

			if controller.phase == .connecting {
				VStack(spacing: 14) {
					ProgressView().controlSize(.large)
					Text("Connecting to \(controller.consoleName)…").font(.title3)
					Button("Cancel", action: onDisconnect)
				}
				.padding(28)
				.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
			}

			if controller.cantDisplay {
				Text("The console is showing something it does not allow to be streamed.")
					.padding(16)
					.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
			}

			VStack {
				HStack(alignment: .top) {
					if settings.showStats { StatsOverlay(stats: controller.liveStats, profile: controller.configuration.profile) }
					Spacer()
					if recorder.state.isBusy { RecordingBadge(recorder: recorder) }
				}
				Spacer()
				if showControls { controlBar.transition(.opacity.combined(with: .move(edge: .bottom))) }
			}
			.padding(16)
		}
		.onContinuousHover { phase in
			if case .active = phase { revealControls() }
		}
		.sheet(item: $controller.pinRequest) { request in
			pinSheet(request)
		}
		.navigationTitle(controller.consoleName)
		.animation(.easeOut(duration: 0.18), value: showControls)
	}

	private var controlBar: some View {
		HStack(spacing: 14) {
			Button(action: onDisconnect) {
				Label("Disconnect", systemImage: "xmark.circle.fill")
			}
			.keyboardShortcut("d", modifiers: .command)
			.help("Disconnect (⌘D)")

			Button {
				controller.toggleRecording()
			} label: {
				Label(recorder.isRecording ? "Stop recording" : "Record", systemImage: recorder.isRecording ? "stop.circle.fill" : "record.circle")
			}
			.keyboardShortcut("r", modifiers: .command)
			.help("Record to ~/Movies/PlayStream (⌘R)")

			Button {
				settings.showStats.toggle()
			} label: {
				Label("Stats", systemImage: "chart.bar.xaxis")
			}
			.keyboardShortcut("i", modifiers: .command)
			.help("Show stream statistics (⌘I)")

			Button {
				NSApp.keyWindow?.toggleFullScreen(nil)
			} label: {
				Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
			}
			.help("Full screen (⌃⌘F)")

			Divider().frame(height: 18)

			Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
			Slider(value: Binding(get: { controller.volume }, set: { controller.volume = $0 }), in: 0...1)
				.frame(width: 120)

			Divider().frame(height: 18)

			Menu {
				Button("Put console in rest mode") { controller.putConsoleToSleep() }
			} label: {
				Label("More", systemImage: "ellipsis.circle")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
		}
		.labelStyle(.titleAndIcon)
		.buttonStyle(.borderless)
		.padding(.horizontal, 18)
		.padding(.vertical, 12)
		.background(.regularMaterial, in: Capsule())
	}

	private func pinSheet(_ request: StreamController.PINRequest) -> some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("Console login PIN").font(.headline)
			Text(request.incorrect ? "That PIN was not accepted. Try again." : "Your console profile is protected by a PIN. Enter it to continue.")
				.foregroundStyle(request.incorrect ? .red : .secondary)
			SecureField("PIN", text: $pin)
				.textFieldStyle(.roundedBorder)
				.onSubmit { submitPIN() }
			HStack {
				Spacer()
				Button("Disconnect", role: .cancel) {
					controller.pinRequest = nil
					onDisconnect()
				}
				Button("Continue") { submitPIN() }
					.keyboardShortcut(.defaultAction)
					.disabled(pin.isEmpty)
			}
		}
		.padding(20)
		.frame(width: 340)
	}

	private func submitPIN() {
		let value = pin
		pin = ""
		controller.submitPIN(value)
	}

	private func revealControls() {
		showControls = true
		hideTask?.cancel()
		hideTask = Task {
			try? await Task.sleep(nanoseconds: 2_500_000_000)
			guard !Task.isCancelled else { return }
			showControls = false
			NSCursor.setHiddenUntilMouseMoves(true)
		}
	}
}

private struct RecordingBadge: View {
	@ObservedObject var recorder: StreamRecorder

	var body: some View {
		HStack(spacing: 8) {
			Circle().fill(.red).frame(width: 10, height: 10)
			Text(label).font(.callout.monospacedDigit())
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 7)
		.background(.regularMaterial, in: Capsule())
	}

	private var label: String {
		switch recorder.state {
		case .waitingForKeyframe: return "Starting…"
		case .finishing: return "Saving…"
		default:
			let seconds = Int(recorder.elapsed)
			let megabytes = Double(recorder.bytesWritten) / 1_000_000
			return String(format: "%02d:%02d  %.0f MB", seconds / 60, seconds % 60, megabytes)
		}
	}
}

private struct StatsOverlay: View {
	let stats: StreamController.LiveStats
	let profile: StreamProfile

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			row("Video", "\(stats.video.width)×\(stats.video.height)  \(String(format: "%.0f", stats.video.decodedFPS)) fps  \(stats.video.hdrActive ? "HDR" : "SDR")")
			row("Bitrate", String(format: "%.1f Mbit/s (asked %.0f)", stats.session.measuredBitrate / 1_000_000, Double(profile.bitrateKbps) / 1000))
			row("Network", String(format: "loss %.1f%%  rtt %.0f ms", stats.session.packetLoss * 100, stats.session.rttMilliseconds))
			row("Frames", "lost \(stats.video.framesLostInNetwork)  dropped \(stats.video.framesDropped)  recovered \(stats.video.framesRecovered)")
			if let decode = stats.video.decodeTimeAvgMs {
				row("Decode", String(format: "%.1f ms", decode))
			}
			row("Hand-off", String(format: "%.1f ms (max %.1f)", stats.video.handoffAvgMs, stats.video.handoffMaxMs))
			if let glass = stats.video.glassAvgMs {
				row("To glass", String(format: "%.1f ms", glass))
			}
			if let audio = stats.audio {
				row("Audio", String(format: "buffer %.0f ms  out %.0f ms  underruns %d", audio.bufferedMs, audio.outputLatencyMs, audio.underruns))
			}
		}
		.font(.caption.monospacedDigit())
		.padding(10)
		.background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.foregroundStyle(.white)
	}

	private func row(_ title: String, _ value: String) -> some View {
		HStack(spacing: 8) {
			Text(title).foregroundStyle(.white.opacity(0.6)).frame(width: 62, alignment: .leading)
			Text(value)
		}
	}
}
