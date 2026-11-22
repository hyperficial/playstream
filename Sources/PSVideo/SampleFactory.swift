import CoreMedia
import Foundation

/// Converts the NAL units of one Annex-B frame into a length-prefixed (AVCC/HVCC, 4-byte lengths)
/// `CMSampleBuffer`. Block memory comes from a `CMMemoryPool`, so in steady state the per-frame
/// allocation is recycled instead of hitting malloc for every ~60 KB frame.
final class SampleFactory {
	private let pool: CMMemoryPool
	private let blockAllocator: CFAllocator

	init() {
		pool = CMMemoryPoolCreate(options: [kCMMemoryPoolOption_AgeOutPeriod: 2.0] as CFDictionary)
		blockAllocator = CMMemoryPoolGetAllocator(pool)
	}

	deinit {
		CMMemoryPoolInvalidate(pool)
	}

	/// - Returns: nil if there is nothing to put in the sample or CoreMedia fails.
	func makeSample(
		base: UnsafePointer<UInt8>, nals: [NALUnitRange], hevc: Bool,
		formatDescription: CMVideoFormatDescription, pts: CMTime, duration: CMTime,
		isKeyframe: Bool
	) -> CMSampleBuffer? {
		var total = 0
		for n in nals {
			switch AnnexB.kind(of: n.type, hevc: hevc) {
			case .vcl, .keep: total += 4 + n.length
			default: break
			}
		}
		guard total > 0 else { return nil }

		var block: CMBlockBuffer?
		var status = CMBlockBufferCreateWithMemoryBlock(
			allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: total,
			blockAllocator: blockAllocator, customBlockSource: nil, offsetToData: 0, dataLength: total,
			flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
		guard status == kCMBlockBufferNoErr, let block else { return nil }

		var dataPointer: UnsafeMutablePointer<CChar>?
		var lengthAtOffset = 0
		status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
		guard status == kCMBlockBufferNoErr, let raw = dataPointer, lengthAtOffset >= total else { return nil }

		let dst = UnsafeMutableRawPointer(raw)
		var w = 0
		for n in nals {
			switch AnnexB.kind(of: n.type, hevc: hevc) {
			case .vcl, .keep:
				let be = UInt32(n.length).bigEndian
				withUnsafeBytes(of: be) { dst.advanced(by: w).copyMemory(from: $0.baseAddress!, byteCount: 4) }
				dst.advanced(by: w + 4).copyMemory(from: base + n.offset, byteCount: n.length)
				w += 4 + n.length
			default:
				break
			}
		}

		var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
		var size = total
		var sample: CMSampleBuffer?
		status = CMSampleBufferCreateReady(
			allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
			sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
			sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
		guard status == noErr, let sample else { return nil }

		if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
			let yes = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
			let no = Unmanaged.passUnretained(kCFBooleanFalse).toOpaque()
			CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), isKeyframe ? no : yes)
			CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DependsOnOthers).toOpaque(), isKeyframe ? no : yes)
		}
		return sample
	}
}
