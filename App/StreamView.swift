import PSContracts
import PSInput
import PSRecording
import PSVideo
import SwiftUI

struct StreamView: View {
	@ObservedObject var controller: StreamController
	@ObservedObject var settings: AppSettings
	@ObservedObject var recorder: StreamRecorder
	let input: ControllerInput
	let onDisconnect: () -> Void

	@State private var showControls = false
	@State private var showSettings = false
	@State private var hideTask: Task<Void, Never>?
	@State private var pin = ""

	init(controller: StreamController, settings: AppSettings, input: ControllerInput, onDisconnect: @escaping () -> Void) {
		self.controller = controller
		self.settings = settings
		self.input = input
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
					if let level = StatsLevel(rawValue: settings.statsLevel), level != .off {
						StatsOverlay(stats: controller.liveStats, history: controller.history, profile: controller.configuration.profile, level: level)
					}
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
				settings.statsLevel = (StatsLevel(rawValue: settings.statsLevel) ?? .off).next.rawValue
			} label: {
				Label("Stats", systemImage: "chart.bar.xaxis")
			}
			.keyboardShortcut("i", modifiers: .command)
			.help("Stream statistics: off, compact, full (⌘I)")

			Button {
				NSApp.keyWindow?.toggleFullScreen(nil)
			} label: {
				Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
			}
			.help("Full screen (⌃⌘F)")

			Button {
				showSettings.toggle()
			} label: {
				Label("Settings", systemImage: "slider.horizontal.3")
			}
			.help("Controller and stream settings")
			.popover(isPresented: $showSettings, arrowEdge: .top) {
				SettingsView(settings: settings, input: input)
			}

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
			guard !Task.isCancelled, !showSettings else { return }
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
