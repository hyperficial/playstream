// swift-tools-version: 6.0
import PackageDescription

// PlayStreamKit: everything except the thin app shell in App/.
// The protocol core (vendor/chiaki-ng, built by scripts/build-chiaki.sh into build/chiaki)
// is only ever touched through the CPSBridge C target.

let root = Context.packageDirectory
let brew = "/opt/homebrew"

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
	name: "PlayStreamKit",
	platforms: [.macOS("26.0")],
	products: [
		.library(name: "PlayStreamKit", targets: [
			"PSContracts", "CPSBridge", "PSCore", "PSVideo", "PSAudio", "PSInput", "PSPairing", "PSRecording",
		]),
		.executable(name: "ps-video-harness", targets: ["VideoHarness"]),
		.executable(name: "ps-audio-harness", targets: ["AudioHarness"]),
		.executable(name: "ps-input-harness", targets: ["InputHarness"]),
		.executable(name: "ps-pairing-harness", targets: ["PairingHarness"]),
		.executable(name: "ps-recording-harness", targets: ["RecordingHarness"]),
		.executable(name: "ps-core-harness", targets: ["CoreHarness"]),
	],
	targets: [
		// Shared value types and protocols. No dependencies. Every module talks through these.
		.target(name: "PSContracts", swiftSettings: swift5),

		// C bridge over libchiaki. Public header is self-contained (no chiaki types leak out).
		.target(
			name: "CPSBridge",
			cSettings: [
				.headerSearchPath("../../vendor/chiaki-ng/lib/include"),
				.headerSearchPath("../../build/chiaki/lib/include"),
			],
			linkerSettings: [
				.unsafeFlags([
					"-L\(root)/build/chiaki/lib",
					"-L\(root)/build/chiaki/third-party",
					"-L\(root)/build/chiaki/third-party/nanopb",
					"-L\(brew)/opt/openssl@3/lib",
					"-L\(brew)/opt/curl/lib",
					"-L\(brew)/lib",
				]),
				.linkedLibrary("chiaki"),
				.linkedLibrary("jerasure"),
				.linkedLibrary("gf_complete"),
				.linkedLibrary("protobuf-nanopb"),
				.linkedLibrary("crypto"),
				.linkedLibrary("opus"),
				.linkedLibrary("json-c"),
				.linkedLibrary("miniupnpc"),
				.linkedLibrary("event"),
				.linkedLibrary("curl"),
				.linkedFramework("CoreServices"),
			]
		),

		// Session lifecycle: wraps the bridge, fans stream data out to the sinks in PSContracts.
		.target(name: "PSCore", dependencies: ["PSContracts", "CPSBridge"], swiftSettings: swift5),

		// Annex-B -> VideoToolbox -> HDR display.
		.target(name: "PSVideo", dependencies: ["PSContracts"], swiftSettings: swift5),
		// PCM -> low-latency output.
		.target(name: "PSAudio", dependencies: ["PSContracts"], swiftSettings: swift5),
		// DualSense / keyboard -> ControllerState, plus rumble / adaptive triggers / haptics.
		.target(name: "PSInput", dependencies: ["PSContracts"], swiftSettings: swift5),
		// Discovery, registration, PSN account id, host store, wake.
		.target(name: "PSPairing", dependencies: ["PSContracts", "CPSBridge"], swiftSettings: swift5),
		// Lossless passthrough recording of the stream.
		.target(name: "PSRecording", dependencies: ["PSContracts"], swiftSettings: swift5),

		// Per-module command line harnesses for testing a module in isolation.
		.executableTarget(name: "VideoHarness", dependencies: ["PSVideo", "PSContracts"], swiftSettings: swift5),
		.executableTarget(name: "AudioHarness", dependencies: ["PSAudio", "PSContracts"], swiftSettings: swift5),
		.executableTarget(name: "InputHarness", dependencies: ["PSInput", "PSContracts"], swiftSettings: swift5),
		.executableTarget(name: "PairingHarness", dependencies: ["PSPairing", "PSContracts"], swiftSettings: swift5),
		.executableTarget(name: "RecordingHarness", dependencies: ["PSRecording", "PSContracts"], swiftSettings: swift5),
		.executableTarget(name: "CoreHarness", dependencies: ["PSCore", "PSPairing", "PSContracts"], swiftSettings: swift5),
	]
)
