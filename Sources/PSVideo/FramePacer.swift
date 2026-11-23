import Foundation

/// When a frame should be shown. Host-clock seconds (same timebase as `CACurrentMediaTime()`).
struct FrameSchedule {
	/// Presentation target, nil = show immediately (pacing off).
	var target: Double?
	/// Decode the frame (it is a reference) but do not show it: we are catching up after a burst.
	var skip: Bool
	/// Arrived after its slot (only meaningful when paced).
	var late = false
	/// Stream frame interval the grid runs at, seconds.
	var interval = 1.0 / 60
	/// Frames were lost / repaired just before this one (frame generation must not bridge it).
	var discontinuity = false
	/// Best-case arrival grid time of this frame (base + k*T), host seconds.
	var grid = 0.0
	/// Raw jitter allowance (high percentile of lateness + margin, not clamped to the minimum delay), s.
	var jitter = 0.0
	/// Delay the pacer applies (target - grid), s.
	var pacerDelay = 0.0
	/// Late by a whole interval (missed console frame / stall).
	var outlier = false
	/// Trace record of this frame.
	var traceID = 0
	static let immediate = FrameSchedule(target: nil, skip: false)
}

@inline(__always)
func hostSeconds(_ ticks: UInt64) -> Double {
	Double(ticks) * Double(StatsCollector.timebase.numer) / Double(StatsCollector.timebase.denom) / 1e9
}

/// Adaptive playout scheduler (jitter buffer) for the stream thread.
///
/// Model: frame k ideally arrives at `base + k*T` (T = stream frame interval, k counts lost frames
/// too). `base` is the earliest relative arrival seen in the last 2 s, so `lateness = arrival -
/// (base + k*T)` is >= 0 and measures how much the network delayed this frame compared to the best
/// case. Every frame is shown at `base + k*T + delay`: a steady grid, offset by an adaptive delay.
///
/// - `targetDelay` = high percentile of lateness over the last 2 s + margin, clamped to
///   [minDelay, maxDelay]. Rises at once, decays at `decayPerSecond`.
/// - `delay` (applied) follows `targetDelay`: up at once (one frame is held a little longer), down by
///   at most `catchUp` (10%) of a frame interval per frame (slightly shortened intervals, no jump), or
///   `fastCatchUp` (50%) while above `maxDelay`, i.e. a burst backlog is played out quickly.
/// - A frame later than its slot is shown at once and the grid re-anchors (`delay = lateness`).
/// - If `delay` exceeds `targetDelay` by more than `skipFrames` intervals (badly behind after a long
///   stall), frames are skipped (decoded, not shown) until it doesn't. Latency cannot creep up.
final class FramePacer {
	// Tunables (snapshot taken once per frame; see Tunables.specs for meanings and ranges).
	let tunables: Tunables
	private var t = TunableValues()
	var minDelay: Double { t.pacerMinDelayMs / 1000 }
	var maxDelay: Double { t.pacerMaxDelayMs / 1000 }
	var percentile: Double { t.pacerPercentile }
	var margin: Double { t.pacerMarginMs / 1000 }
	var decayPerSecond: Double { t.pacerDecayMsPerSecond / 1000 }
	var catchUp: Double { t.pacerCatchUp }
	var fastCatchUp: Double { t.pacerFastCatchUp }
	var skipFrames: Double { t.pacerSkipFrames }

	init(tunables: Tunables = Tunables()) {
		self.tunables = tunables
		t = tunables.values
	}

	private(set) var interval = 1.0 / 60
	private var nominalFPS = 60.0

	// Grid state.
	private var started = false
	private var k: Int64 = 0
	private var base = 0.0
	private var lastArrival = 0.0
	private var slipRun: [Double] = []
	private var lastTarget = -Double.infinity
	/// Outlier handling (ignore whole-interval lateness in the estimator, re-base on slips). Diagnostics
	/// can turn it off to compare with the previous behaviour.
	var robustOutliers = true
	/// Times the grid was re-based because the console's frame timeline slipped.
	private(set) var rebases = 0
	private var startArrival = 0.0
	private(set) var delay = 1.0 / 60
	private(set) var targetDelay = 1.0 / 60

	// 2 s window of relative arrivals (o = arrival - k*T) and lateness.
	private var offsets = Ring(capacity: 1024)
	private var lateness = Ring(capacity: 1024)
	private var scratch = [Double](repeating: 0, count: 2048)

	// 5 s window of inter-arrival jitter and gaps, for stats.
	private var jitter = Ring(capacity: 2048)
	private var gaps = Ring(capacity: 2048)

	// Frame-rate detection.
	private var rateMismatchFrames = 0


	func reset(fps: Int) {
		nominalFPS = Double(max(1, fps))
		interval = 1 / nominalFPS
		restartGrid()
		jitter.removeAll()
		gaps.removeAll()
		rateMismatchFrames = 0
	}

