import CoreMedia
import Foundation

/// Public value types of the recorder.
extension StreamRecorder {
	public enum State: Equatable, Sendable {
		case idle
		/// `start()` was called; samples are discarded until the first keyframe arrives.
		case waitingForKeyframe
		case recording
		/// `stop()` was called; the writers are flushing. Do not quit the app yet.
		case finishing
		case failed(String)

		public var isBusy: Bool {
			switch self {
			case .waitingForKeyframe, .recording, .finishing: return true
			case .idle, .failed: return false
			}
		}
	}

	public enum AudioMode: Equatable, Sendable {
		/// AAC-LC encoded by the writer, bit rate in bit/s (256000 is transparent for stereo game audio).
		case aac(bitrate: Int)
		/// 16-bit little-endian PCM stored as is (QuickTime `sowt`). Bigger files, no generation loss.
		case lossless

		public static let aacHigh = AudioMode.aac(bitrate: 256_000)
	}

	/// Colour tags written into the video sample description when the incoming format description
	/// lacks them. Defaults describe HDR10 (BT.2020 primaries, PQ transfer, BT.2020 non-constant luma).
	public struct ColorTags: Equatable, Sendable {
		public var primaries: String
		public var transfer: String
		public var matrix: String
		public init(primaries: String, transfer: String, matrix: String) {
			self.primaries = primaries
			self.transfer = transfer
			self.matrix = matrix
		}
		public static let hdr10 = ColorTags(
			primaries: kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
			transfer: kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String,
			matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String)
		public static let sdr709 = ColorTags(
			primaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String,
			transfer: kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String,
			matrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
	}

	/// HDR10 static metadata (SMPTE ST 2086 mastering display + CTA-861.3 content light level),
	/// added to the sample description (`mdcv`/`clli`) only when the stream is PQ and carries none.
	public struct HDRStaticMetadata: Equatable, Sendable {
		/// 24 bytes, big endian, exactly as the `mdcv` box payload.
		public var masteringDisplayColorVolume: Data
		/// 4 bytes, big endian: MaxCLL, MaxFALL (`clli` box payload).
		public var contentLightLevel: Data
		public init(masteringDisplayColorVolume: Data, contentLightLevel: Data) {
			self.masteringDisplayColorVolume = masteringDisplayColorVolume
			self.contentLightLevel = contentLightLevel
		}
		/// P3-D65 mastering display, 1000 nit peak, 0.0001 nit black; MaxCLL 1000, MaxFALL 400.
		public static let p3d65_1000nit: HDRStaticMetadata = {
			func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
			func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
			var m: [UInt8] = []
			// G, B, R, white point in 0.00002 units (display order of the mdcv box: G, B, R).
			m += be16(13250) + be16(34500)
			m += be16(7500) + be16(3000)
			m += be16(34000) + be16(16000)
			m += be16(15635) + be16(16450)
			m += be32(10_000_000) + be32(1)
			return HDRStaticMetadata(masteringDisplayColorVolume: Data(m), contentLightLevel: Data(be16(1000) + be16(400)))
		}()
	}

	public struct Options {
		/// Where recordings go. Default `~/Movies/PlayStream/`.
		public var directory: URL
		public var fileNamePrefix: String = "PlayStream"
		public var audio: AudioMode = .aacHigh
		/// Movie fragment interval. A crash loses at most about this much.
		public var fragmentInterval: TimeInterval = 2
		/// Back-pressure bounds while the writer inputs are not ready (about 3 s of 60 fps video, 6 s of 10 ms audio).
		public var maxPendingVideoFrames: Int = 180
		public var maxPendingAudioBuffers: Int = 600
		/// How long `stop()` waits for back-pressured samples to drain before dropping them.
		public var finishTimeout: TimeInterval = 10
		/// A non-keyframe arriving this long after its predecessor means frames went missing, so the
		/// references are broken: discard until the next keyframe (and request one). nil disables.
		public var lossGapThreshold: TimeInterval? = 0.15
		/// Place frames on a steady grid instead of their jittery arrival times (see `VideoRetimer`).
		public var smoothVideoTimestamps: Bool = true
		/// Added to the audio timeline (seconds). Positive delays audio relative to video. For fine
		/// tuning of a measured, constant pipeline latency difference.
		public var audioDelay: TimeInterval = 0
		/// Applied only if the video format description carries no colour tags.
		public var fallbackColorTags: ColorTags?
		/// Applied only if the stream is PQ and carries no mastering / light level metadata.
		public var fallbackHDRMetadata: HDRStaticMetadata?

		/// Test hook: pretend the writer inputs are not ready from `after` seconds into a file for
		/// `duration` seconds, to exercise the bounded queues. Leave nil.
		public var debugStallWriter: (after: TimeInterval, duration: TimeInterval)?

		public init(directory: URL = Options.defaultDirectory) {
			self.directory = directory
		}

		public static var defaultDirectory: URL {
			FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/PlayStream", isDirectory: true)
		}
	}

	public struct Stats: Equatable, Sendable {
		/// Frames accepted into a file (equals the frame count of the finished files).
		public var videoFramesWritten = 0
		public var audioBuffersWritten = 0
		/// Frames seen before the first keyframe of the recording (expected, not an error).
		public var videoFramesDiscardedBeforeKeyframe = 0
		/// Frames discarded while resynchronising on a keyframe (after a gap, a format change or an overflow).
		public var videoFramesDiscardedForResync = 0
		/// Frames dropped because the writer could not keep up (bounded queue full).
		public var videoFramesDroppedBackpressure = 0
		/// Frames whose timestamp did not advance.
		public var videoFramesDroppedBadTimestamp = 0
		public var audioBuffersDroppedBackpressure = 0
		/// Silence inserted to cover audio gaps, and audio trimmed to correct accumulated lead.
		public var audioFramesSilenceInserted = 0
		public var audioFramesSkipped = 0
		/// Detected or reported loss events that triggered a keyframe resync.
		public var lossEvents = 0
		public var segmentsStarted = 0
		public var peakPendingVideoFrames = 0
		public var peakPendingAudioBuffers = 0

		/// Everything dropped while recording was wanted (excludes the expected pre-keyframe frames).
		public var droppedVideoFrames: Int {
			videoFramesDiscardedForResync + videoFramesDroppedBackpressure + videoFramesDroppedBadTimestamp
		}
	}
}
