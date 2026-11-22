import Foundation

/// Producer-thread-only measurement of inter-arrival gaps. Keeps the longest gap of each second
/// (a 64-second ring) and publishes, through atomics on the core:
///  - `needMicros`: longest gap in the last `windowSeconds` plus a margin: the fill that rides out the worst recent stall
///  - `longestGapMicros`: longest gap in the last 10 s
///  - `gapPctMicros`: 95th percentile of the per-second maxima over the last 60 s
final class GapTracker {
	static let ringSize = 64
	static let percentile = 0.95

	private let maxes = UnsafeMutablePointer<Double>.allocate(capacity: ringSize)
	private let scratch = UnsafeMutablePointer<Double>.allocate(capacity: ringSize)
	private var t0 = 0.0
	private var last = -1.0
	private var second = 0
	var windowSeconds = 30
	var marginMs = 15.0

	init() {
		maxes.initialize(repeating: 0, count: Self.ringSize)
		scratch.initialize(repeating: 0, count: Self.ringSize)
	}

	deinit {
		maxes.deallocate()
		scratch.deallocate()
	}

	func reset(_ core: AudioRenderCore) {
		last = -1
		for i in 0..<Self.ringSize { maxes[i] = 0 }
		core.needMicros.store(0, ordering: .relaxed)
		core.longestGapMicros.store(0, ordering: .relaxed)
		core.gapPctMicros.store(0, ordering: .relaxed)
	}

	/// `t` is the arrival time in seconds on any monotonic clock.
	func note(_ t: Double, core: AudioRenderCore) {
		if last < 0 {
			t0 = t
			last = t
			second = 0
			return
		}
		let gapMs = max(0, (t - last) * 1000)
		last = t
		let b = max(second, Int(t - t0))
		var rolled = false
		if b > second {
			if b - second >= Self.ringSize {
				for i in 0..<Self.ringSize { maxes[i] = 0 }
			} else {
				var s = second + 1
				while s <= b { maxes[s % Self.ringSize] = 0; s += 1 }
			}
			second = b
			rolled = true
		}
		let idx = second % Self.ringSize
		if gapMs > maxes[idx] { maxes[idx] = gapMs }
		if rolled || gapMs > 20 { publish(core) }
	}

	private func windowMax(_ seconds: Int) -> Double {
		var m = 0.0
		let n = min(seconds, second + 1)
		for k in 0..<n { m = max(m, maxes[(second - k) % Self.ringSize]) }
		return m
	}

	private func publish(_ core: AudioRenderCore) {
		let need = windowMax(windowSeconds) + marginMs
		core.needMicros.store(Int(need * 1000), ordering: .relaxed)
		core.longestGapMicros.store(Int(windowMax(10) * 1000), ordering: .relaxed)
		// Percentile of the per-second maxima over up to 60 s (insertion sort of <= 60 values).
		let n = min(60, second + 1)
		for k in 0..<n {
			let v = maxes[(second - k) % Self.ringSize]
			var j = k
			while j > 0 && scratch[j - 1] > v { scratch[j] = scratch[j - 1]; j -= 1 }
			scratch[j] = v
		}
		let rank = min(n - 1, Int((Double(n) * Self.percentile).rounded(.up)) - 1)
		core.gapPctMicros.store(Int(scratch[max(0, rank)] * 1000), ordering: .relaxed)
	}
}
