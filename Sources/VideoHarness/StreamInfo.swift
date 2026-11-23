import Foundation

// Sequence parameter set inspection: how many pictures a decoder may hold back for reordering.
// HEVC: sps_max_dec_pic_buffering / sps_max_num_reorder_pics / sps_max_latency_increase (always present).
// H.264: max_num_ref_frames, and VUI bitstream_restriction max_num_reorder_frames / max_dec_frame_buffering
// (when absent, a decoder must assume reordering up to the DPB size and may hold pictures).

/// Splits an Annex-B byte stream into NAL units (without start codes).
func annexBUnits(_ d: [UInt8]) -> [ArraySlice<UInt8>] {
	var starts: [(Int, Int)] = [] // (start code position, payload start)
	var i = 0
	while i + 3 <= d.count {
		if d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 {
			starts.append((i > 0 && d[i - 1] == 0 ? i - 1 : i, i + 3))
			i += 3
		} else { i += 1 }
	}
	var out: [ArraySlice<UInt8>] = []
	for (k, s) in starts.enumerated() {
		let end = k + 1 < starts.count ? starts[k + 1].0 : d.count
		if end > s.1 { out.append(d[s.1..<end]) }
	}
	return out
}

func unescapeRBSP(_ n: ArraySlice<UInt8>) -> [UInt8] {
	var out: [UInt8] = []
	out.reserveCapacity(n.count)
	var zeros = 0
	for b in n {
		if zeros >= 2 && b == 3 { zeros = 0; continue }
		out.append(b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	return out
}

func escapeRBSP(_ r: [UInt8]) -> [UInt8] {
	var out: [UInt8] = []
	var zeros = 0
	for b in r {
		if zeros >= 2 && b <= 3 { out.append(3); zeros = 0 }
		out.append(b)
		zeros = b == 0 ? zeros + 1 : 0
	}
	return out
}

struct BitReader {
	let d: [UInt8]
	var pos = 0
	init(_ d: [UInt8], skipBytes: Int) { self.d = d; pos = skipBytes * 8 }
	var bitsLeft: Int { d.count * 8 - pos }
	mutating func u(_ n: Int) -> UInt64 {
		var v: UInt64 = 0
		for _ in 0..<n {
			let byte = pos / 8 < d.count ? d[pos / 8] : 0
			v = (v << 1) | UInt64((byte >> (7 - UInt8(pos % 8))) & 1)
			pos += 1
		}
		return v
	}
	mutating func flag() -> Bool { u(1) == 1 }
	mutating func ue() -> UInt64 {
		var zeros = 0
		while u(1) == 0 && zeros < 32 { zeros += 1 }
		return zeros == 0 ? 0 : ((1 << UInt64(zeros)) - 1 + u(zeros))
	}
	mutating func se() -> Int64 {
		let k = ue()
		return k & 1 == 1 ? Int64((k + 1) / 2) : -Int64(k / 2)
	}
}

struct SPSInfo: CustomStringConvertible {
	var codec = ""
	var width = 0, height = 0
	var fields: [(String, String)] = []
	/// H.264: bit position (in the RBSP, including the NAL header byte) of vui_parameters_present_flag.
	var vuiFlagBit: Int?
	var description: String { "\(codec) \(width)x\(height): " + fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ") }
}

func parseHEVCSPS(_ rbsp: [UInt8]) -> SPSInfo {
	var r = BitReader(rbsp, skipBytes: 2)
	var info = SPSInfo(codec: "HEVC")
	_ = r.u(4)
	let maxSub = Int(r.u(3))
	_ = r.u(1)
	// profile_tier_level(1, maxSub)
	_ = r.u(2); _ = r.u(1); let profile = r.u(5); _ = r.u(32); _ = r.u(4); _ = r.u(43); _ = r.u(1)
	let level = r.u(8)
	var subProfile = [Bool](), subLevel = [Bool]()
	for _ in 0..<maxSub { subProfile.append(r.flag()); subLevel.append(r.flag()) }
	if maxSub > 0 { for _ in maxSub..<8 { _ = r.u(2) } }
	for i in 0..<maxSub {
		if subProfile[i] { _ = r.u(88) }
		if subLevel[i] { _ = r.u(8) }
	}
	_ = r.ue()
	let chroma = r.ue()
	if chroma == 3 { _ = r.u(1) }
	info.width = Int(r.ue()); info.height = Int(r.ue())
	if r.flag() { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }
	let bd = r.ue() + 8
	_ = r.ue()
	_ = r.ue()
	let orderingAll = r.flag()
	info.fields += [("profile", "\(profile)"), ("level", String(format: "%.1f", Double(level) / 30)), ("bitDepth", "\(bd)"), ("maxSubLayers", "\(maxSub + 1)")]
	for i in (orderingAll ? 0 : maxSub)...maxSub {
		let dpb = r.ue() + 1, reorder = r.ue(), lat = r.ue()
		info.fields += [("[\(i)] max_dec_pic_buffering", "\(dpb)"), ("max_num_reorder_pics", "\(reorder)"), ("max_latency_increase_plus1", "\(lat)")]
	}
	return info
}

func parseH264SPS(_ rbsp: [UInt8]) -> SPSInfo {
	var r = BitReader(rbsp, skipBytes: 1)
	var info = SPSInfo(codec: "H.264")
	let profile = r.u(8); _ = r.u(8); let level = r.u(8)
	_ = r.ue()
	if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
		let chroma = r.ue()
		if chroma == 3 { _ = r.u(1) }
		_ = r.ue(); _ = r.ue(); _ = r.u(1)
		if r.flag() {
			for i in 0..<(chroma == 3 ? 12 : 8) where r.flag() {
				let size = i < 6 ? 16 : 64
				var last: Int64 = 8, next: Int64 = 8
				for _ in 0..<size where next != 0 {
					next = (last + r.se() + 256) % 256
					last = next == 0 ? last : next
				}
			}
		}
	}
	_ = r.ue()
	let pocType = r.ue()
	if pocType == 0 { _ = r.ue() } else if pocType == 1 {
		_ = r.u(1); _ = r.se(); _ = r.se()
		let n = r.ue()
		for _ in 0..<n { _ = r.se() }
	}
	let refs = r.ue()
	_ = r.u(1)
	let wmb = r.ue() + 1, hmu = r.ue() + 1
	let frameOnly = r.flag()
	if !frameOnly { _ = r.u(1) }
	_ = r.u(1)
	if r.flag() { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }
	info.width = Int(wmb) * 16; info.height = Int(hmu) * 16 * (frameOnly ? 1 : 2)
	info.fields += [("profile", "\(profile)"), ("level", String(format: "%.1f", Double(level) / 10)), ("max_num_ref_frames", "\(refs)"), ("poc_type", "\(pocType)")]
	info.vuiFlagBit = r.pos
	let vui = r.flag()
	info.fields.append(("vui", vui ? "yes" : "no"))
	guard vui else { info.fields.append(("bitstream_restriction", "absent (decoder must assume reordering up to the DPB size)")); return info }
	if r.flag() { if r.u(8) == 255 { _ = r.u(32) } }
	if r.flag() { _ = r.u(1) }
	if r.flag() { _ = r.u(3); _ = r.u(1); if r.flag() { _ = r.u(24) } }
	if r.flag() { _ = r.ue(); _ = r.ue() }
	if r.flag() { _ = r.u(32); _ = r.u(32); _ = r.u(1) }
	func hrd(_ r: inout BitReader) {
		let n = r.ue() + 1
		_ = r.u(4); _ = r.u(4)
		for _ in 0..<n { _ = r.ue(); _ = r.ue(); _ = r.u(1) }
		_ = r.u(20)
	}
	let nal = r.flag(); if nal { hrd(&r) }
	let vcl = r.flag(); if vcl { hrd(&r) }
	if nal || vcl { _ = r.u(1) }
	_ = r.u(1)
	if r.flag() {
		_ = r.u(1); _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue()
		info.fields += [("max_num_reorder_frames", "\(r.ue())"), ("max_dec_frame_buffering", "\(r.ue())")]
	} else {
		info.fields.append(("bitstream_restriction", "absent (decoder must assume reordering up to the DPB size)"))
	}
	return info
}

/// Every SPS in an Annex-B buffer.
func spsInfos(_ bytes: [UInt8], hevc: Bool) -> [SPSInfo] {
	annexBUnits(bytes).compactMap { n -> SPSInfo? in
		guard let h = n.first else { return nil }
		if hevc { return (h >> 1) & 0x3F == 33 ? parseHEVCSPS(unescapeRBSP(n)) : nil }
		return h & 0x1F == 7 ? parseH264SPS(unescapeRBSP(n)) : nil
	}
}

/// H.264: the same buffer with every SPS's VUI removed (vui_parameters_present_flag = 0). Recreates a
/// stream without bitstream_restriction, the case where a decoder may hold pictures for reordering.
func stripH264VUI(_ bytes: [UInt8]) -> [UInt8] {
	var out: [UInt8] = []
	for n in annexBUnits(bytes) {
		out += [0, 0, 0, 1]
		guard let h = n.first, h & 0x1F == 7 else { out += n; continue }
		let rbsp = unescapeRBSP(n)
		guard let bit = parseH264SPS(rbsp).vuiFlagBit else { out += n; continue }
		var w: [UInt8] = []
		var acc: UInt8 = 0, nbits = 0
		func put(_ b: UInt8) { acc = (acc << 1) | b; nbits += 1; if nbits == 8 { w.append(acc); acc = 0; nbits = 0 } }
		for i in 0..<bit { put((rbsp[i / 8] >> (7 - UInt8(i % 8))) & 1) }
		put(0) // vui_parameters_present_flag
		put(1) // rbsp_stop_one_bit
		while nbits != 0 { put(0) }
		out += escapeRBSP(w)
	}
	return out
}
