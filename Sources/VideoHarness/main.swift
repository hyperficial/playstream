// ps-video-harness: feeds an Annex-B elementary stream into PSVideo.VideoPipeline the way the
// protocol core does (header buffer first, then one buffer per frame, 64 bytes of zero padding after
// each buffer, delivered from a background thread at the stream frame rate).
//
//   ps-video-harness --file build/video-test/hdr_main10.hevc --codec hevchdr [--mode layer|metal]
//                    [--window] [--seconds 5] [--drop-at 200 --drop-count 5] [--corrupt-at 300]
//                    [--switch-mode-at 400] [--screenshot out.png] [--inline-ps] [--trailing-zeros]
//                    [--no-console-recovery] [--loop]
//   pacing / network: [--pacing off|adaptive] [--min-delay-ms 16.7] [--max-delay-ms 50]
//                    [--pattern steady|jitter|stall|mixed] [--jitter-ms 4] [--stall-every-ms 500]
//                    [--stall-min-ms 60] [--stall-max-ms 115] [--mixed-from 5 --mixed-to 12]
//                    [--send-fps 30] [--seed 1] [--switch-pacing-at SECONDS]
// --window / --fullscreen only open a window with PSVIDEO_ALLOW_WINDOW=1 (it never activates the app).

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
	var pacing: VideoPacingMode = .adaptive
	var minDelayMs: Double?
	var maxDelayMs: Double?
	var pattern = "steady"
	var jitterMs = 4.0
	var stallEveryMs = 500.0
	var stallMinMs = 60.0
	var stallMaxMs = 115.0
	var mixedFrom = 5.0
	var mixedTo = 12.0
	var sendFPS: Double?
	var seed: UInt64 = 1
	var switchPacingAt: Double?
	var makeMediaDir: String?
	var slipEveryMs = 0.0
	var fgMethod: VideoFrameGenerationMethod = .extrapolate
	var qualityRef: String?
	var upscaler: VideoUpscaler = .off
	var outputSize: CGSize?
	var sharpness = 0.5
	var frameGen: VideoFrameGeneration = .off
	var detectTruth: String?
	var fgEval = false
	var genTruth: String?
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
	case "--pacing": opt.pacing = next() == "off" ? .off : .adaptive
	case "--min-delay-ms": opt.minDelayMs = Double(next())
	case "--max-delay-ms": opt.maxDelayMs = Double(next())
	case "--pattern": opt.pattern = next()
	case "--jitter-ms": opt.jitterMs = Double(next()) ?? 4
	case "--stall-every-ms": opt.stallEveryMs = Double(next()) ?? 500
	case "--stall-min-ms": opt.stallMinMs = Double(next()) ?? 60
	case "--stall-max-ms": opt.stallMaxMs = Double(next()) ?? 115
	case "--mixed-from": opt.mixedFrom = Double(next()) ?? 5
	case "--mixed-to": opt.mixedTo = Double(next()) ?? 12
	case "--send-fps": opt.sendFPS = Double(next())
	case "--seed": opt.seed = UInt64(next()) ?? 1
	case "--switch-pacing-at": opt.switchPacingAt = Double(next())
	case "--make-media": opt.makeMediaDir = next()
	case "--slip-every-ms": opt.slipEveryMs = Double(next()) ?? 0
	case "--simulate-pacing": _ = next()
	case "--fg-method": opt.fgMethod = VideoFrameGenerationMethod(rawValue: next()) ?? .extrapolate
	case "--quality": opt.qualityRef = next()
	case "--upscaler": opt.upscaler = VideoUpscaler(rawValue: next()) ?? .off
	case "--sharpness": opt.sharpness = Double(next()) ?? 0.5
	case "--frame-gen": opt.frameGen = VideoFrameGeneration(rawValue: next()) ?? .off
	case "--detect-eval": opt.detectTruth = next()
	case "--fg-eval": opt.fgEval = true
	case "--gen-truth": opt.genTruth = next()
	case "--output-size":
		let p = next().split(separator: "x").compactMap { Double($0) }
		if p.count == 2 { opt.outputSize = CGSize(width: p[0], height: p[1]) }
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

