import CoreMedia
import CoreVideo
import Darwin
import Foundation
import os
import PSContracts
import PSRecording
import VideoToolbox

// MARK: - Clocks

enum Clock {
	static let tb: mach_timebase_info_data_t = {
		var t = mach_timebase_info_data_t()
		mach_timebase_info(&t)
		return t
	}()
	static func ns(fromTicks t: UInt64) -> Int64 { Int64(t / UInt64(tb.denom) * UInt64(tb.numer) + (t % UInt64(tb.denom)) * UInt64(tb.numer) / UInt64(tb.denom)) }
	static func ticks(fromNs n: Int64) -> UInt64 { UInt64(n) / UInt64(tb.numer) * UInt64(tb.denom) + (UInt64(n) % UInt64(tb.numer)) * UInt64(tb.denom) / UInt64(tb.numer) }
	static func nowNs() -> Int64 { ns(fromTicks: mach_absolute_time()) }
	/// CoreMedia's host clock, the clock the video contract names.
	static func cmHostNow() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }
	static func sleep(untilNs t: Int64) { mach_wait_until(ticks(fromNs: t)) }
}

// MARK: - Keyframe requests

/// Plays the console: a keyframe request is answered after `latency` by forcing an IDR on the encoder.
final class KeyframeResponder: KeyframeRequesting {
	let latency: TimeInterval
	private let force = OSAllocatedUnfairLock(initialState: false)
	private let requests = OSAllocatedUnfairLock(initialState: 0)
	init(latency: TimeInterval) { self.latency = latency }
	var requestCount: Int { requests.withLock { $0 } }

	func requestKeyframe() {
		requests.withLock { $0 += 1 }
		DispatchQueue.global().asyncAfter(deadline: .now() + latency) { [force] in force.withLock { $0 = true } }
	}
	func takeForce() -> Bool { force.withLock { let v = $0; $0 = false; return v } }
	func forceNow() { force.withLock { $0 = true } }
}

// MARK: - Delivery (the "network thread" side of the contracts)

struct EventLog {
	var flashPTS: [Int: Int64] = [:]   // second -> host ns the flash frame was delivered with
	var beepOnset: [Int: Int64] = [:]  // second -> host ns the beep started (arrival - chunk duration)
}

final class Delivery {
	let tap: EncodedVideoTap
	let recorder: StreamRecorderControl
	private let lock = NSLock()
	private(set) var counting = false
	private(set) var delivered = 0
	private(set) var lostFrames = 0
	private(set) var flashes: [Int: Int64] = [:]
	private var streamIndex = 0
	var dropIndexes: Set<Int> = []        // stream indexes (of delivered-since-start frames) never delivered
	var notifyLoss = true
	private var pendingLossNote = false

	init(tap: EncodedVideoTap, recorder: StreamRecorderControl) { self.tap = tap; self.recorder = recorder }

	func startRecording(_ block: () -> Void) { lock.lock(); block(); counting = true; streamIndex = 0; lock.unlock() }
	func stopRecording(_ block: () -> Void) { lock.lock(); counting = false; block(); lock.unlock() }

	/// Called by the encoder output thread.
	func deliver(_ sample: CMSampleBuffer, isKey: Bool, frameNumber: Int, fps: Int) {
		lock.lock(); defer { lock.unlock() }
		var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: Clock.cmHostNow(), decodeTimeStamp: .invalid)
		var out: CMSampleBuffer?
		guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
			sampleTimingArray: &timing, sampleBufferOut: &out) == noErr, let out else { return }
		if counting {
			streamIndex += 1
			if dropIndexes.contains(streamIndex) {
				lostFrames += 1
				pendingLossNote = notifyLoss
				return
			}
			delivered += 1
			if frameNumber % fps == 0 { flashes[frameNumber / fps] = Clock.nanoseconds(out.presentationTimeStamp) }
		}
		if pendingLossNote { pendingLossNote = false; recorder.noteLoss() }
		let a = mach_absolute_time()
		tap.encodedVideoDidProduce(sampleBuffer: out, isKeyframe: isKey)
		let dt = Clock.ns(fromTicks: mach_absolute_time() - a)
		if counting { activeCalls += 1; activeTotalNs += dt; activeMaxNs = max(activeMaxNs, dt) } else { idleCalls += 1; idleTotalNs += dt; idleMaxNs = max(idleMaxNs, dt) }
	}
	private(set) var activeCalls = 0, activeTotalNs: Int64 = 0, activeMaxNs: Int64 = 0
	private(set) var idleCalls = 0, idleTotalNs: Int64 = 0, idleMaxNs: Int64 = 0
}

