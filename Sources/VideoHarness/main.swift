// ps-video-harness: feeds an Annex-B elementary stream into PSVideo.VideoPipeline the way the
// protocol core does (header buffer first, then one buffer per frame, 64 bytes of zero padding after
// each buffer, delivered from a background thread at the stream frame rate).
//
//   ps-video-harness --file build/video-test/hdr_main10.hevc --codec hevchdr [--mode layer|metal]
//                    [--window] [--seconds 5] [--drop-at 200 --drop-count 5] [--corrupt-at 300]
//                    [--switch-mode-at 400] [--screenshot out.png] [--inline-ps] [--trailing-zeros]
//                    [--no-console-recovery] [--loop]

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import PSContracts
@_spi(Diagnostics) import PSVideo
import CoreImage

// MARK: - Options

struct Options {
	var file = "build/video-test/hdr_main10.hevc"
	var codec: VideoCodec = .hevcHDR
	var mode: VideoDisplayMode = .sampleBufferLayer
	var window = false
	var seconds: Double = 5
	var fps = 60
	var dropAt: Int?
	var dropCount = 5
	var corruptAt: Int?
	var switchModeAt: Int?
	var screenshot: String?
	var screenshotAt: Double?
	var inlinePS = false
	var trailingZeros = false
	var consoleRecovery = true
	var loop = false
	var fullscreen = false
	var quiet = false
	var dumpDir: String?
	/// Second elementary stream; when the first runs out, its header is sent as a separate buffer
	/// (like the core does on an adaptive profile switch) and its frames follow.
	var thenFile: String?
}

var opt = Options()
var args = Array(CommandLine.arguments.dropFirst())
func next() -> String {
	guard !args.isEmpty else { fatalError("missing argument value") }
	return args.removeFirst()
}
while !args.isEmpty {
	let a = args.removeFirst()
	switch a {
	case "--file": opt.file = next()
	case "--codec":
		switch next() {
		case "h264": opt.codec = .h264
		case "hevc": opt.codec = .hevc
		default: opt.codec = .hevcHDR
		}
	case "--mode": opt.mode = next() == "metal" ? .metal : .sampleBufferLayer
	case "--window": opt.window = true
	case "--fullscreen": opt.window = true; opt.fullscreen = true
	case "--seconds": opt.seconds = Double(next()) ?? 5
	case "--fps": opt.fps = Int(next()) ?? 60
	case "--drop-at": opt.dropAt = Int(next())
	case "--drop-count": opt.dropCount = Int(next()) ?? 5
	case "--corrupt-at": opt.corruptAt = Int(next())
	case "--switch-mode-at": opt.switchModeAt = Int(next())
	case "--screenshot": opt.screenshot = next()
	case "--screenshot-at": opt.screenshotAt = Double(next())
	case "--inline-ps": opt.inlinePS = true
	case "--trailing-zeros": opt.trailingZeros = true
	case "--no-console-recovery": opt.consoleRecovery = false
	case "--loop": opt.loop = true
	case "--quiet": opt.quiet = true
	case "--dump": opt.dumpDir = next()
	case "--then": opt.thenFile = next()
	default:
		print("unknown option \(a)")
		exit(2)
	}
}

func log(_ s: String) {
	let t = String(format: "%7.3f", CACurrentMediaTime() - startTime)
	print("[\(t)] \(s)")
	fflush(stdout)
}

let startTime = CACurrentMediaTime()

// MARK: - Elementary stream splitting (independent of the module's own parser)

struct AccessUnit {
	var bytes: [UInt8]
	var keyframe: Bool
}