if let dir = opt.makeMediaDir {
	exit(makeMedia(dir: dir) ? 0 : 1)
}

// Deterministic pacer simulation (no real-time scheduling): --simulate-pacing SECONDS
if let i = CommandLine.arguments.firstIndex(of: "--simulate-pacing"), i + 1 < CommandLine.arguments.count, let secs = Double(CommandLine.arguments[i + 1]) {
	let fps = opt.sendFPS ?? Double(opt.fps)
	let model = ArrivalModel(seed: opt.seed, interval: 1 / fps)
	let n = Int(secs * fps)
	let arrivals = (0..<n).map { 100.0 + model.arrival($0) }
	let refresh = 1.0 / 120
	for robust in [false, true] {
		let r = VideoPipeline.simulatePacing(arrivals: arrivals, fps: Int(fps), minDelayMs: opt.minDelayMs ?? 1000.0 / 60, maxDelayMs: opt.maxDelayMs ?? 50, robust: robust)
		let shown = r.frames.filter { !$0.skip }
		var hist = [Int](repeating: 0, count: 8)
		var prevSlot: Int?
		for f in shown {
			let slot = Int((f.target / refresh).rounded(.up))
			if let p = prevSlot { hist[min(7, max(0, slot - p))] += 1 }
			prevSlot = slot
		}
		let total = Double(max(1, hist.reduce(0, +)))
		let d = r.frames.map { $0.delay * 1000 }.sorted()
		let lat = zip(r.frames, arrivals).map { ($0.target - $1) * 1000 }.sorted()
		let expected = Int((1 / fps / refresh).rounded())
		print(String(format: "%@: playout delay median %.1f p90 %.1f max %.1f ms; arrival->target median %.1f p95 %.1f ms; late %d, skipped %d, re-bases %d; %d-refresh cadence %.1f%% { %@ }",
		             robust ? "NEW (outliers ignored, slips re-based)" : "OLD (every late frame feeds the estimator)",
		             d[d.count / 2], d[Int(Double(d.count) * 0.9)], d.last!, lat[lat.count / 2], lat[Int(Double(lat.count) * 0.95)],
		             r.frames.filter { $0.late }.count, r.frames.filter { $0.skip }.count, r.rebases, expected, Double(hist[expected]) * 100 / total,
		             (1...7).filter { hist[$0] > 0 }.map { "\($0):\(String(format: "%.1f%%", Double(hist[$0]) * 100 / total))" }.joined(separator: " ")))
	}
	exit(0)
}

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

// On-screen windows steal focus from whoever is using this Mac, so they need an explicit opt-in.
if opt.window && ProcessInfo.processInfo.environment["PSVIDEO_ALLOW_WINDOW"] != "1" {
	print("--window/--fullscreen disabled: set PSVIDEO_ALLOW_WINDOW=1 to open an on-screen window. Running headless.")
	opt.window = false
	opt.fullscreen = false
}
let app = NSApplication.shared
app.setActivationPolicy(opt.window ? .accessory : .prohibited)

let pipeline = VideoPipeline(displayMode: opt.mode, pacingMode: opt.pacing)
if let v = opt.minDelayMs { pipeline.minimumPlayoutDelayMs = v }
if let v = opt.maxDelayMs { pipeline.maximumPlayoutDelayMs = v }
pipeline.upscaler = opt.upscaler
pipeline.upscalerSharpness = opt.sharpness
pipeline.frameGenerationMethod = opt.fgMethod
pipeline.frameGeneration = opt.frameGen
let detectEval = opt.detectTruth.map { DetectEval(truthPath: $0) }
let interpEval = opt.fgEval ? InterpEval(dumpDir: opt.dumpDir) : nil
if let d = opt.dumpDir { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
if detectEval != nil || interpEval != nil {
	pipeline.setDecodedFrameObserver { pb in
		detectEval?.frame(pb)
		interpEval?.frame(pb)
	}
}
let displayLog = DisplayLog()
pipeline.setDisplayObserver { k, t, i in displayLog.add(k, t, i) }
if let o = opt.outputSize { pipeline.setOutputPixelSizeOverride(o) }
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
	w.orderFrontRegardless() // shown, but never made key and the app is never activated
	window = w
	if opt.fullscreen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.toggleFullScreen(nil) } }
}

