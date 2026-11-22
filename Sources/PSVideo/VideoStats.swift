import Foundation
import os
import PSContracts

/// Snapshot of the pipeline's live statistics. Read `VideoPipeline.stats` from any thread
/// (typically a 1-4 Hz timer on the main thread); it is a value copy taken under a short lock.
public struct VideoStats: Sendable, Equatable {
	public var codec: VideoCodec?
	public var displayMode: VideoDisplayMode = .sampleBufferLayer
	public var width: Int = 0
	public var height: Int = 0
	/// The format description carries a PQ / HLG transfer function (HDR content is being shown).
	public var hdrActive: Bool = false
	/// Colour tags of the current format description.
	public var color: VideoColorInfo?

	/// Buffers handed to `videoStreamDidReceive` that contained a frame (the stream header is not counted).
	public var framesReceived: Int = 0
	/// Frames the decoder produced a picture for.
	public var framesDecoded: Int = 0
	/// Frames received but not decoded/shown: waiting for a keyframe, decode errors, or superseded by a
	/// newer frame before they could be shown.
	public var framesDropped: Int = 0
	/// Sample-buffer-layer path: frames the layer itself dropped / found corrupt (included in `framesDropped`).
	public var layerDroppedFrames: Int = 0
	public var layerCorruptedFrames: Int = 0
	/// Sum of `framesLost` reported by the core (lost on the network before reaching us).
	public var framesLostInNetwork: Int = 0
	/// Frames the core repaired (FEC or reference-frame substitution).
	public var framesRecovered: Int = 0
	public var keyframesReceived: Int = 0
	public var decodeErrors: Int = 0
	/// Times we asked for a keyframe out of band (keyframeRequester).
	public var keyframeRequests: Int = 0
	/// Times `videoStreamDidReceive` returned false.
	public var framesRejected: Int = 0

	/// Decoded frames per second over the last full second.
	public var decodedFPS: Double = 0
	/// Hardware decode time (submit to decoded picture), ms. Only measured on the Metal path;
	/// nil for the sample-buffer-layer path where decoding happens inside the layer.
	public var decodeTimeAvgMs: Double?
	public var decodeTimeMaxMs: Double?
	/// Arrival (network callback) to hand-off for display, ms. For the layer path that is the enqueue;
	/// for the Metal path it is the moment the frame's present was committed to the GPU.
	public var handoffAvgMs: Double = 0
	public var handoffMaxMs: Double = 0
	/// Arrival to the frame actually reaching the glass (Metal path only, from the drawable's presented time).
	public var glassAvgMs: Double?
	/// Current display EDR headroom (1.0 = SDR display or HDR not engaged).
	public var edrHeadroom: Double = 1

	// MARK: Pacing and network arrival (arrival figures cover the last 5 s)

	public var pacingMode: VideoPacingMode = .adaptive
	/// Frame rate the pacing grid is running at (follows the console, e.g. 60 -> 30).
	public var streamFPS: Double = 0
	/// Mean |inter-arrival time - frame interval| of frame buffers, ms.
	public var arrivalJitterAvgMs: Double = 0
	/// 95th percentile of the same, ms.
	public var arrivalJitterP95Ms: Double = 0
	/// Longest gap between two frame arrivals, ms (a Wi-Fi stall shows up here).
	public var arrivalMaxGapMs: Double = 0
	/// Playout delay currently applied on top of the best-case arrival time, ms (0 when pacing is off).
	public var playoutDelayMs: Double = 0
	/// Delay the pacer is converging to (jitter percentile + margin, clamped), ms.
	public var playoutTargetDelayMs: Double = 0
	/// Frames that arrived after their presentation slot (shown at once, grid re-anchored).
	public var framesLate: Int = 0
	/// Frames decoded but not shown to catch up after a long stall.
	public var framesSkipped: Int = 0
	/// How far ahead of its target a paced frame is handed to the system so it can make that vsync,
	/// ms. Learned from feedback (Metal: presented-time misses; layer: the layer's own frame-delay
	/// metric). This is pipeline latency the immediate path pays as well, not extra buffering.
	public var presentationLeadMs: Double = 0
	/// Layer path: average time frames reached the screen after their presentation timestamp over the
	/// last poll (AVVideoPerformanceMetrics), ms. ~0 means the layer is hitting its targets.
	public var layerFrameDelayMs: Double?

	// MARK: On-screen cadence (Metal path, from the drawables' presented times; nil on the layer path)

	/// Display refresh rate the presentation is aligned to.
	public var displayRefreshHz: Double?
	/// Mean / max time between consecutive frames reaching the glass, ms (last second).
	public var presentedIntervalAvgMs: Double?
	public var presentedIntervalMaxMs: Double?
	/// Presented intervals that were not the expected number of refreshes (e.g. not 2 at 60 fps on
	/// 120 Hz), cumulative. Each one is a visible judder.
	public var presentedOffCadence: Int = 0

	public init() {}
}