	private func restartGrid() {
		started = false
		lastTarget = -Double.infinity
		slipRun.removeAll()
		offsets.removeAll()
		lateness.removeAll()
		delay = minDelay
		targetDelay = minDelay
	}

	/// Window sizes in frames for the current frame rate.
	private var analysisFrames: Int { min(offsets.capacity, max(8, Int((t.pacerWindowSeconds / interval).rounded()))) }
	private var statsFrames: Int { min(jitter.capacity, max(8, Int((t.pacerStatsWindowSeconds / interval).rounded()))) }

	func schedule(arrival a: Double, framesLost: Int) -> FrameSchedule {
		t = tunables.values
		let lost = max(0, framesLost)
		if !started {
			started = true
			k = 0
			base = a
			lastArrival = a
			startArrival = a
			delay = minDelay
			targetDelay = minDelay
			offsets.push(a, limit: analysisFrames)
			lateness.push(0, limit: analysisFrames)
			return FrameSchedule(target: a + delay, skip: false, late: false, interval: interval, grid: a, jitter: margin, pacerDelay: delay)
		}

		// Arrival statistics.
		let gap = a - lastArrival
		lastArrival = a
		jitter.push(abs(gap - interval * Double(1 + lost)), limit: statsFrames)
		gaps.push(gap, limit: statsFrames)

		k += Int64(1 + lost)
		let o = a - Double(k) * interval
		offsets.push(o, limit: analysisFrames)
		base = offsets.minimum()
		if detectFrameRate() { return schedule(arrival: a, framesLost: lost) }
		var late = max(0, o - base)
		// A frame late by most of an interval or more is not jitter: the console did not deliver a frame
		// for a tick (its timeline slipped), or the network stalled. A playout delay shorter than a frame
		// cannot hide either, so such samples do not feed the delay estimator; the frame is handled as late.
		// At 30 fps (or lower) a slip is one whole interval, longer than any useful delay. At 60 fps the
		// maximum delay can cover a couple of frames of jitter, so only lateness the buffer could never
		// absorb counts as an outlier there.
		let lowRate = interval > 1.0 / 45
		let outlier = robustOutliers && late >= t.pacerOutlierFraction * interval && (lowRate || late >= t.pacerOutlierMaxDelayFraction * maxDelay)
		if outlier {
			slipRun.append(late)
			if slipRun.count >= Int(t.pacerRebaseCount), let lo = slipRun.min(), let hi = slipRun.max(), hi - lo < t.pacerRebaseSpreadFraction * interval {
				// Two frames in a row late by the same amount: the console's timeline moved. Re-base the grid
				// on the new timeline at once (instead of after the 2 s window).
				offsets.removeAll()
				offsets.push(o, limit: analysisFrames)
				base = o
				late = 0
				slipRun.removeAll()
				rebases += 1
			}
		} else {
			slipRun.removeAll()
		}
		// Stream start (decoder creation, first IDR) delays the first frames once; don't let that
		// one-off set the playout delay for the next seconds. Late frames still re-anchor below.
		if !outlier { lateness.push(a - startArrival < t.pacerWarmupSeconds ? 0 : late, limit: analysisFrames) }

		// Target delay from the lateness distribution.
		let p = lateness.percentile(percentile, scratch: &scratch) + margin
		let raw = min(maxDelay, max(minDelay, p))
		if raw >= targetDelay {
			targetDelay = raw
		} else {
			targetDelay = max(raw, targetDelay - decayPerSecond * interval)
		}
		targetDelay = min(maxDelay, max(minDelay, targetDelay))

		// Applied delay.
		var isLate = false
		if outlier {
			// Whole-interval late (console skipped a frame, or a stall): leave the delay alone and show the
			// frame `delay` after its actual arrival, as if its timeline had moved. Burst frames behind it
			// that would land on an already-shown picture are skipped below. No latency is added afterwards.
			isLate = true
			let target = a + delay
			let skip = target < lastTarget + t.pacerBurstSkipFraction * interval
			if !skip { lastTarget = target }
			return FrameSchedule(target: target, skip: skip, late: true, interval: interval, grid: base + Double(k) * interval,
			                     jitter: min(lateness.percentile(percentile, scratch: &scratch) + margin, maxDelay), pacerDelay: delay, outlier: true)
		} else if late > delay + 0.0005 {
			isLate = true
			delay = late // shown at once; the grid re-anchors on this frame
		} else if delay < targetDelay {
			delay = targetDelay
		} else if delay > targetDelay {
			// Above the configured maximum (backlog after a stall longer than the buffer) play the
			// backlog out at up to 2x (one refresh per frame at 60 fps on 120 Hz); inside the normal
			// range shorten intervals only slightly.
			let rate = delay > maxDelay ? fastCatchUp : catchUp
			delay -= min(delay - targetDelay, rate * interval)
		}

		var skip = false
		// Never skip while the grid itself is unproven (too little history or a suspected rate change).
		if rateMismatchFrames == 0 && offsets.count >= 24 && delay - targetDelay > skipFrames * interval {
			skip = true
			delay -= interval
		}
		let grid = base + Double(k) * interval
		var target = max(a, grid + delay)
		// Never land on (or before) the picture just shown: such a frame is part of a burst after a stall.
		if target < lastTarget + t.pacerBurstSkipFraction * interval {
			skip = true
		} else {
			lastTarget = target
		}
		if skip { target = max(target, lastTarget) }
		return FrameSchedule(target: target, skip: skip, late: isLate, interval: interval, grid: grid, jitter: min(p, maxDelay), pacerDelay: target - grid)
	}