// MARK: - Network arrival patterns

/// Deterministic PRNG so runs are repeatable.
struct SplitMix: RandomNumberGenerator {
	var state: UInt64
	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var z = state
		z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
		z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
		return z ^ (z >> 31)
	}
}

/// Arrival time (seconds after stream start) of frame `i`, sent by the console every 1/fps.
/// - steady: exactly on time.
/// - jitter: each frame delayed by a random 0...jitterMs (plus 0.3 ms base noise), order kept.
/// - stall: Wi-Fi off-channel stall of stallMin...stallMax ms roughly every stallEvery ms; frames
///   produced during the stall all arrive together when it ends (0.15 ms apart).
/// - mixed: steady (0.3 ms noise) before mixedFrom and after mixedTo seconds, stall pattern between.
final class ArrivalModel {
	private var rng: SplitMix
	private var stalls: [(start: Double, end: Double)] = []
	private var last = 0.0
	let interval: Double

	init(seed: UInt64, interval: Double) {
		rng = SplitMix(state: seed)
		self.interval = interval
		if opt.pattern == "stall" || opt.pattern == "mixed" || opt.pattern == "live" {
			var t = opt.pattern == "mixed" ? opt.mixedFrom : 0.4
			let end = opt.pattern == "mixed" ? opt.mixedTo : opt.seconds + 1
			while t < end {
				let len = uniform(opt.stallMinMs, opt.stallMaxMs) / 1000
				stalls.append((t, t + len))
				t += uniform(opt.stallEveryMs * 0.8, opt.stallEveryMs * 1.2) / 1000
			}
		}
	}

	private func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * Double.random(in: 0..<1, using: &rng) }

	func arrival(_ i: Int) -> Double {
		let ideal = Double(i) * interval
		var t = ideal + uniform(0, 0.0003)
		if opt.pattern == "jitter" || opt.pattern == "live" { t += uniform(0, opt.jitterMs / 1000) }
		// The console misses a frame every slipEveryMs: its timeline moves one interval later for good.
		if opt.slipEveryMs > 0 { t += (ideal * 1000 / opt.slipEveryMs).rounded(.down) * interval }
		if let s = stalls.first(where: { ideal >= $0.start && ideal < $0.end }) {
			t = max(t, s.end) // held by the stalled radio, then delivered in one burst
		}
		t = max(t, last + 0.00015)
		last = t
		return t
	}
}

// MARK: - On-screen measurement

/// Presentation events: (on-screen time, arrival time or nan) in host seconds.
final class PresentLog {
	private let lock = NSLock()
	private(set) var events: [(shown: Double, arrival: Double)] = []
	func add(_ shown: Double, _ arrival: Double) {
		lock.lock(); events.append((shown, arrival)); lock.unlock()
	}
	func snapshot() -> [(shown: Double, arrival: Double)] {
		lock.lock(); defer { lock.unlock() }; return events
	}
}
let presentLog = PresentLog()

/// Pacer decisions: (arrival, target or nan when pacing is off, skipped).
final class ScheduleLog {
	private let lock = NSLock()
	private(set) var events: [(arrival: Double, target: Double, skip: Bool)] = []
	func add(_ a: Double, _ t: Double, _ s: Bool) { lock.lock(); events.append((a, t, s)); lock.unlock() }
	func snapshot() -> [(arrival: Double, target: Double, skip: Bool)] { lock.lock(); defer { lock.unlock() }; return events }
}
let scheduleLog = ScheduleLog()
var arrivalLogLock = NSLock()

