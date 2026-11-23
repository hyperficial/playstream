import Foundation

/// How much the loudness range of the game is narrowed.
public enum AudioDynamics: Int, Sendable, CaseIterable {
	/// The game's full range, untouched.
	case off = 0
	/// A little more even: quiet detail comes up, peaks come down.
	case light = 1
	/// For low volume at night: loud moments are held down hard, quiet sound is lifted, deep bass is trimmed.
	case night = 2
}

/// Overall tonal balance.
public enum AudioTone: Int, Sendable, CaseIterable {
	case flat = 0
	/// Lifts speech and trims the low end beneath it.
	case voices = 1
	/// More air and detail at the top.
	case bright = 2
	/// Fuller low end, softer top.
	case warm = 3
}

/// The numbers behind the presets. Levels in dB (0 = full scale), times in ms, frequencies in Hz.
enum EffectPresets {
	struct Compressor {
		var threshold: Double
		var ratio: Double
		var knee: Double
		var attackMs: Double
		var releaseMs: Double
		var makeup: Double
	}

	static func compressor(_ mode: AudioDynamics) -> Compressor? {
		switch mode {
		case .off: return nil
		// Full scale comes out at about -7 dB, -40 dB at about -34 dB.
		case .light: return Compressor(threshold: -26, ratio: 2, knee: 10, attackMs: 10, releaseMs: 250, makeup: 6)
		// Full scale comes out at about -12 dB, -40 dB at about -28 dB: 40 dB of range in 16.
		case .night: return Compressor(threshold: -36, ratio: 3, knee: 12, attackMs: 5, releaseMs: 400, makeup: 12)
		}
	}

	/// Night also takes the deepest bass down, which is what carries through walls.
	static let nightShelf = (frequency: 110.0, gain: -5.0)
	/// Voice boost: a wide bell over the speech range, applied only to what is in the centre of
	/// the stereo picture (where games put dialogue). Sound at the sides passes untouched.
	static let voiceBell = (frequency: 1600.0, gain: 5.5, q: 0.6)
	/// Nothing leaves louder than this (-1 dB), whatever the boosts add up to.
	static let ceiling = 0.891
	static let limiterReleaseMs = 120.0
	/// A change of preset fades the processing out, swaps it, and fades it back in over this long each way.
	static let fadeMs = 12.0
}

/// One second-order filter section for a stereo pair (transposed direct form II, double precision
/// so the low-frequency shelves stay exact).
struct Biquad {
	var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
	var z1L = 0.0, z2L = 0.0, z1R = 0.0, z2R = 0.0
	var active = false

	static let off = Biquad()

	private init() {}

	private init(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) {
		self.b0 = b0 / a0
		self.b1 = b1 / a0
		self.b2 = b2 / a0
		self.a1 = a1 / a0
		self.a2 = a2 / a0
		active = true
	}

	static func peak(_ f: Double, gainDb: Double, q: Double, rate: Double) -> Biquad {
		let a = pow(10, gainDb / 40)
		let w = 2 * Double.pi * f / rate
		let alpha = sin(w) / (2 * q)
		let c = cos(w)
		return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a, a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
	}

	static func lowShelf(_ f: Double, gainDb: Double, rate: Double) -> Biquad {
		let a = pow(10, gainDb / 40)
		let w = 2 * Double.pi * f / rate
		let c = cos(w)
		let k = 2 * a.squareRoot() * (sin(w) / 2 * 2.0.squareRoot())
		return Biquad(
			b0: a * ((a + 1) - (a - 1) * c + k), b1: 2 * a * ((a - 1) - (a + 1) * c), b2: a * ((a + 1) - (a - 1) * c - k),
			a0: (a + 1) + (a - 1) * c + k, a1: -2 * ((a - 1) + (a + 1) * c), a2: (a + 1) + (a - 1) * c - k)
	}