func splitStream(_ data: [UInt8], hevc: Bool, inlinePS: Bool) -> (header: [UInt8], frames: [AccessUnit]) {
	// Find NAL payload ranges.
	var starts: [Int] = []
	var i = 0
	while i + 2 < data.count {
		if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
			starts.append(i + 3)
			i += 3
		} else {
			i += 1
		}
	}
	var nals: [ArraySlice<UInt8>] = []
	for (k, s) in starts.enumerated() {
		var e = k + 1 < starts.count ? starts[k + 1] - 3 : data.count
		while e > s && data[e - 1] == 0 { e -= 1 }
		nals.append(data[s..<e])
	}
	func type(_ n: ArraySlice<UInt8>) -> Int { hevc ? Int((n.first! >> 1) & 0x3F) : Int(n.first! & 0x1F) }
	func isPS(_ t: Int) -> Bool { hevc ? (32...34).contains(t) : (t == 7 || t == 8) }
	func isVCL(_ t: Int) -> Bool { hevc ? t < 32 : (1...5).contains(t) }
	func isKey(_ t: Int) -> Bool { hevc ? (16...23).contains(t) : t == 5 }
	func firstSlice(_ n: ArraySlice<UInt8>) -> Bool {
		let b = n[n.startIndex + (hevc ? 2 : 1)]
		return b & 0x80 != 0 // HEVC first_slice_segment_in_pic_flag / H.264 first_mb_in_slice == 0
	}
	let sc: [UInt8] = [0, 0, 0, 1]

	var header: [UInt8] = []
	var frames: [AccessUnit] = []
	var pending: [UInt8] = [] // non-VCL NALs waiting for the next picture
	var current: AccessUnit?
	var sawVCL = false
	for n in nals {
		let t = type(n)
		if isPS(t) {
			if !sawVCL { header += sc + n } else if inlinePS { pending += sc + n }
			continue
		}
		if isVCL(t) {
			sawVCL = true
			if firstSlice(n) || current == nil {
				if let c = current { frames.append(c) }
				current = AccessUnit(bytes: pending, keyframe: false)
				pending = []
			}
			current!.bytes += sc + n
			if isKey(t) { current!.keyframe = true }
		} else if hevc ? (t == 35) : (t == 9) {
			continue // AUD: PS5 sends none
		} else {
			pending += sc + n // SEI etc.
		}
	}
	if let c = current { frames.append(c) }
	return (header, frames)
}

// MARK: - Simulated session / console

final class SimulatedConsole: KeyframeRequesting {
	private let lock = NSLock()
	private var _pending = false
	var requests = 0
	func requestKeyframe() {
		lock.lock()
		_pending = true
		requests += 1
		lock.unlock()
		log("console: keyframe requested via keyframeRequester")
	}

	func takeRequest() -> Bool {
		lock.lock()
		defer { lock.unlock() }
		let p = _pending
		_pending = false
		return p
	}

	func corruptReported() {
		lock.lock()
		_pending = true
		lock.unlock()
	}
}

final class TapCounter: EncodedVideoTap {
	var samples = 0
	var keyframes = 0
	var lastPTS = CMTime.invalid
	var nonMonotonic = 0
	var colorTags = ""
	var hasParamSets = false
	func encodedVideoDidProduce(sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
		samples += 1
		if isKeyframe { keyframes += 1 }
		let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
		if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 { nonMonotonic += 1 }
		lastPTS = pts
		if samples == 1, let fd = CMSampleBufferGetFormatDescription(sampleBuffer) {
			let ext = CMFormatDescriptionGetExtensions(fd) as NSDictionary? ?? [:]
			colorTags = [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix]
				.map { "\(ext[$0 as String] ?? "nil")" }.joined(separator: "/")
			let atoms = ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? NSDictionary
			hasParamSets = atoms?["hvcC"] != nil || atoms?["avcC"] != nil
			let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
			log(String(format: "tap: first sample PTS is %.1f ms before host clock now (expected ~0)", (hostNow - pts).seconds * 1000))
		}
	}
}

// MARK: - Load

let hevc = opt.codec.isHEVC
guard let fileData = FileManager.default.contents(atPath: opt.file) else {
	print("cannot read \(opt.file); run build/video-test/gen.sh first")
	exit(1)
}
var (header, frames) = splitStream([UInt8](fileData), hevc: hevc, inlinePS: opt.inlinePS)
var keyIdx = frames.indices.filter { frames[$0].keyframe }
var second: (header: [UInt8], frames: [AccessUnit])?
if let t = opt.thenFile {
	guard let d = FileManager.default.contents(atPath: t) else { print("cannot read \(t)"); exit(1) }
	second = splitStream([UInt8](d), hevc: hevc, inlinePS: opt.inlinePS)
	log("then: \(t): header \(second!.header.count) B, \(second!.frames.count) frames")
}
log("loaded \(opt.file): header \(header.count) B, \(frames.count) frames, keyframes at \(keyIdx.prefix(8).map(String.init).joined(separator: ","))…, avg frame \(frames.isEmpty ? 0 : frames.reduce(0) { $0 + $1.bytes.count } / frames.count) B")

// MARK: - Pipeline

let app = NSApplication.shared
app.setActivationPolicy(opt.window ? .regular : .prohibited)

let pipeline = VideoPipeline(displayMode: opt.mode)
let console = SimulatedConsole()
let tap = TapCounter()
pipeline.keyframeRequester = console
pipeline.encodedTap = tap

