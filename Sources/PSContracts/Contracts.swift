import CoreMedia
import Foundation

// Shared contracts between the PlayStream modules.
//
// Data flow while streaming:
//
//   PS5 ──network──▶ PSCore.StreamSession ──▶ VideoStreamSink    (PSVideo)  ──▶ EncodedVideoTap (PSRecording)
//                                         ──▶ AudioStreamSink    (PSAudio)  ──▶ PCMAudioTap     (PSRecording)
//                                         ──▶ HapticsStreamSink  (PSInput)
//                                         ──▶ ControllerFeedbackSink (PSInput)
//   PSInput ──ControllerState──▶ ControllerStateReceiver (PSCore.StreamSession) ──network──▶ PS5
//
// Threading: every "stream" callback below is invoked on a network thread owned by the protocol
// core, never the main thread. Implementations must return quickly (no blocking I/O, no waiting
// on the main thread) because stalling these threads stalls packet processing for the stream.

// MARK: - Video

public enum VideoCodec: Int, Codable, Sendable, CaseIterable {
	case h264 = 0
	case hevc = 1
	/// HEVC Main10, BT.2020 primaries, SMPTE ST 2084 (PQ) transfer. PS5 only.
	case hevcHDR = 2

	public var isHEVC: Bool { self != .h264 }
	public var isHDR: Bool { self == .hevcHDR }
}

/// What we ask the console to send.
public struct StreamProfile: Codable, Sendable, Equatable {
	public var width: Int
	public var height: Int
	public var fps: Int
	/// Video bitrate in kbit/s.
	public var bitrateKbps: Int
	public var codec: VideoCodec

	public init(width: Int, height: Int, fps: Int, bitrateKbps: Int, codec: VideoCodec) {
		self.width = width
		self.height = height
		self.fps = fps
		self.bitrateKbps = bitrateKbps
		self.codec = codec
	}

	/// Highest quality the PS5 offers over Remote Play: 1080p60 HDR.
	public static let ps5Max = StreamProfile(width: 1920, height: 1080, fps: 60, bitrateKbps: 30000, codec: .hevcHDR)
}

/// Receives the encoded video elementary stream.
public protocol VideoStreamSink: AnyObject {
	/// Called once before the first access unit of a session.
	func videoStreamWillStart(profile: StreamProfile)

	/// One complete Annex-B buffer (start-code delimited NAL units) exactly as the protocol core
	/// assembled it. The very first buffer of a session is the stream header (parameter sets
	/// only: VPS/SPS/PPS for HEVC, SPS/PPS for H.264); later buffers are one coded frame each.
	/// The memory is only valid for the duration of the call.
	///
	/// - Parameters:
	///   - framesLost: number of frames that were dropped on the network immediately before this one.
	///   - frameRecovered: true if this frame was reconstructed via error correction.
	/// - Returns: false if the buffer could not be consumed (the core then reports a corrupt
	///   frame to the console, which answers with a fresh keyframe).
	func videoStreamDidReceive(accessUnit: UnsafeRawBufferPointer, framesLost: Int, frameRecovered: Bool) -> Bool

	/// The session ended; release decoder resources.
	func videoStreamDidStop()
}

/// Observes the compressed video samples the video pipeline builds, without re-encoding.
/// Used for passthrough recording.
public protocol EncodedVideoTap: AnyObject {
	/// `sampleBuffer` holds one compressed frame (AVCC/HVCC length-prefixed, with a format
	/// description carrying the parameter sets and, for HDR, the colour tags). Its presentation
	/// timestamp is on the host time clock (`CMClockGetHostTimeClock`), taken at arrival.
	/// Called on the same network thread as `VideoStreamSink`; must not block.
	func encodedVideoDidProduce(sampleBuffer: CMSampleBuffer, isKeyframe: Bool)
}

/// Lets a module ask the console for a fresh keyframe (IDR). Implemented by the session.
public protocol KeyframeRequesting: AnyObject {
	func requestKeyframe()
}

// MARK: - Audio

/// Receives decoded game audio.
public protocol AudioStreamSink: AnyObject {
	/// Called before the first frame and whenever the format changes. PS5 sends 48 kHz stereo.
	func audioStreamDidConfigure(channels: Int, sampleRate: Int)

