import Foundation
import Synchronization

/// Plain-old-data state owned exclusively by the consumer (render) side. Lives behind an
/// UnsafeMutablePointer so the render thread never goes through class-property exclusivity checks.
struct RenderState {
	var playing = false
	var readIdx = 0
	var frac = 0.0
	var ema = 0.0
	var ratioAdj = 0.0
	/// Slow integral term: learns the sender's clock offset (clamped to +-0.3 %).
	var trim = 0.0
	var xfRemaining = 0
	var xfLen = 0
	var xfSkip = 0
	var ramp = 0
	var gain: Float = 0
	var lastL: Float = 0
	var lastR: Float = 0
	/// Current (adaptive) target fill in source frames; 0 until first render.
	var target = 0.0
	/// Set by an underrun: resume early (the backlog usually arrives in one burst) instead of priming to the full target.
	var resuming = false
	/// Frames left before another underrun may raise the target.
	var bumpCooldown = 0
	/// Near-underrun tracking over ~1 s windows.
	var minFill = Int.max
	var tickFrames = 0
}

/// Lock-free single-producer / single-consumer ring of stereo float frames plus the render
/// routine that drains it with jitter-buffer policy.
///
/// Producer (network thread): `write`. Consumer (audio render thread): `render`.
/// Everything the two sides share is an atomic; the ring indices are monotonically increasing
/// frame counts (never wrapped), so `write - read` is the fill level.
final class AudioRenderCore {
	static let capacity = 1 << 16  // frames; power of two. ~1.4 s at 48 kHz.
	static let mask = capacity - 1

	let ring: UnsafeMutablePointer<Float>
	let state: UnsafeMutablePointer<RenderState>
	/// Tone, voice boost, dynamics and limiter. Touched by the render thread only.
	let effects: UnsafeMutablePointer<EffectsState>

	let writeIdx = Atomic<Int>(0)
	let readIdx = Atomic<Int>(0)
	/// True while a consumer is (about to be) running. When false the producer discards input.
	let active = Atomic<Bool>(false)

	// Configuration (control side writes, render reads).
	let srcRate = Atomic<Int>(48000)
	/// Floor of the adaptive target (the pinned target when adaptive is off).
	let targetMicros = Atomic<Int>(40_000)
	let maxTargetMicros = Atomic<Int>(200_000)
	let adaptive = Atomic<Bool>(true)
	let decayMicrosPerSec = Atomic<Int>(2_000)
	/// Fill needed to ride out the gaps seen recently (longest gap in window + margin). Written by the producer.
	let needMicros = Atomic<Int>(0)
	let longestGapMicros = Atomic<Int>(0)
	let gapPctMicros = Atomic<Int>(0)
	/// The target currently in force, for stats.
	let curTargetMicros = Atomic<Int>(40_000)
	let maxExcessMicros = Atomic<Int>(60_000)
	let volumeBits = Atomic<UInt32>(Float(1).bitPattern)
	let muted = Atomic<Bool>(false)
	/// Sound shaping (control side writes, render reads). Raw values of `AudioDynamics` / `AudioTone`.
	let dynamicsMode = Atomic<Int>(0)
	let toneMode = Atomic<Int>(0)
	let voiceBoost = Atomic<Bool>(false)
	/// For stats: compressor gain reduction and the deepest limiter reduction since the last read, in 1/1000 dB.
	let reductionMilliDb = Atomic<Int>(0)
	let limiterMilliDb = Atomic<Int>(0)

	// Stats.
	let underruns = Atomic<Int>(0)
	let overruns = Atomic<Int>(0)
	let skips = Atomic<Int>(0)
	let chunksIn = Atomic<Int>(0)
	let heartbeat = Atomic<Int>(0)
	let playingFlag = Atomic<Bool>(false)
	let adjPPM = Atomic<Int>(0)

