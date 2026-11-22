import PSContracts
import PSInput
import SwiftUI

struct SettingsView: View {
	@ObservedObject var settings: AppSettings
	@ObservedObject var input: ControllerInput

	var body: some View {
		Form {
			Section("Video") {
				Picker("Resolution", selection: settings.$resolution) {
					ForEach(AppSettings.Resolution.allCases) { Text($0.label).tag($0) }
				}
				Picker("Frame rate", selection: settings.$fps) {
					Text("60 fps").tag(60)
					Text("30 fps").tag(30)
				}
				Picker("Codec", selection: settings.$codecRaw) {
					ForEach(VideoCodec.allCases.reversed(), id: \.rawValue) { Text($0.label).tag($0.rawValue) }
				}
				VStack(alignment: .leading, spacing: 4) {
					Slider(value: settings.$bitrateMbps, in: AppSettings.bitrateRange, step: 1) {
						Text("Bitrate")
					} minimumValueLabel: {
						Text("2")
					} maximumValueLabel: {
						Text("100")
					}
					Text("\(Int(settings.bitrateMbps)) Mbit/s. Sony's own client uses 15. Higher looks better but needs strong Wi-Fi; lower it if the picture stutters.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				Toggle("Smooth frame pacing", isOn: settings.$framePacing)
				Text("Shows frames on a steady rhythm, about one frame later, instead of the instant they arrive. Turn off for the lowest possible delay. Applies immediately.")
					.font(.caption)
					.foregroundStyle(.secondary)
				Toggle("Low-latency renderer", isOn: settings.$lowLatencyRenderer)
				Toggle("Start in full screen", isOn: settings.$startFullscreen)
			}
			Section("Controller") {
				Picker("Controller", selection: Binding(get: { input.activeControllerID ?? -1 }, set: { input.selectController(id: $0 < 0 ? nil : $0) })) {
					if input.controllers.isEmpty { Text("None connected").tag(-1) }
					ForEach(input.controllers) { controller in
						Text(controller.name).tag(controller.id)
					}
				}
				.disabled(input.controllers.count < 2)
				LabeledContent("Light bar") {
					HStack(spacing: 8) {
						Image(systemName: "light.min").foregroundStyle(.secondary)
						Slider(value: settings.$lightBrightness, in: 0...1)
						Image(systemName: "light.max").foregroundStyle(.secondary)
					}
				}
				Toggle("Player number lights", isOn: settings.$playerLEDs)
				LabeledContent("Rumble strength") {
					Slider(value: settings.$rumbleStrength, in: 0...1)
				}
				Toggle("Motion sensors", isOn: settings.$motionSensors)
				Toggle("Keyboard as controller", isOn: settings.$keyboardFallback)
				Toggle("DualSense haptics and adaptive triggers", isOn: settings.$dualSenseFeatures)
				Toggle("Play haptics as rumble", isOn: settings.$hapticsAsRumble)
					.disabled(!settings.dualSenseFeatures)
				Text("Light, rumble, motion and keyboard apply immediately. The two DualSense options apply to the next connection.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section("Experimental") {
				Picker("Start bitrate hint", selection: settings.$startBitrateHint) {
					Text("Off").tag(0)
					Text("Variant A").tag(1)
					Text("Variant B").tag(2)
				}
				Text("Sends your bitrate in a handshake field that is normally left empty. Whether the console uses it is unknown; A and B are the two possible encodings. If a session fails to connect or looks worse, set it back to Off. Applies to the next connection.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Section("Audio") {
				Slider(value: settings.$volume, in: 0...1) { Text("Volume") }
			}
			Section {
				Text("Other video changes apply to the next connection.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.frame(width: 460)
		.fixedSize(horizontal: false, vertical: true)
	}
}