	/// Interleaved signed 16-bit PCM. `pcm.count == frameCount * channels`.
	/// The memory is only valid for the duration of the call. A typical frame is 480 samples (10 ms).
	func audioStreamDidReceive(pcm: UnsafeBufferPointer<Int16>, frameCount: Int)

	func audioStreamDidStop()
}

/// Observes the decoded PCM audio. Used for recording.
public protocol PCMAudioTap: AnyObject {
	func pcmAudioDidConfigure(channels: Int, sampleRate: Int)
	/// `hostTime` is `mach_absolute_time()` at arrival, so it can be aligned with the video
	/// sample timestamps. Called on a network thread; must not block.
	func pcmAudioDidReceive(pcm: UnsafeBufferPointer<Int16>, frameCount: Int, hostTime: UInt64)
}

/// Receives the DualSense haptics stream: interleaved signed 16-bit PCM, 2 channels
/// (left / right actuator), 3000 Hz. Only sent when the session was started with DualSense
/// features enabled.
public protocol HapticsStreamSink: AnyObject {
	func hapticsStreamDidReceive(pcm: UnsafeBufferPointer<Int16>, frameCount: Int)
}

// MARK: - Controller

/// Digital buttons. Raw values match the protocol core's button bitmask exactly.
public struct ControllerButtons: OptionSet, Sendable, Hashable {
	public let rawValue: UInt32
	public init(rawValue: UInt32) { self.rawValue = rawValue }

	public static let cross = ControllerButtons(rawValue: 1 << 0)
	public static let circle = ControllerButtons(rawValue: 1 << 1)
	public static let square = ControllerButtons(rawValue: 1 << 2)
	public static let triangle = ControllerButtons(rawValue: 1 << 3)
	public static let dpadLeft = ControllerButtons(rawValue: 1 << 4)
	public static let dpadRight = ControllerButtons(rawValue: 1 << 5)
	public static let dpadUp = ControllerButtons(rawValue: 1 << 6)
	public static let dpadDown = ControllerButtons(rawValue: 1 << 7)
	public static let l1 = ControllerButtons(rawValue: 1 << 8)
	public static let r1 = ControllerButtons(rawValue: 1 << 9)
	public static let l3 = ControllerButtons(rawValue: 1 << 10)
	public static let r3 = ControllerButtons(rawValue: 1 << 11)
	public static let options = ControllerButtons(rawValue: 1 << 12)
	/// "Create" on DualSense.
	public static let share = ControllerButtons(rawValue: 1 << 13)
	/// Touchpad click.
	public static let touchpad = ControllerButtons(rawValue: 1 << 14)
	public static let ps = ControllerButtons(rawValue: 1 << 15)
}

/// One finger on the touchpad. Coordinates are in the DualSense touchpad space:
/// x in 0...1919, y in 0...1078, origin top-left.
public struct ControllerTouch: Sendable, Equatable {
	public var x: UInt16
	public var y: UInt16
	/// Touch identifier 0...127, or -1 when this slot is not touching.
	public var id: Int8

	public init(x: UInt16 = 0, y: UInt16 = 0, id: Int8 = -1) {
		self.x = x
		self.y = y
		self.id = id
	}

	public static let none = ControllerTouch()
}

/// Full controller snapshot sent to the console. Mirrors the protocol core's controller state.
public struct ControllerState: Sendable, Equatable {
	public var buttons: ControllerButtons = []
	/// Analog triggers, 0 (released) ... 255 (fully pressed).
	public var l2: UInt8 = 0
	public var r2: UInt8 = 0
	/// Sticks, -32768 ... 32767. Positive x is right, positive y is DOWN.
	public var leftX: Int16 = 0
	public var leftY: Int16 = 0
	public var rightX: Int16 = 0
	public var rightY: Int16 = 0

	/// Id the next new touch should take (wraps at 128). Increment when starting a touch.
	public var touchIdNext: UInt8 = 0
	public var touch0: ControllerTouch = .none
	public var touch1: ControllerTouch = .none

	/// Angular velocity in rad/s.
	public var gyroX: Float = 0
	public var gyroY: Float = 0
	public var gyroZ: Float = 0
	/// Acceleration in g. A controller lying flat on a table reads (0, 1, 0).
	public var accelX: Float = 0
	public var accelY: Float = 1
	public var accelZ: Float = 0
	/// Orientation quaternion. Identity is (0, 0, 0, 1).
	public var orientX: Float = 0
	public var orientY: Float = 0
	public var orientZ: Float = 0
	public var orientW: Float = 1