let view = VideoView(pipeline: pipeline)
var window: NSWindow?
if opt.window {
	let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
	w.title = "ps-video-harness \(opt.mode.rawValue) \(opt.file.split(separator: "/").last ?? "")"
	w.contentView = view
	w.collectionBehavior = [.fullScreenPrimary]
	w.makeKeyAndOrderFront(nil)
	app.activate(ignoringOtherApps: true)
	window = w
	if opt.fullscreen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.toggleFullScreen(nil) } }
}

// MARK: - Feeder thread

final class FeedResult {
	var delivered = 0
	var falseReturns: [Int] = []
	var recoveries: [(failedAt: Int, recoveredAt: Int, keyframe: Bool)] = []
	var done = false
}
let result = FeedResult()
let resultLock = NSLock()

let feeder = Thread {
	let padding = 64
	var scratch = [UInt8](repeating: 0, count: 4 << 20)
	func deliver(_ bytes: [UInt8], lost: Int, extraZeros: Int = 0) -> Bool {
		let n = bytes.count + extraZeros
		if scratch.count < n + padding { scratch = [UInt8](repeating: 0, count: n + padding) }
		return scratch.withUnsafeMutableBytes { buf -> Bool in
			bytes.withUnsafeBytes { buf.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
			memset(buf.baseAddress! + bytes.count, 0, extraZeros + padding)
			return pipeline.videoStreamDidReceive(accessUnit: UnsafeRawBufferPointer(start: buf.baseAddress!, count: n), framesLost: lost, frameRecovered: false)
		}
	}

	pipeline.videoStreamWillStart(profile: StreamProfile(width: 1920, height: 1080, fps: opt.fps, bitrateKbps: 30000, codec: opt.codec))
	_ = deliver(header, lost: 0)

	var tb = mach_timebase_info_data_t()
	mach_timebase_info(&tb)
	let periodTicks = UInt64(1_000_000_000 / Double(opt.fps) * Double(tb.denom) / Double(tb.numer))
	var nextTick = mach_absolute_time()
	let totalTicks = Int(opt.seconds * Double(opt.fps))
	var src = 0 // index into frames
	var lostPending = 0
	var failedSince: Int?
	var switched = false

	for tick in 0..<totalTicks {
		mach_wait_until(nextTick)
		nextTick += periodTicks
		if src >= frames.count {
			if let s2 = second {
				second = nil
				header = s2.header
				frames = s2.frames
				keyIdx = frames.indices.filter { frames[$0].keyframe }
				src = 0
				log("core: profile switch, sending new header (\(header.count) B)")
				_ = deliver(header, lost: 0)
			} else if opt.loop { src = keyIdx.first ?? 0 } else { break }
		}
		// The simulated console answers a keyframe request (or a corrupt-frame report) with an IDR
		// a couple of frames later; here: jump to the next keyframe in the file.
		if opt.consoleRecovery && console.takeRequest() {
			if let k = keyIdx.first(where: { $0 > src }) {
				log("console: sending keyframe (frame \(k)) instead of frame \(src)")
				src = k
			} else if opt.loop, let k = keyIdx.first {
				src = k
			}
		}
		if let d = opt.dropAt, src == d {
			log("network: dropping frames \(d)..<\(d + opt.dropCount)")
			src += opt.dropCount
			lostPending = opt.dropCount
			continue
		}
		if let s = opt.switchModeAt, src == s, !switched {
			switched = true
			DispatchQueue.main.async {
				let newMode: VideoDisplayMode = pipeline.displayMode == .metal ? .sampleBufferLayer : .metal
				log("switching display mode to \(newMode.rawValue)")
				pipeline.displayMode = newMode
			}
		}
		var bytes = frames[src].bytes
		if let c = opt.corruptAt, src == c {
			log("network: corrupting frame \(src) (slice data scrambled)")
			let startOfSlice = min(bytes.count - 1, 40)
			for j in startOfSlice..<bytes.count { bytes[j] = UInt8(truncatingIfNeeded: j &* 151 &+ 7) }
			bytes[bytes.count - 1] = 0x80
		}
		let ok = deliver(bytes, lost: lostPending, extraZeros: opt.trailingZeros ? 37 : 0)
		lostPending = 0
		resultLock.lock()
		result.delivered += 1
		if !ok {
			result.falseReturns.append(src)
			if failedSince == nil { failedSince = src }
			if opt.consoleRecovery { console.corruptReported() }
		} else if let f = failedSince {
			result.recoveries.append((f, src, frames[src].keyframe))
			log("recovered at frame \(src) (keyframe: \(frames[src].keyframe)) after first failure at \(f)")
			failedSince = nil
		}
		resultLock.unlock()
		if !ok && !opt.quiet { log("videoStreamDidReceive returned false for frame \(src)\(frames[src].keyframe ? " (keyframe)" : "")") }
		src += 1
		_ = tick
	}
	// Let the decoder drain before stopping.
	Thread.sleep(forTimeInterval: 0.3)
	resultLock.lock()
	result.done = true
	resultLock.unlock()
}
feeder.qualityOfService = .userInteractive
feeder.name = "simulated-network-thread"

func describe(_ s: VideoStats) -> String {
	var parts = [
		"mode=\(s.displayMode.rawValue)",
		"\(s.width)x\(s.height)",
		"codec=\(s.codec.map { "\($0)" } ?? "-")",
		"hdr=\(s.hdrActive)",
		"rx=\(s.framesReceived)",
		"dec=\(s.framesDecoded)",
		"drop=\(s.framesDropped)",
		"rej=\(s.framesRejected)",
		"lost=\(s.framesLostInNetwork)",
		"err=\(s.decodeErrors)",
		"kf=\(s.keyframesReceived)",
		"kfreq=\(s.keyframeRequests)",
		String(format: "fps=%.1f", s.decodedFPS),
		String(format: "handoff=%.2f/%.2fms", s.handoffAvgMs, s.handoffMaxMs),
	]
	if let a = s.decodeTimeAvgMs, let m = s.decodeTimeMaxMs { parts.append(String(format: "decode=%.2f/%.2fms", a, m)) }
	if let g = s.glassAvgMs { parts.append(String(format: "glass=%.2fms", g)) }
	parts.append(String(format: "edr=%.2f", s.edrHeadroom))
	return parts.joined(separator: " ")
}

func describePixelBuffer(_ pb: CVPixelBuffer) -> String {
	let fmt = CVPixelBufferGetPixelFormatType(pb)
	let fcc = String(bytes: [24, 16, 8, 0].map { UInt8((fmt >> $0) & 0xFF) }, encoding: .ascii) ?? "\(fmt)"
	let att = CVBufferCopyAttachments(pb, .shouldPropagate) as NSDictionary? ?? [:]
	let p = att[kCVImageBufferColorPrimariesKey as String] ?? "nil"
	let t = att[kCVImageBufferTransferFunctionKey as String] ?? "nil"
	let m = att[kCVImageBufferYCbCrMatrixKey as String] ?? "nil"
	return "\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) '\(fcc)' primaries=\(p) transfer=\(t) matrix=\(m)"
}

// MARK: - Picture verification

/// Compares the Metal shader output with CoreImage's own conversion of the same decoded picture and
/// writes viewable sRGB PNGs of both (HDR highlights clip in the PNG; it is for checking the picture,
/// not its brightness).
func verifyAndDump(_ pb: CVPixelBuffer, dir: String) {
	let hdr = pipeline.colorInfo?.isHDR ?? false
	let attSpace = CVBufferCopyAttachments(pb, .shouldPropagate).flatMap { CVImageBufferCreateColorSpaceFromAttachments($0)?.takeRetainedValue() }
	let outSpace = hdr ? CGColorSpace(name: CGColorSpace.itur_2100_PQ)! : (attSpace ?? CGColorSpace(name: CGColorSpace.itur_709)!)
	let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!, .workingFormat: CIFormat.RGBAh])
	let decoded = CIImage(cvPixelBuffer: pb)
	let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
	let decodedURL = URL(fileURLWithPath: dir).appendingPathComponent("decoded_coreimage.png")
	try? ci.writePNGRepresentation(of: decoded, to: decodedURL, format: .RGBA8, colorSpace: srgb)
	log("wrote \(decodedURL.path) (CoreImage rendering of the decoded picture)")

	guard let metal = pipeline.renderLastFrameOffscreen() else {
		log("metal offscreen render not available (not in metal mode)")
		return
	}
	// CoreImage reference in the same encoding the Metal pass outputs.
	let w = metal.width, h = metal.height
	var ref = [Float16](repeating: 0, count: w * h * 4)
	ref.withUnsafeMutableBytes { buf in
		ci.render(decoded, toBitmap: buf.baseAddress!, rowBytes: w * 8, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBAh, colorSpace: outSpace)
	}
	var sum = 0.0, maxd = 0.0, n = 0
	var hist = [Int](repeating: 0, count: 4) // <0.002, <0.01, <0.03, >=0.03
	for i in stride(from: 0, to: w * h * 4, by: 4) {
		for k in 0..<3 {
			// The drawable holds [0,1]; CoreImage leaves out-of-gamut values unclamped.
			let d = abs(Double(metal.rgba[i + k]) - min(1, max(0, Double(ref[i + k]))))
			sum += d
			maxd = max(maxd, d)
			n += 1
			hist[d < 0.002 ? 0 : d < 0.01 ? 1 : d < 0.03 ? 2 : 3] += 1
		}
	}
	let pct = hist.map { String(format: "%.2f%%", Double($0) * 100 / Double(n)) }
	log(String(format: "metal vs CoreImage (%@ encoded RGB): mean |diff| %.5f, max %.4f; share <0.002: %@, <0.01: %@, <0.03: %@, >=0.03: %@",
		hdr ? "PQ" : "BT.709", sum / Double(n), maxd, pct[0], pct[1], pct[2], pct[3]))
	// Centre pixel and a few probes, both encodings.
	for (px, py) in [(w / 2, h / 2), (w / 8, h / 8), (w * 7 / 8, h * 7 / 8)] {
		let i = (py * w + px) * 4
		log(String(format: "  probe (%4d,%4d): metal %.4f %.4f %.4f  coreimage %.4f %.4f %.4f", px, py,
			Double(metal.rgba[i]), Double(metal.rgba[i + 1]), Double(metal.rgba[i + 2]), Double(ref[i]), Double(ref[i + 1]), Double(ref[i + 2])))
	}
	let data = metal.rgba.withUnsafeBytes { Data($0) }
	let metalImage = CIImage(bitmapData: data, bytesPerRow: w * 8, size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: outSpace)

	let metalURL = URL(fileURLWithPath: dir).appendingPathComponent("metal_output.png")
	try? ci.writePNGRepresentation(of: metalImage, to: metalURL, format: .RGBA8, colorSpace: srgb)
	log("wrote \(metalURL.path) (Metal shader output)")
}