	init() {
		ring = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity * 2)
		ring.initialize(repeating: 0, count: Self.capacity * 2)
		state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
		state.initialize(to: RenderState())
		effects = UnsafeMutablePointer<EffectsState>.allocate(capacity: 1)
		effects.initialize(to: EffectsState())
	}

	deinit {
		ring.deallocate()
		state.deallocate()
		effects.deallocate()
	}

	// MARK: Control side (only while no render thread is running)

	/// Drop everything buffered and go back to priming. Must not be called while rendering.
	func flush(resetTrim: Bool = true) {
		let w = writeIdx.load(ordering: .acquiring)
		readIdx.store(w, ordering: .releasing)
		let keptTrim = resetTrim ? 0 : state.pointee.trim
		state.pointee = RenderState()
		state.pointee.trim = keptTrim
		state.pointee.readIdx = w
		state.pointee.gain = currentGainTarget()
		playingFlag.store(false, ordering: .relaxed)
		adjPPM.store(0, ordering: .relaxed)
	}

	@inline(__always)
	func currentGainTarget() -> Float {
		muted.load(ordering: .relaxed) ? 0 : Float(bitPattern: volumeBits.load(ordering: .relaxed))
	}

	// MARK: Producer

	/// Converts interleaved Int16 to stereo float and appends it. Returns false if it was dropped.
	func write(_ pcm: UnsafeBufferPointer<Int16>, frames: Int, channels: Int) -> Bool {
		guard frames > 0, channels > 0, pcm.count >= frames * channels, let base = pcm.baseAddress else { return false }
		let w = writeIdx.load(ordering: .relaxed)
		let r = readIdx.load(ordering: .acquiring)
		if Self.capacity - (w - r) < frames {
			overruns.wrappingAdd(1, ordering: .relaxed)
			return false
		}
		let k: Float = 1.0 / 32768.0
		let m = Self.mask
		if channels == 2 {
			for i in 0..<frames {
				let d = ring + ((w + i) & m) * 2
				d[0] = Float(base[i * 2]) * k
				d[1] = Float(base[i * 2 + 1]) * k
			}
		} else if channels == 1 {
			for i in 0..<frames {
				let d = ring + ((w + i) & m) * 2
				let v = Float(base[i]) * k
				d[0] = v
				d[1] = v
			}
		} else {
			for i in 0..<frames {
				let d = ring + ((w + i) & m) * 2
				d[0] = Float(base[i * channels]) * k
				d[1] = Float(base[i * channels + 1]) * k
			}
		}
		writeIdx.store(w + frames, ordering: .releasing)
		chunksIn.wrappingAdd(1, ordering: .relaxed)
		return true
	}

	// MARK: Consumer (real-time thread: no locks, no allocation, no ObjC)

	/// Fill `out` (interleaved stereo Float32) with `frames` frames.
	func render(_ out: UnsafeMutablePointer<Float>, frames: Int) {
		heartbeat.wrappingAdd(1, ordering: .relaxed)
		let s = state
		let rate = Double(srcRate.load(ordering: .relaxed))
		let framesPerMs = rate / 1000.0
		let dt = Double(frames) / rate
		let maxExcess = Int(Double(maxExcessMicros.load(ordering: .relaxed)) / 1000.0 * framesPerMs)
		let w = writeIdx.load(ordering: .acquiring)
		var r = s.pointee.readIdx
		let fill = w - r
		let gTarget = currentGainTarget()
		let fx = effects
		fx.pointee.prepare(
			dynamics: dynamicsMode.load(ordering: .relaxed), tone: toneMode.load(ordering: .relaxed),
			voice: voiceBoost.load(ordering: .relaxed), rate: Int(rate))
		let shaping = !fx.pointee.bypass

		// Adaptive target: jumps up to what the observed gaps need, decays slowly, never below the floor.
		let minT = Double(targetMicros.load(ordering: .relaxed)) / 1000.0 * framesPerMs
		let maxT = max(minT, Double(maxTargetMicros.load(ordering: .relaxed)) / 1000.0 * framesPerMs)
		let need = Double(needMicros.load(ordering: .relaxed)) / 1000.0 * framesPerMs
		var tgt = s.pointee.target > 0 ? s.pointee.target : minT
		if adaptive.load(ordering: .relaxed) {
			let decay = Double(decayMicrosPerSec.load(ordering: .relaxed)) / 1000.0 * framesPerMs * dt
			tgt = max(tgt - decay, need)
		} else {
			tgt = minT
		}
		tgt = max(minT, min(maxT, tgt))
		s.pointee.bumpCooldown -= frames

		if !s.pointee.playing {
			// First start: prime to the target. After an underrun the backlog usually lands in one burst,
			// so resume as soon as a modest amount is there and let the target protect the next stall.
			let resumeFrames = max(min(tgt * 0.5, 60 * framesPerMs), 20 * framesPerMs)
			let need0 = s.pointee.resuming ? resumeFrames : tgt
			if fill >= Int(max(need0, Double(frames * 2 + 2))) {
				s.pointee.playing = true
				s.pointee.resuming = false
				s.pointee.ema = Double(fill)
				s.pointee.frac = 0
				s.pointee.xfRemaining = 0
				s.pointee.ramp = 0
				s.pointee.gain = gTarget
				s.pointee.minFill = Int.max
				s.pointee.tickFrames = 0
				playingFlag.store(true, ordering: .relaxed)
			} else {
				for i in 0..<(frames * 2) { out[i] = 0 }
				s.pointee.lastL = 0
				s.pointee.lastR = 0
				s.pointee.target = tgt
				curTargetMicros.store(Int(tgt / framesPerMs * 1000), ordering: .relaxed)
				return
			}
		}
		let target = Int(tgt)

		// Near-underrun feedback: if the fill kept dipping close to empty during the last second, nudge the target up.
		s.pointee.minFill = min(s.pointee.minFill, fill)
		s.pointee.tickFrames += frames
		if Double(s.pointee.tickFrames) >= rate {
			if adaptive.load(ordering: .relaxed), Double(s.pointee.minFill) < 10 * framesPerMs {
				tgt = min(maxT, min(tgt + 5 * framesPerMs, max(tgt, need + 40 * framesPerMs)))
			}
			s.pointee.minFill = Int.max
			s.pointee.tickFrames = 0
		}

		// Drift controller: slow low-pass of the fill level drives a small playback-rate trim.
		let alpha = Double(frames) / (0.3 * rate + Double(frames))
		var ema = s.pointee.ema + alpha * (Double(fill) - s.pointee.ema)
		if s.pointee.xfRemaining == 0 && fill > target + maxExcess {
			// Way too much buffered (burst / clock drift): jump back to target with a short crossfade.
			s.pointee.xfSkip = fill - target
			s.pointee.xfLen = max(32, Int(0.005 * rate))
			s.pointee.xfRemaining = s.pointee.xfLen
			ema = Double(target)
			skips.wrappingAdd(1, ordering: .relaxed)
		}
		s.pointee.ema = ema
		let errMs = (ema - Double(target)) / framesPerMs
		let deadband = 2.0
		let eff = errMs > deadband ? errMs - deadband : (errMs < -deadband ? errMs + deadband : 0)
		let trim = max(-0.003, min(0.003, s.pointee.trim + 0.00004 * eff * dt))
		s.pointee.trim = trim
		// Too full: speed up gently (max +1.5 %). Too empty: stretch harder (max -4 %) to refill quickly.
		let desired = max(-0.04, min(0.015, (eff > 0 ? eff * 0.0005 : eff * 0.001) + trim))
		// Slew-limited so a target change never steps the playback rate abruptly.
		let step = 0.04 * dt
		let adj = s.pointee.ratioAdj + max(-step, min(step, desired - s.pointee.ratioAdj))
		s.pointee.ratioAdj = adj
		adjPPM.store(Int(adj * 1e6), ordering: .relaxed)
		let ratio = 1.0 + adj

		var frac = s.pointee.frac
		var g = s.pointee.gain
		let gCoef = Float(1.0 / (0.005 * rate))
		let rampLen = max(16, Int(0.004 * rate))
		var ramp = s.pointee.ramp
		var lastL = s.pointee.lastL
		var lastR = s.pointee.lastR
		var xf = s.pointee.xfRemaining
		let xfLen = s.pointee.xfLen
		let xfSkip = s.pointee.xfSkip
		let m = Self.mask
		let ring = self.ring

		var i = 0
		while i < frames {
			let ahead = xf > 0 ? xfSkip : 0
			if r + ahead + 1 >= w {
				// Starved: fade out from the last sample, output silence, go back to priming.
				underruns.wrappingAdd(1, ordering: .relaxed)
				s.pointee.playing = false
				s.pointee.resuming = true
				if adaptive.load(ordering: .relaxed), s.pointee.bumpCooldown <= 0 {
					// Raise the target a little, but never far above what the measured gaps justify.
					tgt = min(maxT, min(tgt + 10 * framesPerMs, max(tgt, need + 40 * framesPerMs)))
					s.pointee.bumpCooldown = Int(rate)
				}
				playingFlag.store(false, ordering: .relaxed)
				xf = 0
				let fadeFrames = min(frames - i, 64)
				var j = 0
				while j < frames - i {
					let k: Float = j < fadeFrames ? 1 - Float(j + 1) / Float(fadeFrames) : 0
					out[(i + j) * 2] = lastL * k
					out[(i + j) * 2 + 1] = lastR * k
					j += 1
				}
				lastL = 0
				lastR = 0
				break
			}
			let f = Float(frac)
			let p0 = ring + (r & m) * 2
			let p1 = ring + ((r + 1) & m) * 2
			var l = p0[0] + (p1[0] - p0[0]) * f
			var rr = p0[1] + (p1[1] - p0[1]) * f
			if xf > 0 {
				let q0 = ring + ((r + xfSkip) & m) * 2
				let q1 = ring + ((r + xfSkip + 1) & m) * 2
				let nl = q0[0] + (q1[0] - q0[0]) * f
				let nr = q0[1] + (q1[1] - q0[1]) * f
				let wt = Float(xfLen - xf) / Float(xfLen)
				l = l * (1 - wt) + nl * wt
				rr = rr * (1 - wt) + nr * wt
				xf -= 1
			}
			if shaping { fx.pointee.process(&l, &rr) }
			g += (gTarget - g) * gCoef
			var gg = g
			if ramp < rampLen {
				gg *= Float(ramp) / Float(rampLen)
				ramp += 1
			}
			lastL = l * gg
			lastR = rr * gg
			out[i * 2] = lastL
			out[i * 2 + 1] = lastR
			frac += ratio
			let adv = Int(frac)
			frac -= Double(adv)
			r += adv
			if xf == 0 && ahead > 0 {
				r += xfSkip
			}
			i += 1
		}

		s.pointee.target = tgt
		curTargetMicros.store(Int(tgt / framesPerMs * 1000), ordering: .relaxed)
		s.pointee.readIdx = r
		s.pointee.frac = frac
		s.pointee.gain = g
		s.pointee.ramp = ramp
		s.pointee.lastL = lastL
		s.pointee.lastR = lastR
		s.pointee.xfRemaining = xf
		if shaping {
			reductionMilliDb.store(Int(fx.pointee.reduction * 1000), ordering: .relaxed)
			let floor = fx.pointee.limiterFloor
			if floor < 1 {
				let deepest = Int(-20 * log10(max(floor, 1e-6)) * 1000)
				if deepest > limiterMilliDb.load(ordering: .relaxed) { limiterMilliDb.store(deepest, ordering: .relaxed) }
				fx.pointee.limiterFloor = 1
			}
		} else if reductionMilliDb.load(ordering: .relaxed) != 0 {
			reductionMilliDb.store(0, ordering: .relaxed)
		}
		readIdx.store(r, ordering: .releasing)
	}
}
