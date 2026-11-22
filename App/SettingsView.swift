import PSContracts
import SwiftUI

struct SettingsView: View {
	@ObservedObject var settings: AppSettings

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
				Toggle("Low-latency renderer", isOn: settings.$lowLatencyRenderer)
				Toggle("Start in full screen", isOn: settings.$startFullscreen)
			}
			Section("Controller") {
				Toggle("DualSense haptics and adaptive triggers", isOn: settings.$dualSenseFeatures)
				Toggle("Play haptics as rumble", isOn: settings.$hapticsAsRumble)
					.disabled(!settings.dualSenseFeatures)
			}
			Section("Audio") {
				Slider(value: settings.$volume, in: 0...1) { Text("Volume") }
			}
			Section {
				Text("Changes apply to the next connection.")
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
		.formStyle(.grouped)
		.frame(width: 460)
		.fixedSize(horizontal: false, vertical: true)
	}
}
