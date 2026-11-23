import Foundation
import QuartzCore
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
	/// Frames received but never handed to the display, for any reason except a deliberate pacer
	/// catch-up skip (`framesSkipped`). Exactly the sum of the `drops*` counters below (plus, on the layer
	/// path, `layerDroppedFrames + layerCorruptedFrames`). In steady state on a clean link it should stay 0;
	/// each reason counter says where a non-zero value comes from.
	public var framesDropped: Int = 0
	/// Not decodable: waiting for a keyframe after a decoder reset / loss, or no usable parameter sets.
	public var dropsAwaitingKeyframe: Int = 0
	/// The decoder reported an error for the frame.
	public var dropsDecodeError: Int = 0
	/// Pacing off only: a newer frame was decoded before the render queue got to this one (newest wins).
	public var dropsSuperseded: Int = 0
	/// Paced queue over capacity (16 pictures, ~133 ms at 120 pictures/s). Should never happen; non-zero means
	/// rendering stalled.
	public var dropsQueueOverflow: Int = 0
	/// No drawable from the layer within 1 s (display asleep / window off screen) or a render setup failure.
	public var dropsNoDrawable: Int = 0
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

	// MARK: Overlay (FPS including generated pictures, frame times)

	/// Pictures put on screen per second over the last second, real + generated. Metal path: counted from
	/// the drawables' presented-time callbacks (what actually reached the glass). Layer path: the layer's
	/// own displayed-frame rate from AVVideoPerformanceMetrics (frames it displayed, not glass timing).
	public var presentedFPS: Double = 0
	/// On-screen interval of each of the most recent pictures, ms, newest last, up to 240 entries
	/// (Metal path, from presented times; empty on the layer path).
	public var recentPresentedIntervalsMs: [Float] = []
	/// Interval between consecutive frame arrivals from the network, ms, newest last, up to 240 (both paths).
	public var recentArrivalIntervalsMs: [Float] = []
	/// 99th percentile and maximum of the presented intervals over the last 5 s, ms (Metal path; nil otherwise).
	public var frameTimeP99Ms: Double?
	public var frameTimeMaxMs: Double?

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
	/// Times the pacing grid was re-based because the console's frame timeline slipped (it skipped a frame).
	public var pacerRebases: Int = 0
	/// How far ahead of its target a paced frame is handed to the system so it can make that vsync,
	/// ms. Learned from feedback (Metal: presented-time misses; layer: the layer's own frame-delay
	/// metric). This is pipeline latency the immediate path pays as well, not extra buffering.
	public var presentationLeadMs: Double = 0
	/// Layer path: average time frames reached the screen after their presentation timestamp over the
	/// last poll (AVVideoPerformanceMetrics), ms. ~0 means the layer is hitting its targets.
	public var layerFrameDelayMs: Double?

	// MARK: Upscaling (Metal path)

	/// Upscaler requested through `VideoPipeline.upscaler`.
	public var upscaler: VideoUpscaler = .off
	/// Upscaler actually running: `.off` on the layer path, when the video rect is not larger than the
	/// video, or before the first frame; `.bicubic` if MetalFX is unsupported.
	public var activeUpscaler: VideoUpscaler = .off
	public var upscaleInputWidth: Int = 0
	public var upscaleInputHeight: Int = 0
	/// Drawable size the picture is rendered at (= video size when not upscaling).
	public var upscaleOutputWidth: Int = 0
	public var upscaleOutputHeight: Int = 0
	/// GPU time of all passes for one frame (conversion + scaling + copy), ms, last second.
	public var renderGPUTimeAvgMs: Double?
	public var renderGPUTimeMaxMs: Double?
	/// GPU time of the scaling pass alone (MetalFX, or FSR 1 EASU + RCAS), ms, last second (nil otherwise).
	public var scalerGPUTimeAvgMs: Double?

	// MARK: Frame generation (Metal path, paced)

	public var frameGeneration: VideoFrameGeneration = .off
	/// "native" (pass-through, no added latency), "fillRepeats" (repeated pictures replaced),
	/// "doubling" (a picture generated between each pair: 30 fps stream, or 60 -> 120).
	public var frameGenerationState: String = "native"
	/// Content frame rate detected from new vs repeated pictures, fps.
	public var contentFPS: Double = 0
	/// Generated pictures shown per second (last second) and in total.
	public var generatedFPS: Double = 0
	public var framesGenerated: Int = 0
	/// Slots where the generated picture was not ready in time or must not be made (shown: the repeat).
	public var frameGenerationFallbacks: Int = 0
	/// Of those, skipped because of a scene cut between the two pictures.
	public var frameGenerationCutsSkipped: Int = 0
	/// Extra hold applied while generating (wait for the next picture + processing), ms. 0 when native.
	public var frameGenerationAddedLatencyMs: Double = 0
	/// Outcome of every generation slot since the stream started, by reason (TraceReason names:
	/// "generated", "deadline_missed", "cut", "loss", "low_confidence", "motion_changing",
	/// "no_motion_history", "static_content", "budget_exceeded", "interpolator_not_ready",
	/// "interpolation_failed", "run_of_repeats", "no_gap_slot", "processing_too_late", "no_previous", "cancelled").
	public var frameGenerationReasons: [String: Int] = [:]
	/// Last interpolation call (VideoToolbox low-latency frame interpolation), ms.
	public var frameGenerationTimeMs: Double = 0
	/// Last 10 -> 8-bit conversion (HDR only) and static-overlay guard, ms (both on the critical path).
	public var frameGenerationConvertMs: Double = 0
	public var frameGenerationGuardMs: Double = 0
	/// Times the slot grid moved by whole slots (later after a real picture would have missed its slot,
	/// earlier after 6 s of spare time). Each one is a single visible hitch.
	public var frameGenerationSlotShifts: Int = 0
	/// Real pictures that arrived too late for their slot (the grid moved later).
	public var frameGenerationLateReal: Int = 0
	/// Most extra delay the generator may add over the non-generating paced path, ms (setting; interpolation).
	public var frameGenerationMaxAddedLatencyMs: Double = 45
	public var frameGenerationMethod: VideoFrameGenerationMethod = .extrapolate
	/// Extrapolation: slots where the motion was not trustworthy (changing, low confidence) and the real
	/// picture stayed on screen instead (included in `frameGenerationFallbacks`).
	public var frameGenerationRejectedMotion: Int = 0
	/// Extrapolation: motion estimation and warp time of the last generated picture, ms.
	public var frameGenerationMotionMs: Double = 0
	public var frameGenerationWarpMs: Double = 0

	// MARK: On-screen cadence (Metal path, from the drawables' presented times; nil on the layer path)

	/// Display refresh rate the presentation is aligned to.
	public var displayRefreshHz: Double?
	/// Mean / max time between consecutive frames reaching the glass, ms (last second).
	public var presentedIntervalAvgMs: Double?
	public var presentedIntervalMaxMs: Double?
	/// Presented intervals that were not the expected number of refreshes (e.g. not 2 at 60 fps on
	/// 120 Hz), cumulative. Each one is a visible judder.
	public var presentedOffCadence: Int = 0
	/// Cumulative histogram of presented intervals in display refreshes: [1, 2, 3, 4, 5, 6+].
	public var presentedRefreshHistogram: [Int] = [0, 0, 0, 0, 0, 0]

	// MARK: Present timing (Metal path, paced): requested vs actual presentation time

	/// Frames that reached the glass on the requested vsync (actual - requested in [0, 1 refresh)).
	public var presentsOnTime: Int = 0
	/// One refresh later than requested.
	public var presentsLate1: Int = 0
	/// Two or more refreshes later than requested.
	public var presentsLate2Plus: Int = 0
	/// Of the late ones (1 or 2+), how many were generated pictures.
	public var presentsLateGenerated: Int = 0
	/// Handed to the compositor but never shown (reported presentedTime 0, e.g. replaced in the same vsync).
	public var presentsNotShown: Int = 0
	/// actual - requested presentation time, ms, last second (avg / max).
	public var presentErrorAvgMs: Double?
	public var presentErrorMaxMs: Double?
	/// requested presentation time - commit time, ms, last second (minimum): how much time the compositor got.
	public var commitAheadMinMs: Double?
	/// Deepest paced queue and longest wait for a drawable in the last second.
	public var pacedQueueDepthMax: Int = 0
	public var drawableWaitMaxMs: Double = 0

	// MARK: Presentation path (Metal; grid-free measurements for variable refresh)

	/// `present.mode` in force: 0 paced grid, 1 lowest latency, 2 smooth.
	public var presentMode: Int = 0
	/// Direct-to-display layout (`present.fullLayer`): layer covers the view, native-resolution drawable.
	public var presentFullLayer: Bool = false
	/// The video's window is in native full screen (nil = no window).
	public var nativeFullScreen: Bool?
	/// Panel limits from NSScreen: shortest / longest refresh interval and update granularity (ms).
	public var displayMinRefreshIntervalMs: Double?
	public var displayMaxRefreshIntervalMs: Double?
	public var displayUpdateGranularityMs: Double?
	/// Re-presents of the last picture to keep the panel in range (not stream frames), and how many of
	/// them the system reported as not shown.
	public var keepAlivePresents: Int = 0
	public var keepAliveNotShown: Int = 0
	/// Pictures presented "as soon as possible" (mode 1, no requested time), cumulative.
	public var asapPresents: Int = 0
	/// On-screen interval minus the picture's own interval (stream interval, or the generated
	/// picture's half interval), ms, last ~600 pictures: p50 / p95 of the absolute error.
	public var presentIntervalErrorP50Ms: Double?
	public var presentIntervalErrorP95Ms: Double?
	/// Cumulative histogram of (on-screen interval - expected), ms: [< -6, -6..-2, -2..2, 2..6, 6..12, > 12].
	public var presentIntervalErrorHistogram: [Int] = [0, 0, 0, 0, 0, 0]
	/// Arrival (network) to on-glass for real pictures, ms, last ~600: p50 / p95.
	public var arrivalToPresentedP50Ms: Double?
	public var arrivalToPresentedP95Ms: Double?
	/// Presented minus requested time (signed, ms) for timed presents, last ~600: p50 / p95.
	public var requestedToPresentedP50Ms: Double?
	public var requestedToPresentedP95Ms: Double?
	/// Display update cadence from NSScreen.lastDisplayUpdateTimestamp (`present.sampleDisplayUpdates`):
	/// interval between panel updates, ms, last ~600, and the mean updates per second over them.
	public var displayUpdateIntervalP50Ms: Double?
	public var displayUpdateIntervalP95Ms: Double?
	public var displayUpdateIntervalMaxMs: Double?
	public var displayUpdatesPerSecond: Double?
	/// Decoder submit-to-output latency, ms, last ~600: p50 / p95 (avg/max per second are above), and the
	/// most pictures inside the decoder at once in the last second (holding pictures shows up here).
	public var decodeLatencyP50Ms: Double?
	public var decodeLatencyP95Ms: Double?
	public var decoderInFlightMax: Int = 0
	/// Metal performance HUD shown on the video layer.
	public var metalHUD: Bool = false
	/// An in-frame overlay image is set.
	public var overlayActive: Bool = false

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
		var gpuSum = 0.0, gpuMax = 0.0, gpuN = 0
		var errSum = 0.0, errMax = 0.0, errN = 0
		var aheadMin = Double.infinity
		var depthMax = 0
		var waitMax = 0.0
		var scalerSum = 0.0, scalerN = 0
		var inFlightMax = 0
	}

	/// Fixed-size ring of floats (no allocation after init).
	struct FloatRing {
		var buf: [Float]
		var head = 0, count = 0
		init(_ n: Int) { buf = [Float](repeating: 0, count: n) }
		mutating func push(_ v: Float) {
			buf[(head + count) % buf.count] = v
			if count < buf.count { count += 1 } else { head = (head + 1) % buf.count }
		}
		func array() -> [Float] { (0..<count).map { buf[(head + $0) % buf.count] } }
		mutating func clear() { head = 0; count = 0 }
	}

	private struct State {
		var presented = FloatRing(240)
		var arrivals = FloatRing(240)
		/// Presented intervals with their time, for the 5 s frame-time percentile (~120 Hz x 5 s).
		var frameTimes = FloatRing(720)
		var frameTimeStamps = [Double](repeating: 0, count: 720)
		var lastPresentedTime = 0.0
		var presentedInWindow = 0
		var presentedWindowStart = 0.0
		var stats = VideoStats()
		var window = Window()
		var lastPublish: UInt64 = 0
		/// Decoded counts/fps come from the display layer's own metrics instead of per-frame callbacks.
		var externalDecode = false
		var intervalError = FloatRing(600)
		var toGlass = FloatRing(600)
		var requestErr = FloatRing(600)
		var displayUpdates = FloatRing(600)
		var decodeLat = FloatRing(600)
	}

	private static func pct(_ r: FloatRing, _ p: Double, abs absolute: Bool = false) -> Double? {
		guard r.count > 0 else { return nil }
		var a = r.array()
		if absolute { a = a.map { Swift.abs($0) } }
		a.sort()
		return Double(a[min(a.count - 1, Int(Double(a.count - 1) * p))])
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
			out.recentPresentedIntervalsMs = s.presented.array()
			out.recentArrivalIntervalsMs = s.arrivals.array()
			// Frame-time p99 / max over the last 5 s of presented intervals.
			let now = CACurrentMediaTime()
			var recent: [Float] = []
			recent.reserveCapacity(s.frameTimes.count)
			for i in 0..<s.frameTimes.count {
				let idx = (s.frameTimes.head + i) % s.frameTimes.buf.count
				if now - s.frameTimeStamps[idx] <= 5 { recent.append(s.frameTimes.buf[idx]) }
			}
			if !recent.isEmpty {
				recent.sort()
				out.frameTimeP99Ms = Double(recent[min(recent.count - 1, Int(Double(recent.count - 1) * 0.99))])
				out.frameTimeMaxMs = Double(recent.last!)
			}
			if s.presentedWindowStart > 0 && now - s.presentedWindowStart > 2 { out.presentedFPS = 0 } // stalled
			out.presentIntervalErrorP50Ms = Self.pct(s.intervalError, 0.5, abs: true)
			out.presentIntervalErrorP95Ms = Self.pct(s.intervalError, 0.95, abs: true)
			out.arrivalToPresentedP50Ms = Self.pct(s.toGlass, 0.5)
			out.arrivalToPresentedP95Ms = Self.pct(s.toGlass, 0.95)
			out.requestedToPresentedP50Ms = Self.pct(s.requestErr, 0.5)
			out.requestedToPresentedP95Ms = Self.pct(s.requestErr, 0.95)
			out.displayUpdateIntervalP50Ms = Self.pct(s.displayUpdates, 0.5)
			out.displayUpdateIntervalP95Ms = Self.pct(s.displayUpdates, 0.95)
			out.displayUpdateIntervalMaxMs = Self.pct(s.displayUpdates, 1)
			if s.displayUpdates.count > 0 {
				let sum = s.displayUpdates.array().reduce(0, +)
				if sum > 0 { out.displayUpdatesPerSecond = Double(s.displayUpdates.count) * 1000 / Double(sum) }
			}
			out.decodeLatencyP50Ms = Self.pct(s.decodeLat, 0.5)
			out.decodeLatencyP95Ms = Self.pct(s.decodeLat, 0.95)
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
			let up = s.stats.upscaler
			let fg = s.stats.frameGeneration
			let keep = s.stats
			s = State()
			// Display / presentation configuration survives a stream restart.
			s.stats.displayMinRefreshIntervalMs = keep.displayMinRefreshIntervalMs
			s.stats.displayMaxRefreshIntervalMs = keep.displayMaxRefreshIntervalMs
			s.stats.displayUpdateGranularityMs = keep.displayUpdateGranularityMs
			s.stats.nativeFullScreen = keep.nativeFullScreen
			s.stats.presentMode = keep.presentMode
			s.stats.presentFullLayer = keep.presentFullLayer
			s.stats.metalHUD = keep.metalHUD
			s.stats.overlayActive = keep.overlayActive
			s.stats.frameGeneration = fg
			s.stats.pacingMode = pacing
			s.stats.presentationLeadMs = lead
			s.stats.upscaler = up
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
			s.stats.renderGPUTimeAvgMs = nil
			s.stats.renderGPUTimeMaxMs = nil
			s.stats.scalerGPUTimeAvgMs = nil
			s.stats.activeUpscaler = .off
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
				s.decodeLat.push(Float(d))
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
			if refreshHz > 0 {
				let n = Int((ms / 1000 * refreshHz).rounded())
				s.stats.presentedRefreshHistogram[min(5, max(0, n - 1))] += 1
			}
			s.stats.displayRefreshHz = refreshHz
		}
	}

	enum DropReason { case awaitingKeyframe, decodeError, superseded, queueOverflow, noDrawable }

	func drop(_ r: DropReason, count: Int = 1) {
		lock.withLock { s in
			s.stats.framesDropped += count
			switch r {
			case .awaitingKeyframe: s.stats.dropsAwaitingKeyframe += count
			case .decodeError: s.stats.dropsDecodeError += count
			case .superseded: s.stats.dropsSuperseded += count
			case .queueOverflow: s.stats.dropsQueueOverflow += count
			case .noDrawable: s.stats.dropsNoDrawable += count
			}
		}
	}

	/// A paced frame reached the glass `errorMs` after its requested time.
	func presentTiming(errorMs: Double, refresh: Double, generated: Bool = false) {
		lock.withLock { s in
			let r = errorMs / 1000 / refresh
			if r < 1 { s.stats.presentsOnTime += 1 } else if r < 2 { s.stats.presentsLate1 += 1 } else { s.stats.presentsLate2Plus += 1 }
			if r >= 1 && generated { s.stats.presentsLateGenerated += 1 }
			s.window.errSum += errorMs
			s.window.errN += 1
			s.window.errMax = max(s.window.errMax, errorMs)
		}
	}

	/// Grid-free cadence: one picture stayed `intervalMs` on screen where `expectedMs` was intended.
	func presentedVRR(intervalMs: Double, expectedMs: Double) {
		lock.withLock { s in
			let e = intervalMs - expectedMs
			s.intervalError.push(Float(e))
			let b = e < -6 ? 0 : e < -2 ? 1 : e <= 2 ? 2 : e <= 6 ? 3 : e <= 12 ? 4 : 5
			s.stats.presentIntervalErrorHistogram[b] += 1
		}
	}

	func arrivalToPresented(ms: Double) {
		lock.withLock { $0.toGlass.push(Float(ms)) }
	}

	func requestedToPresented(ms: Double) {
		lock.withLock { $0.requestErr.push(Float(ms)) }
	}

	func keepAlive(issued: Bool = false, notShown: Bool = false) {
		lock.withLock { s in
			if issued { s.stats.keepAlivePresents += 1 }
			if notShown { s.stats.keepAliveNotShown += 1 }
		}
	}

	func asapPresent() {
		lock.withLock { $0.stats.asapPresents += 1 }
	}

	/// The panel updated `ms` after its previous update (NSScreen.lastDisplayUpdateTimestamp).
	func displayUpdate(intervalMs ms: Double) {
		lock.withLock { $0.displayUpdates.push(Float(ms)) }
	}

	func decoderInFlight(_ n: Int) {
		lock.withLock { s in s.window.inFlightMax = max(s.window.inFlightMax, n) }
	}

	func presentNotShown() {
		lock.withLock { $0.stats.presentsNotShown += 1 }
	}

	func pacedCommit(aheadMs: Double, queueDepth: Int, drawableWaitMs: Double) {
		lock.withLock { s in
			s.window.aheadMin = min(s.window.aheadMin, aheadMs)
			s.window.depthMax = max(s.window.depthMax, queueDepth)
			s.window.waitMax = max(s.window.waitMax, drawableWaitMs)
		}
	}

	/// A picture reached the glass at host time `t` (Metal path, every presented drawable).
	func presented(at t: Double) {
		lock.withLock { s in
			if s.lastPresentedTime > 0 && t > s.lastPresentedTime {
				let ms = Float((t - s.lastPresentedTime) * 1000)
				if ms < 1000 {
					s.presented.push(ms)
					let idx = (s.frameTimes.head + s.frameTimes.count) % s.frameTimes.buf.count
					s.frameTimes.push(ms)
					s.frameTimeStamps[idx] = t
				}
			}
			s.lastPresentedTime = max(s.lastPresentedTime, t)
			if s.presentedWindowStart == 0 { s.presentedWindowStart = t }
			s.presentedInWindow += 1
			if t - s.presentedWindowStart >= 1 {
				s.stats.presentedFPS = Double(s.presentedInWindow) / (t - s.presentedWindowStart)
				s.presentedInWindow = 0
				s.presentedWindowStart = t
			}
		}
	}

	/// A frame arrived `ms` after the previous one (both paths).
	func arrival(intervalMs ms: Double) {
		lock.withLock { $0.arrivals.push(Float(ms)) }
	}

	func renderGPU(ms: Double) {
		lock.withLock { s in
			s.window.gpuSum += ms
			s.window.gpuN += 1
			s.window.gpuMax = max(s.window.gpuMax, ms)
		}
	}

	func scalerGPU(ms: Double) {
		lock.withLock { s in
			s.window.scalerSum += ms
			s.window.scalerN += 1
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
		if w.gpuN > 0 {
			s.stats.renderGPUTimeAvgMs = w.gpuSum / Double(w.gpuN)
			s.stats.renderGPUTimeMaxMs = w.gpuMax
		}
		s.stats.scalerGPUTimeAvgMs = w.scalerN > 0 ? w.scalerSum / Double(w.scalerN) : nil
		if w.errN > 0 {
			s.stats.presentErrorAvgMs = w.errSum / Double(w.errN)
			s.stats.presentErrorMaxMs = w.errMax
		}
		if w.aheadMin.isFinite { s.stats.commitAheadMinMs = w.aheadMin }
		s.stats.pacedQueueDepthMax = w.depthMax
		s.stats.drawableWaitMaxMs = w.waitMax
		s.stats.decoderInFlightMax = w.inFlightMax
		if w.presentN > 0 {
			s.stats.presentedIntervalAvgMs = w.presentSum / Double(w.presentN)
			s.stats.presentedIntervalMaxMs = w.presentMax
		}
		s.window = Window(start: now)
		s.lastPublish = now
	}
}