extension Clock {
	static func nanoseconds(_ t: CMTime) -> Int64 { CMTimeConvertScale(t, timescale: 1_000_000_000, method: .default).value }
}

/// Small shim so the harness code does not need the concrete recorder type in `Delivery`.
protocol StreamRecorderControl { func noteLoss() }

// MARK: - Video source

final class SyntheticVideo {
	enum Kind { case hevcHDR, h264SDR }
	let kind: Kind
	let fps: Int
	let responder: KeyframeResponder
	let delivery: Delivery
	let stripColorTags: Bool
	var nativeHDRMetadata = false
	private(set) var width: Int
	private(set) var height: Int
	private var session: VTCompressionSession?
	private var frameNumber = 0
	private var templates: Templates?
	private(set) var encodeFailures = 0
	private(set) var maxFrameInterval: Double = 0

	init(kind: Kind, width: Int, height: Int, fps: Int, responder: KeyframeResponder, delivery: Delivery, stripColorTags: Bool) {
		self.kind = kind; self.width = width; self.height = height; self.fps = fps
		self.responder = responder; self.delivery = delivery; self.stripColorTags = stripColorTags
	}

	private var pixelFormat: OSType {
		kind == .hevcHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
	}

	final class Templates {
		let w: Int, h: Int, ten: Bool
		var rowDark: [UInt8], rowFlash: [UInt8], bar: [UInt8], chroma: [UInt8]
		init(w: Int, h: Int, ten: Bool) {
			self.w = w; self.h = h; self.ten = ten
			func fill(_ v: Int, _ n: Int) -> [UInt8] {
				if ten {
					var a = [UInt8](repeating: 0, count: n * 2)
					let word = UInt16(v << 6)
					for i in 0..<n { a[2 * i] = UInt8(word & 0xFF); a[2 * i + 1] = UInt8(word >> 8) }
					return a
				}
				return [UInt8](repeating: UInt8(v >> 2), count: n)
			}
			rowDark = fill(180, w); rowFlash = fill(900, w); bar = fill(600, 64); chroma = fill(512, w)
		}
	}