	/// The console can drop to a lower frame rate (e.g. 30 fps); the grid must follow at once or
	/// every frame would look later than the last. With the right interval the relative arrivals
	/// `o = arrival - k*T` are flat; with the wrong one their lower envelope drifts by the error each
	/// frame. Lower envelope = minimum of each half of the 2 s window, so stalls and bursts (which only
	/// push arrivals later) do not disturb it. Snaps to nominal, /2, /3, /4. Returns true if the grid
	/// was restarted (the caller re-schedules the frame on the new grid).
	private func detectFrameRate() -> Bool {
		let n = offsets.count
		guard n >= 24 else { return false }
		let half = n / 2
		let m1 = offsets.minimum(from: 0, to: half)
		let m2 = offsets.minimum(from: half, to: n)
		let estimated = interval + (m2 - m1) / Double(half)
		guard estimated > 0 else { return false }
		var snapped = 1 / estimated
		for div in [1.0, 2.0, 3.0, 4.0] {
			let cand = nominalFPS / div
			if abs(snapped - cand) / cand < t.pacerRateTolerance { snapped = cand; break }
		}
		let current = 1 / interval
		if abs(snapped - current) / current < t.pacerRateTolerance {
			rateMismatchFrames = 0
			return false
		}
		rateMismatchFrames += 1
		guard rateMismatchFrames >= Int(t.pacerRateMismatchFrames) else { return false }
		rateMismatchFrames = 0
		interval = 1 / snapped
		NSLog("[PSVideo] stream frame rate now %.1f fps (pacing grid follows)", snapped)
		let keepDelay = delay
		restartGrid()
		delay = max(minDelay, min(keepDelay, maxDelay))
		return true
	}

	struct ArrivalStats {
		var jitterAvg = 0.0, jitterP95 = 0.0, maxGap = 0.0
	}

	func arrivalStats() -> ArrivalStats {
		guard jitter.count > 0 else { return ArrivalStats() }
		return ArrivalStats(jitterAvg: jitter.mean(), jitterP95: jitter.percentile(0.95, scratch: &scratch), maxGap: gaps.maximum())
	}
}

/// Fixed-capacity ring of doubles (no allocation after init).
struct Ring {
	private var buf: [Double]
	private var head = 0
	private(set) var count = 0
	let capacity: Int

	init(capacity: Int) {
		self.capacity = capacity
		buf = [Double](repeating: 0, count: capacity)
	}

	mutating func removeAll() {
		head = 0
		count = 0
	}

	/// Appends, keeping at most `limit` (<= capacity) newest values.
	mutating func push(_ v: Double, limit: Int) {
		let lim = min(limit, capacity)
		buf[(head + count) % capacity] = v
		if count < capacity { count += 1 } else { head = (head + 1) % capacity }
		while count > lim {
			head = (head + 1) % capacity
			count -= 1
		}
	}

	func minimum() -> Double { minimum(from: 0, to: count) }

	/// Minimum of the values at positions from..<to (0 = oldest).
	func minimum(from: Int, to: Int) -> Double {
		var m = Double.infinity
		for i in from..<Swift.min(to, count) { m = Swift.min(m, buf[(head + i) % capacity]) }
		return m
	}

	func maximum() -> Double {
		var m = -Double.infinity
		for i in 0..<count { m = Swift.max(m, buf[(head + i) % capacity]) }
		return m
	}

	func mean() -> Double {
		guard count > 0 else { return 0 }
		var s = 0.0
		for i in 0..<count { s += buf[(head + i) % capacity] }
		return s / Double(count)
	}

	func percentile(_ p: Double, scratch: inout [Double]) -> Double {
		guard count > 0 else { return 0 }
		if scratch.count < count { scratch = [Double](repeating: 0, count: count) }
		for i in 0..<count { scratch[i] = buf[(head + i) % capacity] }
		scratch.withUnsafeMutableBufferPointer { $0[0..<count].sort() }
		let idx = Swift.min(count - 1, Int((p * Double(count - 1)).rounded()))
		return scratch[idx]
	}
}
