import Foundation
import PSContracts
import SwiftUI

/// User-facing stream settings, persisted in UserDefaults.
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
	/// 0 off, 1 bicubic, 2 MetalFX. Needs the Metal renderer; applies live.
	@AppStorage("stream.upscaler") var upscaler: Int = 0
	/// 0 off, 1 fill 30 fps games up to 60, 2 double to 120 (experimental). Needs the Metal renderer and pacing; applies live.
	@AppStorage("stream.frameGeneration") var frameGeneration: Int = 0
	/// Most extra delay (ms) frame generation may add. Lower is more responsive but falls back to plain frames more often. Applies live.
	@AppStorage("stream.frameGenerationMaxDelay") var frameGenerationMaxDelay: Double = 40
	/// Experimental start-bitrate hint: 0 off, 1 variant A, 2 variant B. Applies to the next connection.
	@AppStorage("stream.startBitrateHint") var startBitrateHint: Int = 0
	@AppStorage("stream.showStats") var showStats: Bool = false
	@AppStorage("stream.lowLatencyRenderer") var lowLatencyRenderer: Bool = false
	/// Show frames on a steady cadence (about one frame of delay) instead of the instant they arrive. Applies live.
	@AppStorage("stream.framePacing") var framePacing: Bool = true
	@AppStorage("audio.volume") var volume: Double = 1.0
	@AppStorage("stream.startFullscreen") var startFullscreen: Bool = true

	static let bitrateRange: ClosedRange<Double> = 2...100

	var codec: VideoCodec {
		get { VideoCodec(rawValue: codecRaw) ?? .hevcHDR }
		set { codecRaw = newValue.rawValue }
	}

	func profile(isPS5: Bool) -> StreamProfile {
		let size = resolution.size
		return StreamProfile(
			width: size.width,
			height: size.height,
			fps: fps,
			bitrateKbps: Int(bitrateMbps * 1000),
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