	func makeSession() throws {
		let codec: CMVideoCodecType = kind == .hevcHDR ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
		var s: VTCompressionSession?
		let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
		let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec,
			encoderSpecification: spec as CFDictionary,
			imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
			compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &s)
		guard st == noErr, let s else { throw NSError(domain: "harness", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "VTCompressionSessionCreate \(st)"]) }
		func set(_ k: CFString, _ v: Any) {
			let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
			if r != noErr { print("  [synth] set \(k) failed \(r)") }
		}
		set(kVTCompressionPropertyKey_RealTime, true)
		set(kVTCompressionPropertyKey_AllowFrameReordering, false)
		set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 2)
		set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
		set(kVTCompressionPropertyKey_AverageBitRate, kind == .hevcHDR ? 20_000_000 : 12_000_000)
		if kind == .hevcHDR {
			set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main10_AutoLevel)
			set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_2020)
			set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ)
			set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_2020)
			if nativeHDRMetadata {
				set(kVTCompressionPropertyKey_MasteringDisplayColorVolume, StreamRecorder.HDRStaticMetadata.p3d65_1000nit.masteringDisplayColorVolume as CFData)
				set(kVTCompressionPropertyKey_ContentLightLevelInfo, StreamRecorder.HDRStaticMetadata.p3d65_1000nit.contentLightLevel as CFData)
			}
		} else {
			set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
			set(kVTCompressionPropertyKey_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2)
			set(kVTCompressionPropertyKey_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2)
			set(kVTCompressionPropertyKey_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)
		}
		VTCompressionSessionPrepareToEncodeFrames(s)
		session = s
		templates = Templates(w: width, h: height, ten: kind == .hevcHDR)
		responder.forceNow() // first frame of a (new) session is an IDR anyway
	}

	func resize(width w: Int, height h: Int) throws {
		if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(s) }
		width = w; height = h
		try makeSession()
	}

	func stop() {
		if let s = session { VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid); VTCompressionSessionInvalidate(s) }
		session = nil
	}

	/// Generates and encodes the next frame; `flash` draws a full-white frame (sync marker).
	func encodeNext() {
		guard let session, let t = templates, let pool = VTCompressionSessionGetPixelBufferPool(session) else { return }
		var pbOpt: CVPixelBuffer?
		guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt) == noErr, let pb = pbOpt else { encodeFailures += 1; return }
		let n = frameNumber
		let flash = n % fps == 0
		fill(pb, t, n, flash)
		if kind == .hevcHDR {
			CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
			CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
			CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
		}
		let props: CFDictionary? = responder.takeForce() ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
		let fpsLocal = fps
		let strip = stripColorTags
		let delivery = self.delivery
		let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: CMTime(value: Int64(n), timescale: CMTimeScale(fps)),
			duration: CMTime(value: 1, timescale: CMTimeScale(fps)), frameProperties: props, infoFlagsOut: nil) { status, _, sample in
			guard status == noErr, var sample else { return }
			let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
			let notSync = (atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
			if strip, let fmt = CMSampleBufferGetFormatDescription(sample), let stripped = SyntheticVideo.stripColor(fmt),
			   let re = SyntheticVideo.reformat(sample, stripped) { sample = re }
			delivery.deliver(sample, isKey: !notSync, frameNumber: n, fps: fpsLocal)
		}
		if st != noErr { encodeFailures += 1 }
		frameNumber += 1
	}

	private func fill(_ pb: CVPixelBuffer, _ t: Templates, _ n: Int, _ flash: Bool) {
		CVPixelBufferLockBaseAddress(pb, [])
		defer { CVPixelBufferUnlockBaseAddress(pb, []) }
		let bps = t.ten ? 2 : 1
		guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0), let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
		let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
		let barX = (n * 12) % (t.w - 64)
		t.rowDark.withUnsafeBytes { dark in t.rowFlash.withUnsafeBytes { fl in t.bar.withUnsafeBytes { bar in
			for row in 0..<t.h {
				let dst = y + row * ys
				memcpy(dst, flash ? fl.baseAddress! : dark.baseAddress!, t.w * bps)
				if !flash { memcpy(dst + barX * bps, bar.baseAddress!, 64 * bps) }
			}
		}}}
		t.chroma.withUnsafeBytes { ch in
			for row in 0..<(t.h / 2) { memcpy(c + row * cs, ch.baseAddress!, t.w * bps) }
		}
	}

	// Test aid: simulates a pipeline whose format description lacks colour tags.
	static func stripColor(_ fmt: CMFormatDescription) -> CMFormatDescription? {
		var ext = (CMFormatDescriptionGetExtensions(fmt) as? [String: Any]) ?? [:]
		for k in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix,
		          kCMFormatDescriptionExtension_MasteringDisplayColorVolume, kCMFormatDescriptionExtension_ContentLightLevelInfo] { ext.removeValue(forKey: k as String) }
		ext.removeValue(forKey: "VerbatimSampleDescription"); ext.removeValue(forKey: "VerbatimISOSampleEntry")
		let d = CMVideoFormatDescriptionGetDimensions(fmt)
		var out: CMVideoFormatDescription?
		CMVideoFormatDescriptionCreate(allocator: nil, codecType: CMFormatDescriptionGetMediaSubType(fmt), width: d.width, height: d.height, extensions: ext as CFDictionary, formatDescriptionOut: &out)
		return out
	}
	static func reformat(_ s: CMSampleBuffer, _ f: CMFormatDescription) -> CMSampleBuffer? {
		guard let data = CMSampleBufferGetDataBuffer(s) else { return nil }
		var timing = CMSampleTimingInfo(); CMSampleBufferGetSampleTimingInfo(s, at: 0, timingInfoOut: &timing)
		var size = CMSampleBufferGetSampleSize(s, at: 0)
		var out: CMSampleBuffer?
		CMSampleBufferCreateReady(allocator: nil, dataBuffer: data, formatDescription: f, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &out)
		if let out, let src = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [NSDictionary], let d = (CMSampleBufferGetSampleAttachmentsArray(out, createIfNecessary: true) as? [NSMutableDictionary])?.first, let first = src.first {
			d.addEntries(from: first as! [AnyHashable: Any])
		}
		return out
	}
}