/// Layer path: the layer reports nothing about presentation, so poll the displayed pixel buffer once
/// per display refresh and note when it changes (resolution: one refresh).
final class LayerPoller: NSObject {
	var link: CADisplayLink?
	weak var last: CVPixelBuffer?
	var lastID: ObjectIdentifier?
	func start(in view: NSView) {
		let l = view.displayLink(target: self, selector: #selector(tick(_:)))
		let hz = Float(view.window?.screen?.maximumFramesPerSecond ?? 120)
		l.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
		l.add(to: .main, forMode: .common)
		link = l
	}
	@objc func tick(_ l: CADisplayLink) {
		guard let pb = pipeline.copyLastDecodedPixelBuffer() else { return }
		let id = ObjectIdentifier(pb)
		if id != lastID {
			lastID = id
			presentLog.add(l.timestamp, .nan)
		}
	}
}
let layerPoller = LayerPoller()

// MARK: - Feeder thread

final class FeedResult {
	var delivered = 0
	var falseReturns: [Int] = []
	var recoveries: [(failedAt: Int, recoveredAt: Int, keyframe: Bool)] = []
	var done = false
}
let result = FeedResult()
var streamStartHost = 0.0
let resultLock = NSLock()

/// The real network thread is woken by socket I/O; a timer-driven harness thread gets coalesced
/// wake-ups on a busy system (60-110 ms late seen). Make the feeder a time-constraint thread so the
/// arrival pattern is what the test asks for.
func makeFeederRealtime() {
	var tb = mach_timebase_info_data_t()
	mach_timebase_info(&tb)
	func ticks(_ ms: Double) -> UInt32 { UInt32(ms * 1_000_000 * Double(tb.denom) / Double(tb.numer)) }
	var policy = thread_time_constraint_policy_data_t(period: ticks(1000.0 / 60), computation: ticks(2), constraint: ticks(5), preemptible: 1)
	let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
	let r = withUnsafeMutablePointer(to: &policy) {
		$0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
			thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
		}
	}
	if r != KERN_SUCCESS { log("feeder: could not set time-constraint policy (\(r))") }
}
let harnessActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "ps-video-harness timing")