/// Accumulates stats on producer threads; publishes a per-second window. All access under one unfair lock.
final class StatsCollector: @unchecked Sendable {
	private struct Window {
		var start: UInt64 = 0
		var decoded = 0
		var decodeSum = 0.0, decodeMax = 0.0, decodeN = 0
		var handoffSum = 0.0, handoffMax = 0.0, handoffN = 0
		var glassSum = 0.0, glassN = 0
		var presentSum = 0.0, presentMax = 0.0, presentN = 0
	}

	private struct State {
		var stats = VideoStats()
		var window = Window()
		var lastPublish: UInt64 = 0
		/// Decoded counts/fps come from the display layer's own metrics instead of per-frame callbacks.
		var externalDecode = false
	}

	private let lock = OSAllocatedUnfairLock(initialState: State())

	static let timebase: mach_timebase_info_data_t = {
		var tb = mach_timebase_info_data_t()
		mach_timebase_info(&tb)
		return tb
	}()

	@inline(__always)
	static func ms(from start: UInt64, to end: UInt64) -> Double {
		guard end > start else { return 0 }
		return Double(end - start) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
	}

	func snapshot() -> VideoStats {
		lock.withLock { s in
			var out = s.stats
			out.framesDropped += out.layerDroppedFrames + out.layerCorruptedFrames
			// No completed window for 2 s: the stream is stalled.
			if !s.externalDecode && s.lastPublish != 0 && Self.ms(from: s.lastPublish, to: mach_absolute_time()) > 2000 {
				out.decodedFPS = 0
			}
			return out
		}
	}

	func reset(codec: VideoCodec?, mode: VideoDisplayMode) {
		lock.withLock { s in
			let headroom = s.stats.edrHeadroom
			let pacing = s.stats.pacingMode
			let lead = s.stats.presentationLeadMs
			s = State()
			s.stats.pacingMode = pacing
			s.stats.presentationLeadMs = lead
			s.stats.codec = codec
			s.stats.displayMode = mode
			s.stats.edrHeadroom = headroom
			s.externalDecode = mode == .sampleBufferLayer
		}
	}

	/// Display path changed mid-stream: per-path measurements start over, counters are kept.
	func switchMode(_ mode: VideoDisplayMode) {
		lock.withLock { s in
			s.stats.displayMode = mode
			s.stats.decodeTimeAvgMs = nil
			s.stats.decodeTimeMaxMs = nil
			s.stats.glassAvgMs = nil
			s.stats.presentedIntervalAvgMs = nil
			s.stats.presentedIntervalMaxMs = nil
			s.stats.displayRefreshHz = nil
			s.stats.layerDroppedFrames = 0
			s.stats.layerCorruptedFrames = 0
			s.externalDecode = mode == .sampleBufferLayer
			s.window = Window()
		}
	}

	func update(_ body: (inout VideoStats) -> Void) {
		lock.withLock { body(&$0.stats) }
	}

	func frameDecoded(decodeMs: Double?) {
		lock.withLock { s in
			s.stats.framesDecoded += 1
			s.window.decoded += 1
			if let d = decodeMs {
				s.window.decodeSum += d
				s.window.decodeN += 1
				s.window.decodeMax = max(s.window.decodeMax, d)
			}
			Self.rollIfNeeded(&s)
		}
	}

	func handedOff(ms: Double) {
		lock.withLock { s in
			s.window.handoffSum += ms
			s.window.handoffN += 1
			s.window.handoffMax = max(s.window.handoffMax, ms)
			Self.rollIfNeeded(&s)
		}
	}

	/// One frame reached the glass `intervalMs` after the previous one.
	func presentedInterval(ms: Double, offCadence: Bool, refreshHz: Double) {
		lock.withLock { s in
			s.window.presentSum += ms
			s.window.presentN += 1
			s.window.presentMax = max(s.window.presentMax, ms)
			if offCadence { s.stats.presentedOffCadence += 1 }
			s.stats.displayRefreshHz = refreshHz
		}
	}

	func onGlass(ms: Double) {
		lock.withLock { s in
			s.window.glassSum += ms
			s.window.glassN += 1
		}
	}

	private static func rollIfNeeded(_ s: inout State) {
		let now = mach_absolute_time()
		if s.window.start == 0 { s.window.start = now; return }
		let elapsed = ms(from: s.window.start, to: now)
		guard elapsed >= 1000 else { return }
		let w = s.window
		if !s.externalDecode { s.stats.decodedFPS = Double(w.decoded) * 1000 / elapsed }
		if w.decodeN > 0 {
			s.stats.decodeTimeAvgMs = w.decodeSum / Double(w.decodeN)
			s.stats.decodeTimeMaxMs = w.decodeMax
		}
		if w.handoffN > 0 {
			s.stats.handoffAvgMs = w.handoffSum / Double(w.handoffN)
			s.stats.handoffMaxMs = w.handoffMax
		}
		if w.glassN > 0 { s.stats.glassAvgMs = w.glassSum / Double(w.glassN) }
		if w.presentN > 0 {
			s.stats.presentedIntervalAvgMs = w.presentSum / Double(w.presentN)
			s.stats.presentedIntervalMaxMs = w.presentMax
		}
		s.window = Window(start: now)
		s.lastPublish = now
	}
}