// MARK: - Audio source

final class SyntheticAudio {
	let tap: PCMAudioTap
	let rate = 48000, channels = 2, chunk = 480
	enum Hiccup { case none, burst(atSec: Double, ms: Int), loss(atSec: Double, ms: Int) }
	var hiccup: Hiccup = .none
	var jitterMs = 2
	private let log = OSAllocatedUnfairLock(initialState: [Int: Int64]())
	private(set) var chunksSent = 0
	private(set) var tapCalls = 0, tapTotalNs: Int64 = 0, tapMaxNs: Int64 = 0
	private var stop = OSAllocatedUnfairLock(initialState: false)
	private var thread: Thread?
	private let done = DispatchSemaphore(value: 0)

	init(tap: PCMAudioTap) { self.tap = tap }
	var beepOnsets: [Int: Int64] { log.withLock { $0 } }

	func start(t0: Int64) {
		tap.pcmAudioDidConfigure(channels: channels, sampleRate: rate)
		let th = Thread { [self] in run(t0: t0); done.signal() }
		th.qualityOfService = .userInteractive
		th.start()
		thread = th
	}
	func stopAndJoin() { stop.withLock { $0 = true }; done.wait() }

	private func run(t0: Int64) {
		var n = 0
		var buf = [Int16](repeating: 0, count: chunk * channels)
		let chunkNs = Int64(chunk) * 1_000_000_000 / Int64(rate)
		var burstDone = false, lossDone = false
		while !stop.withLock({ $0 }) {
			let deadline = t0 + Int64(n + 1) * chunkNs
			switch hiccup {
			case .burst(let at, let ms) where !burstDone && Double(n) * 0.01 >= at:
				burstDone = true
				Clock.sleep(untilNs: Clock.nowNs() + Int64(ms) * 1_000_000) // late; following chunks arrive back to back
			case .loss(let at, let ms) where !lossDone && Double(n) * 0.01 >= at:
				lossDone = true
				n += ms / 10 // those chunks never arrive
				continue
			default: Clock.sleep(untilNs: deadline)
			}
			if jitterMs > 0 { usleep(UInt32.random(in: 0...(UInt32(jitterMs) * 1000))) }
			let s0 = n * chunk
			for i in 0..<chunk {
				let s = s0 + i
				let t = Double(s) / Double(rate)
				var l = 0.10 * sin(2 * .pi * 440 * t), r = 0.10 * sin(2 * .pi * 554.37 * t)
				let sec = s / rate, within = s % rate
				if within < 1440 { // 30 ms beep at the top of every second, same instant as the video flash
					let b = 0.8 * sin(2 * .pi * 2000 * t)
					l += b; r += b
					_ = sec
				}
				buf[2 * i] = Int16(max(-1, min(1, l)) * 32000)
				buf[2 * i + 1] = Int16(max(-1, min(1, r)) * 32000)
			}
			let host = mach_absolute_time()
			if s0 % rate == 0 { log.withLock { $0[s0 / rate] = Clock.ns(fromTicks: host) - chunkNs } }
			let a = mach_absolute_time()
			buf.withUnsafeBufferPointer { tap.pcmAudioDidReceive(pcm: $0, frameCount: chunk, hostTime: host) }
			let dt = Clock.ns(fromTicks: mach_absolute_time() - a)
			tapCalls += 1; tapTotalNs += dt; tapMaxNs = max(tapMaxNs, dt)
			n += 1
			chunksSent += 1
		}
	}
}