let feeder = Thread {
	makeFeederRealtime()
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
	let sendFPS = opt.sendFPS ?? Double(opt.fps)
	let model = ArrivalModel(seed: opt.seed, interval: 1 / sendFPS)
	let streamStart = mach_absolute_time() + UInt64(0.05 * 1e9 * Double(tb.denom) / Double(tb.numer))
	streamStartHost = Double(streamStart) * Double(tb.numer) / Double(tb.denom) / 1e9
	let totalTicks = Int(opt.seconds * sendFPS)
	var src = 0 // index into frames
	var lostPending = 0
	var failedSince: Int?
	var switched = false

	for tick in 0..<totalTicks {
		let at = model.arrival(tick)
		mach_wait_until(streamStart + UInt64(at * 1e9 * Double(tb.denom) / Double(tb.numer)))
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

func describePacing(_ s: VideoStats) -> String {
	var t = String(format: "pacing=%@ fps=%.0f jitter=%.2f/p95 %.2fms maxgap=%.1fms delay=%.1fms (target %.1f) late=%d skipped=%d dropped=%d",
		s.pacingMode.rawValue, s.streamFPS, s.arrivalJitterAvgMs, s.arrivalJitterP95Ms, s.arrivalMaxGapMs, s.playoutDelayMs, s.playoutTargetDelayMs, s.framesLate, s.framesSkipped, s.framesDropped)
	if let g = s.glassAvgMs { t += String(format: " glass=%.1fms", g) }
	if let a = s.presentedIntervalAvgMs, let m = s.presentedIntervalMaxMs { t += String(format: " shown-interval=%.1f/max %.1fms offCadence=%d", a, m, s.presentedOffCadence) }
	if let hz = s.displayRefreshHz { t += String(format: " refresh=%.0fHz", hz) }
	t += " upscaler=\(s.upscaler.rawValue)->\(s.activeUpscaler.rawValue) \(s.upscaleInputWidth)x\(s.upscaleInputHeight)->\(s.upscaleOutputWidth)x\(s.upscaleOutputHeight)"
	if let g = s.renderGPUTimeAvgMs, let m = s.renderGPUTimeMaxMs { t += String(format: " gpu=%.2f/%.2fms", g, m) }
	if let g = s.scalerGPUTimeAvgMs { t += String(format: " mfx=%.2fms", g) }
	t += " rebases=\(s.pacerRebases)"
	t += String(format: " presentedFPS=%.1f presentedRing=%d arrivalRing=%d", s.presentedFPS, s.recentPresentedIntervalsMs.count, s.recentArrivalIntervalsMs.count)
	if let a = s.recentArrivalIntervalsMs.last { t += String(format: " lastArrival=%.1fms", a) }
	if let p = s.frameTimeP99Ms, let m = s.frameTimeMaxMs { t += String(format: " frameTimeP99=%.1f max=%.1f", p, m) }
	if s.frameGeneration != .off {
		t += " method=\(s.frameGenerationMethod.rawValue) rejMotion=\(s.frameGenerationRejectedMotion)" + String(format: " motion=%.1fms warp=%.1fms", s.frameGenerationMotionMs, s.frameGenerationWarpMs)
		t += String(format: " fg=%@/%@ content=%.0ffps gen=%.0f/s total=%d fallbacks=%d cuts=%d added=%.1fms interp=%.1fms convert=%.2fms guard=%.2fms shifts=%d lateReal=%d lateGen=%d", s.frameGeneration.rawValue, s.frameGenerationState, s.contentFPS, s.generatedFPS, s.framesGenerated, s.frameGenerationFallbacks, s.frameGenerationCutsSkipped, s.frameGenerationAddedLatencyMs, s.frameGenerationTimeMs, s.frameGenerationConvertMs, s.frameGenerationGuardMs, s.frameGenerationSlotShifts, s.frameGenerationLateReal, s.presentsLateGenerated)
	}
	t += String(format: " lead=%.1fms", s.presentationLeadMs)
	t += " drops[kf=\(s.dropsAwaitingKeyframe) dec=\(s.dropsDecodeError) sup=\(s.dropsSuperseded) ovf=\(s.dropsQueueOverflow) nodrw=\(s.dropsNoDrawable)]"
	t += String(format: " qmax=%d drwwait=%.1fms", s.pacedQueueDepthMax, s.drawableWaitMaxMs)
	if let c = s.commitAheadMinMs { t += String(format: " commitAheadMin=%.1fms", c) }
	if let d = s.layerFrameDelayMs { t += String(format: " layerFrameDelay=%.2fms", d) }
	return t
}

/// Distribution of on-screen frame intervals (in display refreshes) and arrival-to-glass latency,
/// split into phases by stream time.
func summarizePresentation() {
	let ev = presentLog.snapshot()
	guard ev.count > 2 else {
		log("presentation: no on-screen events recorded (headless? layer path needs --window)")
		return
	}
	let refresh = 1.0 / Double(window?.screen?.maximumFramesPerSecond ?? 120)
	let source = opt.mode == .metal ? "Metal drawable presentedTime" : "layer: displayed-buffer poll at display refresh (±1 refresh)"
	var phases: [(String, Double, Double)] = [("all", -1, 1e9)]
	if opt.pattern == "mixed" {
		phases = [("clean-before", 1.0, opt.mixedFrom), ("bursty", opt.mixedFrom, opt.mixedTo), ("clean-after", opt.mixedTo, 1e9), ("clean-after +5s", opt.mixedTo + 5, 1e9)]
	} else {
		phases = [("all (after 1 s warm-up)", 1.0, 1e9)]
	}
	log("presentation (\(source)), refresh \(String(format: "%.2f", refresh * 1000)) ms:")
	for (name, from, to) in phases {
		var hist = [Int](repeating: 0, count: 7) // 0..5 refreshes, 6 = 6+
		var intervals: [Double] = []
		var lat: [Double] = []
		for i in 1..<ev.count {
			let t = ev[i].shown - streamStartHost
			guard t >= from && t < to else { continue }
			let dt = ev[i].shown - ev[i - 1].shown
			intervals.append(dt * 1000)
			hist[min(6, Int((dt / refresh).rounded()))] += 1
			if !ev[i].arrival.isNaN { lat.append((ev[i].shown - ev[i].arrival) * 1000) }
		}
		guard !intervals.isEmpty else { continue }
		intervals.sort()
		lat.sort()
		let n = Double(intervals.count)
		let histText = (0...6).filter { hist[$0] > 0 }.map { "\($0 == 6 ? "6+" : "\($0)"):\(String(format: "%.1f%%", Double(hist[$0]) * 100 / n))" }.joined(separator: " ")
		var line = String(format: "  %@: %d intervals, p50 %.1f p95 %.1f max %.1f ms; refreshes per frame { %@ }",
			name, intervals.count, intervals[intervals.count / 2], intervals[Int(n * 0.95) - (Int(n * 0.95) >= intervals.count ? 1 : 0)], intervals.last!, histText)
		if !lat.isEmpty {
			line += String(format: "; arrival->glass avg %.1f p95 %.1f max %.1f ms", lat.reduce(0, +) / Double(lat.count), lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))], lat.last!)
		}
		log(line)
	}
}

