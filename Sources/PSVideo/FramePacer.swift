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
	// Tunables.
	var minDelay = 1.0 / 60
	var maxDelay = 0.050
	let percentile = 0.99
	let margin = 0.002
	let decayPerSecond = 0.010
	let catchUp = 0.10
	let fastCatchUp = 0.50
	let skipFrames = 3.0

	private(set) var interval = 1.0 / 60
	private var nominalFPS = 60.0

	// Grid state.
	private var started = false
	private var k: Int64 = 0
	private var base = 0.0
	private var lastArrival = 0.0
	private var startArrival = 0.0
	private(set) var delay = 1.0 / 60
	private(set) var targetDelay = 1.0 / 60

	// 2 s window of relative arrivals (o = arrival - k*T) and lateness.
	private var offsets = Ring(capacity: 256)
	private var lateness = Ring(capacity: 256)
	private var scratch = [Double](repeating: 0, count: 512)

	// 5 s window of inter-arrival jitter and gaps, for stats.
	private var jitter = Ring(capacity: 512)
	private var gaps = Ring(capacity: 512)

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
		offsets.removeAll()
		lateness.removeAll()
		delay = minDelay
		targetDelay = minDelay
	}

	/// Window sizes in frames for the current frame rate.
	private var analysisFrames: Int { min(offsets.capacity, max(8, Int((2.0 / interval).rounded()))) }
	private var statsFrames: Int { min(jitter.capacity, max(8, Int((5.0 / interval).rounded()))) }

	func schedule(arrival a: Double, framesLost: Int) -> FrameSchedule {
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
		let late = max(0, o - base)
		// Stream start (decoder creation, first IDR) delays the first frames once; don't let that
		// one-off set the playout delay for the next seconds. Late frames still re-anchor below.
		lateness.push(a - startArrival < 0.5 ? 0 : late, limit: analysisFrames)

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
		if late > delay + 0.0005 {
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
		let target = max(a, grid + delay)
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
			if abs(snapped - cand) / cand < 0.12 { snapped = cand; break }
		}
		let current = 1 / interval
		if abs(snapped - current) / current < 0.12 {
			rateMismatchFrames = 0
			return false
		}
		rateMismatchFrames += 1
		guard rateMismatchFrames >= 10 else { return false }
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
