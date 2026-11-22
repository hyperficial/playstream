import Foundation

/// One NAL unit inside an Annex-B buffer: `offset`/`length` are relative to the buffer start and
/// exclude the start code and any trailing zero bytes (trailing_zero_8bits / transport padding).
struct NALUnitRange {
	var offset: Int
	var length: Int
	/// NAL unit type: 6 bits for HEVC, 5 bits for H.264.
	var type: UInt8
}

enum NALKind {
	case parameterSet
	case vcl
	/// SEI and other NAL units that belong in the sample.
	case keep
	/// AUD, end of sequence/stream, filler: not needed in a length-prefixed sample.
	case discard
}

enum AnnexB {
	/// Splits an Annex-B buffer into NAL units. Accepts 3- and 4-byte start codes (a 4-byte start code is
	/// a zero byte followed by a 3-byte one, and trailing zeros are trimmed from the previous NAL).
	/// `out` is cleared first and reused so the steady state allocates nothing.
	static func scan(_ base: UnsafePointer<UInt8>, count: Int, hevc: Bool, into out: inout [NALUnitRange]) {
		out.removeAll(keepingCapacity: true)
		guard count >= 4 else { return }

		var payloadStart = -1
		var i = 0
		// Skip-ahead search for 00 00 01: if p[i+2] > 1, no start code can end in i...i+2.
		while i + 2 < count {
			let b2 = base[i + 2]
			if b2 > 1 {
				i += 3
				continue
			}
			if b2 == 1 && base[i + 1] == 0 && base[i] == 0 {
				if payloadStart >= 0 {
					append(base, start: payloadStart, end: i, hevc: hevc, into: &out)
				}
				payloadStart = i + 3
				i += 3
				continue
			}
			i += 1
		}
		if payloadStart >= 0 {
			append(base, start: payloadStart, end: count, hevc: hevc, into: &out)
		}
	}

	@inline(__always)
	private static func append(_ base: UnsafePointer<UInt8>, start: Int, end: Int, hevc: Bool, into out: inout [NALUnitRange]) {
		var e = end
		// A NAL unit never ends in 0x00 (rbsp_stop_one_bit / cabac_zero_word ends in 0x03), so any
		// zeros here are trailing_zero_8bits, the first byte of a 4-byte start code, or padding.
		while e > start && base[e - 1] == 0 { e -= 1 }
		let len = e - start
		guard len >= (hevc ? 2 : 1) else { return }
		let header = base[start]
		// forbidden_zero_bit set: not a NAL header (corrupt data); skip it.
		guard header & 0x80 == 0 else { return }
		let type = hevc ? (header >> 1) & 0x3F : header & 0x1F
		out.append(NALUnitRange(offset: start, length: len, type: type))
	}

	@inline(__always)
	static func kind(of type: UInt8, hevc: Bool) -> NALKind {
		if hevc {
			switch type {
			case 0...31: return .vcl
			case 32, 33, 34: return .parameterSet // VPS, SPS, PPS
			case 35, 36, 37, 38: return .discard // AUD, EOS, EOB, FD
			default: return .keep // SEI (39/40) and others
			}
		} else {
			switch type {
			case 1...5: return .vcl
			case 7, 8: return .parameterSet // SPS, PPS
			case 9, 10, 11, 12: return .discard // AUD, end of seq, end of stream, filler
			default: return .keep // SEI (6), SPS ext, etc.
			}
		}
	}

	/// IRAP pictures for HEVC (BLA/IDR/CRA, types 16...23), IDR for H.264.
	@inline(__always)
	static func isKeyframe(type: UInt8, hevc: Bool) -> Bool {
		hevc ? (16...23).contains(type) : type == 5
	}
}