	static func highShelf(_ f: Double, gainDb: Double, rate: Double) -> Biquad {
		let a = pow(10, gainDb / 40)
		let w = 2 * Double.pi * f / rate
		let c = cos(w)
		let k = 2 * a.squareRoot() * (sin(w) / 2 * 2.0.squareRoot())
		return Biquad(
			b0: a * ((a + 1) + (a - 1) * c + k), b1: -2 * a * ((a - 1) + (a + 1) * c), b2: a * ((a + 1) + (a - 1) * c - k),
			a0: (a + 1) - (a - 1) * c + k, a1: 2 * ((a - 1) - (a + 1) * c), a2: (a + 1) - (a - 1) * c - k)
	}

	@inline(__always)
	mutating func process(_ l: inout Double, _ r: inout Double) {
		let yl = b0 * l + z1L
		z1L = b1 * l - a1 * yl + z2L
		z2L = b2 * l - a2 * yl
		l = yl
		let yr = b0 * r + z1R
		z1R = b1 * r - a1 * yr + z2R
		z2R = b2 * r - a2 * yr
		r = yr
	}

	/// One channel only (uses the left state).
	@inline(__always)
	mutating func processMono(_ x: inout Double) {
		let y = b0 * x + z1L
		z1L = b1 * x - a1 * y + z2L
		z2L = b2 * x - a2 * y
		x = y
	}
}

/// Tone, voice boost, dynamics and a safety limiter for the render thread. Plain data, no
/// allocation, no locks: lives behind a pointer owned by `AudioRenderCore`.
///
/// Order: tone filters, voice boost, compressor with make-up gain, limiter. The volume control
/// comes after all of it, so the processing behaves the same at every volume.
struct EffectsState {
	/// The configuration the filters are currently built for (-1: none yet).
	var appliedKey = -1
	/// True when everything is off and fully faded out: `process` is not called at all.
	var bypass = true
	/// 0 (dry) ... 1 (processed); ramps so a preset change never clicks.
	var wet = 0.0
	var wetTarget = 0.0
	var wetStep = 0.0

	var toneA = Biquad.off
	var toneB = Biquad.off
	var nightShelf = Biquad.off

	var voiceOn = false
	var voiceBell = Biquad.off

	var compOn = false
	var threshold = 0.0
	/// 1 - 1/ratio: dB of reduction per dB above the threshold.
	var slope = 0.0
	var knee = 1.0
	var attack = 0.0
	var release = 0.0
	var makeup = 0.0
	/// Fast peak follower in front of the gain computer, so a low note reads as its peak, not its zero crossings.
	var envelope = 0.0
	var envelopeRelease = 0.0
	/// Current gain reduction of the compressor, dB (positive).
	var reduction = 0.0

	var limiterGain = 1.0
	var limiterRelease = 0.0
	/// Lowest limiter gain since the stats were last read.
	var limiterFloor = 1.0

	static func key(dynamics: Int, tone: Int, voice: Bool, rate: Int) -> Int {
		(dynamics & 0xF) | (tone & 0xF) << 4 | (voice ? 1 : 0) << 8 | rate << 12
	}

	/// Call once per render callback. Starts a fade-out when the wanted configuration differs
	/// from the applied one, and rebuilds the filters once the processing has faded out.
	mutating func prepare(dynamics: Int, tone: Int, voice: Bool, rate: Int) {
		let wanted = Self.key(dynamics: dynamics, tone: tone, voice: voice, rate: rate)
		guard wanted != appliedKey else { return }
		if wet > 0 {
			wetTarget = 0
			bypass = false
			return
		}
		apply(dynamics: AudioDynamics(rawValue: dynamics) ?? .off, tone: AudioTone(rawValue: tone) ?? .flat, voice: voice, rate: Double(rate))
		appliedKey = wanted
	}

