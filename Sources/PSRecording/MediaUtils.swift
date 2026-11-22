import CoreMedia
import Darwin
import Foundation

enum MediaUtils {
	private static let timebase: mach_timebase_info_data_t = {
		var t = mach_timebase_info_data_t()
		mach_timebase_info(&t)
		return t
	}()

	/// `mach_absolute_time()` ticks to nanoseconds, the unit of `CMClockGetHostTimeClock`.
	static func nanoseconds(fromMachTime t: UInt64) -> Int64 {
		let n = UInt64(timebase.numer), d = UInt64(timebase.denom)
		if n == d { return Int64(t) }
		return Int64(t / d * n + (t % d) * n / d)
	}

	static func nanoseconds(_ t: CMTime) -> Int64 {
		if t.timescale == 1_000_000_000 { return t.value }
		return CMTimeConvertScale(t, timescale: 1_000_000_000, method: .default).value
	}

	/// ns -> frames at `rate`, without overflowing for hosts with long uptime.
	static func frames(fromNanoseconds ns: Int64, rate: Int, roundUp: Bool = false) -> Int64 {
		let secs = ns / 1_000_000_000
		let rem = ns % 1_000_000_000
		let r = Int64(rate)
		let prod = rem * r
		var f = secs * r + prod / 1_000_000_000
		if roundUp && prod % 1_000_000_000 != 0 { f += 1 }
		return f
	}

	static func isSameFormat(_ a: CMFormatDescription, _ b: CMFormatDescription) -> Bool {
		a === b || CMFormatDescriptionEqual(a, otherFormatDescription: b)
	}

	static func audioFormatDescription(channels: Int, rate: Int) -> CMAudioFormatDescription? {
		var asbd = AudioStreamBasicDescription(
			mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
			mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
			mBytesPerPacket: UInt32(2 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(2 * channels),
			mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
		var layout = AudioChannelLayout()
		layout.mChannelLayoutTag = channelLayoutTag(channels)
		var out: CMAudioFormatDescription?
		let st = CMAudioFormatDescriptionCreate(
			allocator: nil, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
			magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &out)
		return st == noErr ? out : nil
	}

	static func channelLayoutTag(_ channels: Int) -> AudioChannelLayoutTag {
		switch channels {
		case 1: return kAudioChannelLayoutTag_Mono
		case 2: return kAudioChannelLayoutTag_Stereo
		case 6: return kAudioChannelLayoutTag_MPEG_5_1_A
		case 8: return kAudioChannelLayoutTag_MPEG_7_1_A
		default: return kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
		}
	}

	static func channelLayoutData(_ channels: Int) -> Data {
		var layout = AudioChannelLayout()
		layout.mChannelLayoutTag = channelLayoutTag(channels)
		return withUnsafeBytes(of: &layout) { Data($0) }
	}

	/// A copy of `sample` carrying `format`. The data buffer is shared, nothing is re-encoded.
	static func sample(_ sample: CMSampleBuffer, withFormat format: CMFormatDescription) -> CMSampleBuffer? {
		guard let data = CMSampleBufferGetDataBuffer(sample) else { return nil }
		var timing = CMSampleTimingInfo()
		guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
		var size = CMSampleBufferGetSampleSize(sample, at: 0)
		var out: CMSampleBuffer?
		let st = CMSampleBufferCreateReady(
			allocator: nil, dataBuffer: data, formatDescription: format, sampleCount: 1,
			sampleTimingEntryCount: 1, sampleTimingArray: &timing,
			sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &out)
		guard st == noErr, let out else { return nil }
		if let src = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary],
		   let first = src.first,
		   let dst = CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true) as? [NSMutableDictionary],
		   let d = dst.first {
			d.addEntries(from: first as! [AnyHashable: Any])
		}
		return out
	}

	/// Returns a format description with the fallback colour tags / HDR metadata added when missing, or nil if unchanged.
	static func retaggedFormat(
		_ fmt: CMFormatDescription, tags: StreamRecorder.ColorTags?, hdr: StreamRecorder.HDRStaticMetadata?
	) -> CMFormatDescription? {
		guard CMFormatDescriptionGetMediaType(fmt) == kCMMediaType_Video else { return nil }
		var ext = (CMFormatDescriptionGetExtensions(fmt) as? [String: Any]) ?? [:]
		var changed = false
		let keyP = kCMFormatDescriptionExtension_ColorPrimaries as String
		let keyT = kCMFormatDescriptionExtension_TransferFunction as String
		let keyM = kCMFormatDescriptionExtension_YCbCrMatrix as String
		if let tags, ext[keyP] == nil || ext[keyT] == nil || ext[keyM] == nil {
			ext[keyP] = ext[keyP] ?? tags.primaries
			ext[keyT] = ext[keyT] ?? tags.transfer
			ext[keyM] = ext[keyM] ?? tags.matrix
			changed = true
		}
		if let hdr, let t = ext[keyT] as? String, t == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) {
			let keyMD = kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
			let keyCL = kCMFormatDescriptionExtension_ContentLightLevelInfo as String
			var atoms = (ext["SampleDescriptionExtensionAtoms"] as? [String: Any]) ?? [:]
			if ext[keyMD] == nil {
				ext[keyMD] = hdr.masteringDisplayColorVolume
				// The writer copies sample description atoms verbatim; the extension keys alone are not written.
				if atoms["mdcv"] == nil { atoms["mdcv"] = hdr.masteringDisplayColorVolume }
				changed = true
			}
			if ext[keyCL] == nil {
				ext[keyCL] = hdr.contentLightLevel
				if atoms["clli"] == nil { atoms["clli"] = hdr.contentLightLevel }
				changed = true
			}
			ext["SampleDescriptionExtensionAtoms"] = atoms
		}
		guard changed else { return nil }
		// The verbatim blob is the original sample entry and the writer prefers it; it would hide our changes.
		ext.removeValue(forKey: "VerbatimSampleDescription")
		ext.removeValue(forKey: "VerbatimISOSampleEntry")
		let dims = CMVideoFormatDescriptionGetDimensions(fmt)
		var out: CMVideoFormatDescription?
		let st = CMVideoFormatDescriptionCreate(
			allocator: nil, codecType: CMFormatDescriptionGetMediaSubType(fmt), width: dims.width, height: dims.height,
			extensions: ext as CFDictionary, formatDescriptionOut: &out)
		return st == noErr ? out : nil
	}
}