/// Planned presentation, headless: each shown frame's target (or its arrival when pacing is off)
/// snapped to the display's vsync grid. This is what reaches the glass if the system honours the
/// presentation times (the renderer adds a constant presentation lead on top, which the immediate path
/// pays too, so it is left out of the latency figure).
func summarizeSchedule() {
	let ev = scheduleLog.snapshot()
	guard ev.count > 10 else { return }
	let refresh = 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 120)
	let minDelay = pipeline.minimumPlayoutDelayMs
	var phases: [(String, Double, Double)]
	if opt.pattern == "mixed" {
		phases = [("clean-before", 1.0, opt.mixedFrom), ("bursty", opt.mixedFrom, opt.mixedTo), ("clean-after", opt.mixedTo, opt.mixedTo + 5), ("clean-after +5s", opt.mixedTo + 5, 1e9)]
	} else {
		phases = [("all (after 1 s warm-up)", 1.0, 1e9)]
	}
	log(String(format: "planned on-screen cadence (vsync grid %.2f ms, pacing %@):", refresh * 1000, pipeline.pacingMode.rawValue))
	for (name, from, to) in phases {
		var hist = [Int](repeating: 0, count: 8)
		var lat: [Double] = []
		var coalesced = 0, skipped = 0, n = 0
		var prevSlot: Int?
		for e in ev {
			let t = e.arrival - streamStartHost
			guard t >= from && t < to else { continue }
			if e.skip { skipped += 1; continue }
			let shownAt = e.target.isNaN ? e.arrival : e.target
			lat.append((shownAt - e.arrival) * 1000)
			let slot = Int((shownAt / refresh).rounded(.up))
			if let p = prevSlot {
				let d = slot - p
				if d <= 0 { coalesced += 1; continue } // replaced before it reached the glass
				hist[min(7, d)] += 1
				n += 1
			}
			prevSlot = max(slot, prevSlot ?? slot)
		}
		guard n > 0 else { continue }
		lat.sort()
		let histText = (1...7).filter { hist[$0] > 0 }.map { "\($0 == 7 ? "7+" : "\($0)"):\(String(format: "%.1f%%", Double(hist[$0]) * 100 / Double(n)))" }.joined(separator: " ")
		log(String(format: "  %@: %d frames; refreshes per frame { %@ }; never shown (2 in one vsync) %d, skipped %d; added delay avg %.1f p95 %.1f max %.1f ms",
			name, n, histText, coalesced, skipped, lat.reduce(0, +) / Double(lat.count), lat[min(lat.count - 1, Int(Double(lat.count) * 0.95))], lat.last!))
	}
	// Added delay per second of stream time (avg/max), to see adaptation and recovery.
	var series: [String] = []
	var sec = 0
	while true {
		let xs = ev.filter { !$0.target.isNaN && !$0.skip && Int($0.arrival - streamStartHost) == sec }.map { ($0.target - $0.arrival) * 1000 }
		if xs.isEmpty { if sec > Int(opt.seconds) + 1 { break } else { sec += 1; continue } }
		series.append(String(format: "%d:%.0f/%.0f", sec, xs.reduce(0, +) / Double(xs.count), xs.max()!))
		sec += 1
	}
	if !series.isEmpty { log("  added delay per second (s:avg/max ms): " + series.joined(separator: " ")) }
	if opt.pattern == "mixed" && pipeline.pacingMode == .adaptive {
		// When does the delay come back to the minimum after the link recovers?
		var recovered: Double?
		for e in ev where !e.target.isNaN && e.arrival - streamStartHost >= opt.mixedTo {
			let d = (e.target - e.arrival) * 1000
			if d <= minDelay + 1.5 { if recovered == nil { recovered = e.arrival - streamStartHost } } else { recovered = nil }
		}
		if let r = recovered {
			log(String(format: "  delay back at the minimum (%.1f ms) %.1f s after the link recovered, and stayed there", minDelay, r - opt.mixedTo))
		} else {
			log("  delay did NOT return to the minimum before the end of the run")
		}
	}
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

