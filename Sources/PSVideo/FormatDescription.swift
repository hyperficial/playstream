import CoreMedia
import Foundation
import PSContracts

/// Colour description the pipeline settled on for the current format description.
public struct VideoColorInfo: Sendable, Equatable {
	/// CoreMedia constant strings, e.g. "ITU_R_2020", "SMPTE_ST_2084_PQ", "ITU_R_709_2".
	public var primaries: String
	public var transferFunction: String
	public var matrix: String
	public var fullRange: Bool
	/// Bits per luma sample according to the SPS (8 or 10).
	public var bitDepth: Int
	/// Which of the three tags came from the stream's VUI (the rest were filled in by the pipeline).
	public var taggedInStream: Bool

	public var isHDR: Bool {
		transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
			|| transferFunction == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
	}

	public var isPQ: Bool { transferFunction == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) }
	public var isBT2020Matrix: Bool { matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) }
}

/// Holds the latest parameter sets and notices when they change.
final class ParameterSetStore {
	let hevc: Bool
	private(set) var vps: [[UInt8]] = []
	private(set) var sps: [[UInt8]] = []
	private(set) var pps: [[UInt8]] = []

	init(hevc: Bool) { self.hevc = hevc }

	var isComplete: Bool { !sps.isEmpty && !pps.isEmpty && (!hevc || !vps.isEmpty) }

	func reset() {
		vps.removeAll()
		sps.removeAll()
		pps.removeAll()
	}

	/// Takes all parameter sets found in one buffer. For each parameter set type present in the
	/// buffer, the stored list of that type is replaced. Returns true if anything changed.
	/// Compares in place first so a stream that repeats identical headers allocates nothing.
	func update(base: UnsafePointer<UInt8>, nals: [NALUnitRange]) -> Bool {
		var seenVPS = 0, seenSPS = 0, seenPPS = 0
		var same = true
		for n in nals where AnnexB.kind(of: n.type, hevc: hevc) == .parameterSet {
			let slot = slotIndex(n.type)
			let index: Int
			switch slot {
			case 0: index = seenVPS; seenVPS += 1
			case 1: index = seenSPS; seenSPS += 1
			default: index = seenPPS; seenPPS += 1
			}
			let list = slot == 0 ? vps : (slot == 1 ? sps : pps)
			if index >= list.count || list[index].count != n.length
				|| !list[index].withUnsafeBufferPointer({ memcmp($0.baseAddress!, base + n.offset, n.length) == 0 })
			{
				same = false
			}
		}
		if seenVPS == 0 && seenSPS == 0 && seenPPS == 0 { return false }
		if same && (seenVPS == 0 || seenVPS == vps.count) && (seenSPS == 0 || seenSPS == sps.count) && (seenPPS == 0 || seenPPS == pps.count) {
			return false
		}
		var newVPS: [[UInt8]] = [], newSPS: [[UInt8]] = [], newPPS: [[UInt8]] = []
		for n in nals where AnnexB.kind(of: n.type, hevc: hevc) == .parameterSet {
			let bytes = Array(UnsafeBufferPointer(start: base + n.offset, count: n.length))
			switch slotIndex(n.type) {
			case 0: newVPS.append(bytes)
			case 1: newSPS.append(bytes)
			default: newPPS.append(bytes)
			}
		}
		if seenVPS > 0 { vps = newVPS }
		if seenSPS > 0 { sps = newSPS }
		if seenPPS > 0 { pps = newPPS }
		return true
	}

	private func slotIndex(_ type: UInt8) -> Int {
		if hevc { return type == 32 ? 0 : (type == 33 ? 1 : 2) }
		return type == 7 ? 1 : 2
	}

	/// Builds the format description and applies the colour policy:
	/// - tags present in the stream's VUI are kept;
	/// - missing tags are filled from the negotiated codec (BT.2020 / PQ / BT.2020 NCL for `.hevcHDR`,
	///   BT.709 for the SDR codecs), so the decoder output and the display layer always know the
	///   colour space even if the console omits the VUI colour description.
	func makeFormatDescription(codec: VideoCodec) -> (CMVideoFormatDescription, VideoColorInfo)? {
		guard isComplete else { return nil }
		let sets: [[UInt8]] = hevc ? vps + sps + pps : sps + pps
		var flat: [UInt8] = []
		flat.reserveCapacity(sets.reduce(0) { $0 + $1.count })
		var offsets: [Int] = []
		var sizes: [Int] = []
		for s in sets {
			offsets.append(flat.count)
			sizes.append(s.count)
			flat.append(contentsOf: s)
		}

		var base: CMFormatDescription?
		let status: OSStatus = flat.withUnsafeBufferPointer { buf in
			let pointers = offsets.map { UnsafePointer<UInt8>(buf.baseAddress! + $0) }
			return pointers.withUnsafeBufferPointer { ptrs in
				sizes.withUnsafeBufferPointer { szs in
					if hevc {
						return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
							allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
							parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: szs.baseAddress!,
							nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &base)
					} else {
						return CMVideoFormatDescriptionCreateFromH264ParameterSets(
							allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
							parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: szs.baseAddress!,
							nalUnitHeaderLength: 4, formatDescriptionOut: &base)
					}
				}
			}
		}
		guard status == noErr, let fd = base else {
			NSLog("[PSVideo] could not build format description from parameter sets: %d", status)
			return nil
		}

