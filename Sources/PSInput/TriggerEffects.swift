import Foundation
import GameController

/// Decoded DualSense adaptive-trigger effect.
///
/// Raw layout (the console sends `type` = mode byte and 10 parameter bytes, exactly what goes into the
/// DualSense output report; see dualsensectl's encoders / Nielk1's trigger-effect notes):
///   0x00 / 0x05  off
///   0x21 feedback   p0,p1 = 10-bit zone mask (LE); p2..p5 = 3 bits per zone (LE 32 bit) = strength-1 (1...8)
///   0x25 weapon     p0,p1 = (1<<start)|(1<<end) zone mask; p2 = strength-1
///   0x26 vibration  p0..p5 as feedback (amplitude per zone); p8 = frequency
///   0x22 bow        p0,p1 = start/end mask; p2 = (strength-1) | (snapForce-1) << 3
///   0x23 galloping  p0,p1 = start/end mask; p2 = secondFoot | firstFoot << 3; p3 = frequency
///   0x27 machine    p0,p1 = start/end mask; p2 = ampA | ampB << 3; p3 = frequency; p4 = period
/// Zones are 0...9 along the trigger travel.
public enum TriggerEffect: Equatable {
	case off
	/// strengths[zone] in 0...8 (0 = no resistance in that zone). Also covers slope-style ramps.
	case feedback(strengths: [Int])
	case weapon(startZone: Int, endZone: Int, strength: Int)
	case vibration(amplitudes: [Int], frequency: Int)
	case bow(startZone: Int, endZone: Int, strength: Int, snap: Int)
	case galloping(startZone: Int, endZone: Int, firstFoot: Int, secondFoot: Int, frequency: Int)
	case machine(startZone: Int, endZone: Int, ampA: Int, ampB: Int, frequency: Int, period: Int)
	/// A mode byte we do not understand (legacy 0x01/0x02/0x06 included: their position/strength
	/// scaling is undocumented in the reference). Rendered as off.
	case unsupported(type: UInt8)

	public static func decode(type: UInt8, params p: [UInt8]) -> TriggerEffect {
		var b = [UInt8](repeating: 0, count: 10)
		for (i, v) in p.prefix(10).enumerated() { b[i] = v }
		let mask = Int(b[0]) | Int(b[1]) << 8
		func zones() -> (start: Int, end: Int)? {
			let m = mask & 0x3ff
			guard m != 0 else { return nil }
			let lo = m.trailingZeroBitCount
			let hi = (Int.bitWidth - 1) - m.leadingZeroBitCount
			return (lo, hi)
		}
		func perZone() -> [Int] {
			let bits = UInt32(b[2]) | UInt32(b[3]) << 8 | UInt32(b[4]) << 16 | UInt32(b[5]) << 24
			return (0..<10).map { i in
				(mask >> i) & 1 == 1 ? Int((bits >> UInt32(3 * i)) & 7) + 1 : 0
			}
		}
		switch type {
		case 0x00, 0x05:
			return .off
		case 0x21:
			let s = perZone()
			return s.allSatisfy { $0 == 0 } ? .off : .feedback(strengths: s)
		case 0x25:
			guard let z = zones() else { return .off }
			return .weapon(startZone: z.start, endZone: z.end, strength: Int(b[2] & 7) + 1)
		case 0x26:
			let s = perZone()
			if s.allSatisfy({ $0 == 0 }) || b[8] == 0 { return .off }
			return .vibration(amplitudes: s, frequency: Int(b[8]))
		case 0x22:
			guard let z = zones() else { return .off }
			return .bow(startZone: z.start, endZone: z.end, strength: Int(b[2] & 7) + 1, snap: Int((b[2] >> 3) & 7) + 1)
		case 0x23:
			guard let z = zones() else { return .off }
			return .galloping(startZone: z.start, endZone: z.end, firstFoot: Int((b[2] >> 3) & 7), secondFoot: Int(b[2] & 7), frequency: Int(b[3]))
		case 0x27:
			guard let z = zones() else { return .off }
			return .machine(startZone: z.start, endZone: z.end, ampA: Int(b[2] & 7), ampB: Int((b[2] >> 3) & 7), frequency: Int(b[3]), period: Int(b[4]))
		default:
			return .unsupported(type: type)
		}
	}

	// MARK: GameController rendering

	/// What we actually ask the GameController framework to do (pure data, so it can be checked).
	public enum GCRendering: Equatable {
		case off
		case feedback(resistive: [Float])                                  // 10 positional strengths 0...1
		case weapon(start: Float, end: Float, strength: Float)
		case vibration(amplitudes: [Float], frequency: Float)              // 10 positional amplitudes
	}

	static func strengthF(_ s: Int) -> Float { Float(max(0, min(8, s))) / 8 }
	static func zoneF(_ z: Int) -> Float { Float(max(0, min(9, z))) / 9 }

	public var gcRendering: GCRendering {
		switch self {
		case .off, .unsupported, .galloping:
			return .off
		case .feedback(let s):
			return .feedback(resistive: s.map(Self.strengthF))
		case .weapon(let a, let b, let s):
			return b > a ? .weapon(start: Self.zoneF(a), end: Self.zoneF(b), strength: Self.strengthF(s)) : .off
		case .bow(let a, let b, let s, _):
			// No bow in GC: closest is weapon (resistance start...end then release). Approximation.
			return b > a ? .weapon(start: Self.zoneF(a), end: Self.zoneF(b), strength: Self.strengthF(s)) : .off
		case .vibration(let amps, let f):
			return .vibration(amplitudes: amps.map(Self.strengthF), frequency: Float(min(255, f)) / 255)
		case .machine(let a, let b, let ampA, let ampB, let f, _):
			// Approximation: steady vibration between start and end at the stronger amplitude.
			let amp = Float(max(ampA, ampB)) / 7
			guard amp > 0, f > 0 else { return .off }
			let arr = (0..<10).map { ($0 >= a && $0 <= b) ? amp : 0 }
			return .vibration(amplitudes: arr, frequency: Float(min(255, f)) / 255)
		}
	}

	public func apply(to trigger: GCDualSenseAdaptiveTrigger) {
		switch gcRendering {
		case .off:
			trigger.setModeOff()
		case .feedback(let r):
			var v = GCDualSenseAdaptiveTrigger.PositionalResistiveStrengths()
			Self.fill(&v.values, r)
			trigger.setModeFeedback(resistiveStrengths: v)
		case .weapon(let s, let e, let st):
			trigger.setModeWeaponWithStartPosition(s, endPosition: e, resistiveStrength: st)
		case .vibration(let a, let f):
			var v = GCDualSenseAdaptiveTrigger.PositionalAmplitudes()
			Self.fill(&v.values, a)
			trigger.setModeVibration(amplitudes: v, frequency: f)
		}
	}

	private static func fill<T>(_ tuple: inout T, _ values: [Float]) {
		withUnsafeMutableBytes(of: &tuple) { raw in
			let p = raw.bindMemory(to: Float.self)
			for i in 0..<min(p.count, values.count) { p[i] = values[i] }
		}
	}
}