	private mutating func apply(dynamics: AudioDynamics, tone: AudioTone, voice: Bool, rate: Double) {
		wetStep = 1 / (EffectPresets.fadeMs / 1000 * rate)
		switch tone {
		case .flat:
			toneA = .off
			toneB = .off
		case .voices:
			toneA = .lowShelf(160, gainDb: -4, rate: rate)
			toneB = .peak(2800, gainDb: 3.5, q: 0.8, rate: rate)
		case .bright:
			toneA = .highShelf(5000, gainDb: 4, rate: rate)
			toneB = .off
		case .warm:
			toneA = .lowShelf(220, gainDb: 3, rate: rate)
			toneB = .highShelf(6000, gainDb: -3, rate: rate)
		}
		nightShelf = dynamics == .night ? .lowShelf(EffectPresets.nightShelf.frequency, gainDb: EffectPresets.nightShelf.gain, rate: rate) : .off

		voiceOn = voice
		let bell = EffectPresets.voiceBell
		voiceBell = voice ? .peak(bell.frequency, gainDb: bell.gain, q: bell.q, rate: rate) : .off

		if let c = EffectPresets.compressor(dynamics) {
			compOn = true
			threshold = c.threshold
			slope = 1 - 1 / c.ratio
			knee = c.knee
			attack = 1 - exp(-1 / (c.attackMs / 1000 * rate))
			release = 1 - exp(-1 / (c.releaseMs / 1000 * rate))
			makeup = c.makeup
		} else {
			compOn = false
			makeup = 0
		}
		envelope = 0
		envelopeRelease = 1 - exp(-1 / (0.010 * rate))
		// Start at unity gain (the reduction cancels the make-up) and settle from there: switching
		// a mode on never begins with a burst of make-up gain.
		reduction = makeup
		limiterGain = 1
		limiterRelease = 1 - exp(-1 / (EffectPresets.limiterReleaseMs / 1000 * rate))

		let anything = tone != .flat || voice || dynamics != .off
		wetTarget = anything ? 1 : 0
		bypass = !anything
	}

	/// One stereo frame, in place.
	@inline(__always)
	mutating func process(_ l: inout Float, _ r: inout Float) {
		let dryL = Double(l), dryR = Double(r)
		var x = dryL, y = dryR

		if toneA.active { toneA.process(&x, &y) }
		if toneB.active { toneB.process(&x, &y) }
		if nightShelf.active { nightShelf.process(&x, &y) }

		if voiceOn {
			var mid = 0.5 * (x + y)
			let side = 0.5 * (x - y)
			voiceBell.processMono(&mid)
			x = mid + side
			y = mid - side
		}

		if compOn {
			let peak = max(abs(x), abs(y))
			envelope = peak > envelope ? peak : envelope + envelopeRelease * (peak - envelope)
			let level = envelope > 1e-6 ? 20 * log10(envelope) : -120
			let over = level - threshold
			let wanted: Double
			if 2 * over <= -knee {
				wanted = 0
			} else if 2 * over >= knee {
				wanted = over * slope
			} else {
				let t = over + knee / 2
				wanted = slope * t * t / (2 * knee)
			}
			reduction += (wanted > reduction ? attack : release) * (wanted - reduction)
			let gain = pow(10, (makeup - reduction) / 20)
			x *= gain
			y *= gain
		}

		// Limiter: instant down, slow back up. Catches what the compressor's attack lets through
		// and whatever the tone and voice boosts add on top of an already loud signal.
		let peak = max(abs(x), abs(y))
		let allowed = peak > EffectPresets.ceiling ? EffectPresets.ceiling / peak : 1
		limiterGain = min(allowed, limiterGain + limiterRelease * (1 - limiterGain))
		if limiterGain < limiterFloor { limiterFloor = limiterGain }
		x *= limiterGain
		y *= limiterGain

		if wet != wetTarget {
			wet = wetTarget > wet ? min(wetTarget, wet + wetStep) : max(wetTarget, wet - wetStep)
		}
		l = Float(dryL + wet * (x - dryL))
		r = Float(dryR + wet * (y - dryR))
	}
}
