import Foundation
import PSContracts
import SwiftUI

/// User-facing stream settings, persisted in UserDefaults.
///
/// Every key here is also listed in `SettingsCatalog` (PSCore) with its type, range and default,
/// which is what lets `psctl settings set` change it from the terminal. When adding a setting,
/// add it there too; `ps-core-harness selftest` fails if the two lists disagree.
final class AppSettings: ObservableObject {
	enum Resolution: Int, CaseIterable, Identifiable {
		case p1080 = 1080
		case p720 = 720
		case p540 = 540

		var id: Int { rawValue }
		var label: String { "\(rawValue)p" }
		var size: (width: Int, height: Int) {
			switch self {
			case .p1080: return (1920, 1080)
			case .p720: return (1280, 720)
			case .p540: return (960, 540)
			}
		}
	}

	@AppStorage("stream.resolution") var resolution: Resolution = .p1080
	@AppStorage("stream.fps") var fps: Int = 60
	/// Mbit/s. The console's own client uses 15 at 1080p; on a good local network far more works.
	@AppStorage("stream.bitrateMbps") var bitrateMbps: Double = 30
	@AppStorage("stream.codec") var codecRaw: Int = VideoCodec.hevcHDR.rawValue
	@AppStorage("stream.dualsense") var dualSenseFeatures: Bool = true
	@AppStorage("stream.hapticsAsRumble") var hapticsAsRumble: Bool = true
	/// 0 (off) ... 1 (full). Applies live.
	@AppStorage("controller.lightBrightness") var lightBrightness: Double = 0.4
	@AppStorage("controller.playerLEDs") var playerLEDs: Bool = true
	/// 0 (off) ... 1 (as the game asks). Applies live.
	@AppStorage("controller.rumbleStrength") var rumbleStrength: Double = 1.0
	@AppStorage("controller.motion") var motionSensors: Bool = true
	@AppStorage("controller.keyboard") var keyboardFallback: Bool = true
	/// 0 off, 1 bicubic, 2 MetalFX, 3 FSR 1. Needs the Metal renderer; applies live.
	@AppStorage("stream.upscaler") var upscaler: Int = 0
	/// 0 (none) ... 1 (strongest). Only FSR 1 has a sharpening stage. Applies live.
	@AppStorage("stream.upscalerSharpness") var upscalerSharpness: Double = 0.5
	/// 0 off, 1 fill 30 fps games up to 60, 2 double to 120 (experimental). Needs the Metal renderer and pacing; applies live.
	@AppStorage("stream.frameGeneration") var frameGeneration: Int = 0
	/// Most extra delay (ms) frame generation may add. Lower is more responsive but falls back to plain frames more often. Applies live.
	@AppStorage("stream.frameGenerationMaxDelay") var frameGenerationMaxDelay: Double = 45
	/// 0 predict ahead (no added delay), 1 in-between pictures (smoothest, delayed). Applies live.
	@AppStorage("stream.frameGenerationMethod") var frameGenerationMethod: Int = 0
	/// Experimental start-bitrate hint: 0 off, 1 variant A, 2 variant B. Applies to the next connection.
	@AppStorage("stream.startBitrateHint") var startBitrateHint: Int = 0
	/// 0 off, 1 compact (fps, frame time, graph), 2 full.
	@AppStorage("stream.statsLevel") var statsLevel: Int = 0
	@AppStorage("stream.lowLatencyRenderer") var lowLatencyRenderer: Bool = false
	/// Show frames on a steady cadence (about one frame of delay) instead of the instant they arrive. Applies live.
	@AppStorage("stream.framePacing") var framePacing: Bool = true
	@AppStorage("audio.volume") var volume: Double = 1.0
	@AppStorage("stream.startFullscreen") var startFullscreen: Bool = true
	/// The local control socket `scripts/psctl` talks to (same user only). Applies live.
	@AppStorage("debug.controlChannel") var controlChannel: Bool = true
	/// Write a `Hitch:` line into the log when a visible hitch is detected. Applies live.
	@AppStorage("debug.hitchNotes") var hitchNotes: Bool = true
	/// At launch, reconnect to the console that was streaming when the app last quit or was relaunched.
	@AppStorage("resume.autoReconnect") var autoReconnect: Bool = true

	static let bitrateRange: ClosedRange<Double> = 2...100

	var codec: VideoCodec {
		get { VideoCodec(rawValue: codecRaw) ?? .hevcHDR }
		set { codecRaw = newValue.rawValue }
	}

	func profile(isPS5: Bool) -> StreamProfile {
		let size = resolution.size
		// The stored values can be edited from outside the app; keep what goes to the console
		// within what the settings panel could have produced.
		let range = AppSettings.bitrateRange
		let rate = bitrateMbps.isFinite ? min(max(bitrateMbps, range.lowerBound), range.upperBound) : 30
		return StreamProfile(
			width: size.width,
			height: size.height,
			fps: fps == 30 ? 30 : 60,
			bitrateKbps: Int(rate * 1000),
			codec: isPS5 ? codec : .h264
		)
	}
}

extension VideoCodec {
	var label: String {
		switch self {
		case .h264: return "H.264"
		case .hevc: return "HEVC"
		case .hevcHDR: return "HEVC HDR"
		}
	}
}