pipeline.presentedObserver = { shown, arrival in presentLog.add(shown, arrival) }
pipeline.scheduleObserver = { a, t, s in scheduleLog.add(a, t, s) }
if opt.window && opt.mode == .sampleBufferLayer {
	DispatchQueue.main.async { layerPoller.start(in: view) }
}
if let t = opt.switchPacingAt {
	DispatchQueue.main.asyncAfter(deadline: .now() + t) {
		pipeline.pacingMode = pipeline.pacingMode == .off ? .adaptive : .off
		log("pacing switched to \(pipeline.pacingMode.rawValue)")
	}
}
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
		if opt.quiet && opt.pattern != "none" { log(describePacing(pipeline.stats)) }
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
if let q = opt.qualityRef {
	if let d = opt.dumpDir { try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
	evaluateUpscaling(refPath: q, dumpDir: opt.dumpDir)
} else if let dir = opt.dumpDir, let pb = pipeline.copyLastDecodedPixelBuffer() {
	try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
	verifyAndDump(pb, dir: dir)
}
summarizePresentation()
summarizeSchedule()
detectEval?.report()
interpEval?.report()
if opt.frameGen != .off {
	let truth = opt.genTruth.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.split(separator: "\n").map { $0 == "1" } ?? []
	let n = Int(opt.seconds * Double(opt.fps))
	log("frame generation (display queue, planned on the vsync grid):")
	summarizeGeneration(displayLog, truth: truth, phases: [("first half", 30, n / 2), ("second half", n / 2, n + 1)])
}
log("PACING " + describePacing(final))
pipeline.videoStreamDidStop()
log("FINAL \(describe(final))")
log("tap: samples=\(tap.samples) keyframes=\(tap.keyframes) nonMonotonicPTS=\(tap.nonMonotonic) colour=\(tap.colorTags) paramSetsInFormatDesc=\(tap.hasParamSets)")
resultLock.lock()
log("feeder: delivered=\(result.delivered) falseReturns=\(result.falseReturns.count) \(result.falseReturns.prefix(12)) recoveries=\(result.recoveries.map { "\($0.failedAt)->\($0.recoveredAt)\($0.keyframe ? "(IDR)" : "")" }) keyframeRequests=\(console.requests)")
resultLock.unlock()
exit(0)