	public init() {}

	public static let idle = ControllerState()
}

/// Takes controller snapshots and forwards them to the console. Implemented by the session.
/// May be called from any thread, as often as the state changes (the core rate-limits sending).
public protocol ControllerStateReceiver: AnyObject {
	func controllerStateDidChange(_ state: ControllerState)
}

/// Feedback the console sends for the controller. Called on a network thread.
public protocol ControllerFeedbackSink: AnyObject {
	/// Classic rumble. `left` is the low-frequency (strong) motor, `right` the high-frequency (weak) one. 0...255.
	func controllerFeedbackRumble(left: UInt8, right: UInt8)
	/// DualSense adaptive trigger effect, in the raw DualSense output-report encoding:
	/// `type` is the effect mode byte and `params` the 10 parameter bytes that follow it.
	func controllerFeedbackTriggerEffects(typeLeft: UInt8, paramsLeft: [UInt8], typeRight: UInt8, paramsRight: [UInt8])
	/// Light bar colour.
	func controllerFeedbackLED(red: UInt8, green: UInt8, blue: UInt8)
	/// Player indicator LEDs.
	func controllerFeedbackPlayerIndex(_ index: UInt8)
	/// The game asked to reset the motion/orientation reference.
	func controllerFeedbackMotionReset()
}

// MARK: - Hosts

public enum HostState: String, Codable, Sendable {
	case ready
	case standby
	case unknown
}

/// A console seen on the local network right now.
public struct DiscoveredHost: Identifiable, Sendable, Equatable {
	/// Stable console identifier: the 12 hex digit host id (MAC), uppercase. Matches `RegisteredHost.id`.
	public var id: String
	public var name: String
	/// IP address the console answered from.
	public var address: String
	public var isPS5: Bool
	public var state: HostState
	/// Raw system version string from discovery, e.g. "14230000".
	public var systemVersion: String
	/// Protocol target value to use when registering / connecting (opaque, from the core).
	public var target: UInt32
	public var requestPort: UInt16
	public var runningAppName: String?
	public var runningAppTitleID: String?

	public init(id: String, name: String, address: String, isPS5: Bool, state: HostState, systemVersion: String, target: UInt32, requestPort: UInt16, runningAppName: String? = nil, runningAppTitleID: String? = nil) {
		self.id = id
		self.name = name
		self.address = address
		self.isPS5 = isPS5
		self.state = state
		self.systemVersion = systemVersion
		self.target = target
		self.requestPort = requestPort
		self.runningAppName = runningAppName
		self.runningAppTitleID = runningAppTitleID
	}
}

/// A console this Mac has been paired with. Contains secrets (`registKey`, `rpKey`).
public struct RegisteredHost: Identifiable, Codable, Sendable, Equatable {
	/// 12 hex digit MAC, uppercase. Matches `DiscoveredHost.id`.
	public var id: String
	public var nickname: String
	public var isPS5: Bool
	/// Protocol target value (opaque, from the core).
	public var target: UInt32
	/// 16 bytes, zero padded. Identifies this pairing to the console.
	public var registKey: Data
	/// 16 bytes. Session secret ("morning").
	public var rpKey: Data
	public var rpKeyType: UInt32
	/// 6 bytes.
	public var serverMAC: Data
	/// Last address the console was seen at, for connecting when discovery has not found it yet.
	public var lastKnownAddress: String?

	public init(id: String, nickname: String, isPS5: Bool, target: UInt32, registKey: Data, rpKey: Data, rpKeyType: UInt32, serverMAC: Data, lastKnownAddress: String? = nil) {
		self.id = id
		self.nickname = nickname
		self.isPS5 = isPS5
		self.target = target
		self.registKey = registKey
		self.rpKey = rpKey
		self.rpKeyType = rpKeyType
		self.serverMAC = serverMAC
		self.lastKnownAddress = lastKnownAddress
	}
}

/// The PSN account the pairing is tied to: the 8 byte account id (not the online id / username).
public struct PSNAccount: Codable, Sendable, Equatable {
	/// Exactly 8 bytes.
	public var accountID: Data
	public var onlineID: String?

	public init(accountID: Data, onlineID: String? = nil) {
		self.accountID = accountID
		self.onlineID = onlineID
	}

	/// Base64 form, as used by other Remote Play clients.
	public var accountIDBase64: String { accountID.base64EncodedString() }
}