// MARK: - Run

feeder.start()
var lastPrint = CACurrentMediaTime()
var shotTaken = false
let deadline = Date().addingTimeInterval(opt.seconds + 3)
if opt.window { app.finishLaunching() }
while Date() < deadline {
	RunLoop.main.run(until: Date().addingTimeInterval(0.05))
	if opt.window {
		while let ev = app.nextEvent(matching: .any, until: nil, inMode: .default, dequeue: true) { app.sendEvent(ev) }
	}
	let now = CACurrentMediaTime()
	if now - lastPrint >= 1 {
		lastPrint = now
		if !opt.quiet { log(describe(pipeline.stats)) }
	}
	if let path = opt.screenshot, !shotTaken, let w = window, now - startTime >= (opt.screenshotAt ?? min(opt.seconds * 0.6, 3)) {
		shotTaken = true
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
		p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", path]
		try? p.run()
		p.waitUntilExit()
		log("screenshot -> \(path) (status \(p.terminationStatus))")
	}
	resultLock.lock()
	let done = result.done
	resultLock.unlock()
	if done { break }
}

let final = pipeline.stats
if let pb = pipeline.copyLastDecodedPixelBuffer() {
	log("last decoded picture: \(describePixelBuffer(pb))")
} else {
	log("last decoded picture: none available")
}
if let c = pipeline.colorInfo {
	log("format description colour: primaries=\(c.primaries) transfer=\(c.transferFunction) matrix=\(c.matrix) fullRange=\(c.fullRange) bitDepth=\(c.bitDepth) taggedInStream=\(c.taggedInStream)")
}
if let dir = opt.dumpDir, let pb = pipeline.copyLastDecodedPixelBuffer() {
	try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
	verifyAndDump(pb, dir: dir)
}
pipeline.videoStreamDidStop()
log("FINAL \(describe(final))")
log("tap: samples=\(tap.samples) keyframes=\(tap.keyframes) nonMonotonicPTS=\(tap.nonMonotonic) colour=\(tap.colorTags) paramSetsInFormatDesc=\(tap.hasParamSets)")
resultLock.lock()
log("feeder: delivered=\(result.delivered) falseReturns=\(result.falseReturns.count) \(result.falseReturns.prefix(12)) recoveries=\(result.recoveries.map { "\($0.failedAt)->\($0.recoveredAt)\($0.keyframe ? "(IDR)" : "")" }) keyframeRequests=\(console.requests)")
resultLock.unlock()
exit(0)