		let ext = (CMFormatDescriptionGetExtensions(fd) as NSDictionary?)?.mutableCopy() as? NSMutableDictionary ?? NSMutableDictionary()
		let kP = kCMFormatDescriptionExtension_ColorPrimaries as String
		let kT = kCMFormatDescriptionExtension_TransferFunction as String
		let kM = kCMFormatDescriptionExtension_YCbCrMatrix as String
		let kR = kCMFormatDescriptionExtension_FullRangeVideo as String
		let tagged = ext[kP] != nil && ext[kT] != nil && ext[kM] != nil

		let defP: CFString, defT: CFString, defM: CFString
		if codec.isHDR {
			defP = kCMFormatDescriptionColorPrimaries_ITU_R_2020
			defT = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
			defM = kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
		} else {
			defP = kCMFormatDescriptionColorPrimaries_ITU_R_709_2
			defT = kCMFormatDescriptionTransferFunction_ITU_R_709_2
			defM = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
		}
		var changed = false
		if ext[kP] == nil { ext[kP] = defP; changed = true }
		if ext[kT] == nil { ext[kT] = defT; changed = true }
		if ext[kM] == nil { ext[kM] = defM; changed = true }

		let bitDepth = Self.lumaBitDepth(sps: sps.first ?? [], hevc: hevc) ?? (codec.isHDR ? 10 : 8)
		var color = VideoColorInfo(
			primaries: ext[kP] as? String ?? "", transferFunction: ext[kT] as? String ?? "",
			matrix: ext[kM] as? String ?? "", fullRange: (ext[kR] as? Bool) ?? false,
			bitDepth: bitDepth, taggedInStream: tagged)
		if color.isHDR && ext[kCMFormatDescriptionExtension_BitsPerComponent as String] == nil {
			ext[kCMFormatDescriptionExtension_BitsPerComponent as String] = bitDepth
			changed = true
		}

		guard changed else { return (fd, color) }
		let dims = CMVideoFormatDescriptionGetDimensions(fd)
		var out: CMVideoFormatDescription?
		let st = CMVideoFormatDescriptionCreate(
			allocator: kCFAllocatorDefault, codecType: CMFormatDescriptionGetMediaSubType(fd),
			width: dims.width, height: dims.height, extensions: ext as CFDictionary, formatDescriptionOut: &out)
		guard st == noErr, let tagged = out else {
			NSLog("[PSVideo] could not re-tag format description: %d", st)
			color.taggedInStream = true
			return (fd, color)
		}
		return (tagged, color)
	}

	/// Reads bit_depth_luma_minus8 from an SPS (enough of the SPS is parsed to get there).
	static func lumaBitDepth(sps: [UInt8], hevc: Bool) -> Int? {
		guard sps.count > 4 else { return nil }
		var r = BitReader(nal: sps, skipHeaderBytes: hevc ? 2 : 1)
		if hevc {
			_ = r.bits(4) // vps id
			let maxSubLayersMinus1 = r.bits(3)
			_ = r.bits(1)
			// profile_tier_level(1, maxSubLayersMinus1)
			_ = r.bits(8); _ = r.bits(32); _ = r.bits(32); _ = r.bits(16); _ = r.bits(8) // general: 2+1+5, flags, 48 bits, level
			var subProfile = [Bool](), subLevel = [Bool]()
			for _ in 0..<maxSubLayersMinus1 { subProfile.append(r.bits(1) == 1); subLevel.append(r.bits(1) == 1) }
			if maxSubLayersMinus1 > 0 { for _ in maxSubLayersMinus1..<8 { _ = r.bits(2) } }
			for i in 0..<maxSubLayersMinus1 {
				if subProfile[i] { _ = r.bits(32); _ = r.bits(32); _ = r.bits(24) }
				if subLevel[i] { _ = r.bits(8) }
			}
			_ = r.ue() // sps id
			let chroma = r.ue()
			if chroma == 3 { _ = r.bits(1) }
			_ = r.ue(); _ = r.ue() // width, height
			if r.bits(1) == 1 { _ = r.ue(); _ = r.ue(); _ = r.ue(); _ = r.ue() }
			let d = r.ue()
			return r.overrun || d > 8 ? nil : d + 8
		} else {
			let profile = r.bits(8)
			_ = r.bits(16)
			_ = r.ue()
			if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
				if r.ue() == 3 { _ = r.bits(1) }
				let d = r.ue()
				return r.overrun || d > 8 ? nil : d + 8
			}
			return 8
		}
	}
}

/// Minimal RBSP bit reader (removes emulation prevention bytes).
struct BitReader {
	private var data: [UInt8] = []
	private var pos = 0
	private(set) var overrun = false

	init(nal: [UInt8], skipHeaderBytes: Int) {
		data.reserveCapacity(nal.count)
		var zeros = 0
		for (i, b) in nal.enumerated() where i >= skipHeaderBytes {
			if zeros >= 2 && b == 3 { zeros = 0; continue }
			zeros = b == 0 ? zeros + 1 : 0
			data.append(b)
		}
	}

	mutating func bits(_ n: Int) -> Int {
		var v = 0
		for _ in 0..<n {
			let byte = pos >> 3
			guard byte < data.count else { overrun = true; return v }
			v = (v << 1) | Int((data[byte] >> (7 - UInt8(pos & 7))) & 1)
			pos += 1
		}
		return v
	}

	mutating func ue() -> Int {
		var zeros = 0
		while bits(1) == 0 {
			zeros += 1
			if zeros > 31 || overrun { overrun = true; return 0 }
		}
		return (1 << zeros) - 1 + bits(zeros)
	}
}
