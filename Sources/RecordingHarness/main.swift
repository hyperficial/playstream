import Combine
import CoreMedia
import Darwin
import Foundation
import PSContracts
import PSRecording

// ps-recording-harness: synthesises a console stream (VideoToolbox HEVC Main10 / H.264, sine + beeps),
// pushes it through StreamRecorder's tap methods from separate threads and inspects the files with ffprobe.
//
//   ps-recording-harness [--out DIR] [--seconds N] [scenario ...]
//   scenarios: hevc-hdr h264-sdr-pcm hevc-resize hevc-notags crash   (default: all)

struct Scenario {
	var name: String
	var kind: SyntheticVideo.Kind
	var width = 1920, height = 1080, fps = 60
	var seconds = 14.0
	var startAt = 3.3
	var stopAt: Double? = nil
	var resize: (at: Double, w: Int, h: Int)? = nil
	var dropStreamIndexes: [Int] = []
	var notifyLoss = true
	var audio: StreamRecorder.AudioMode = .aacHigh
	var hiccup: SyntheticAudio.Hiccup = .none
	var keyframeLatencyMs = 250
	var stripTags = false
	var fallbackTags = false
	var expectSegments = 1
	var neverStop = false
	var nativeHDRMetadata = false
	var fallbackHDRMetadataExpected = false
	var noAudio = false
	var stall: (after: Double, duration: Double)?
	var maxPendingVideo: Int?
	var maxPendingAudio: Int?
	var expectBackpressure = false
}

final class RecorderShim: StreamRecorderControl {
	let r: StreamRecorder
	init(_ r: StreamRecorder) { self.r = r }
	func noteLoss() { r.noteVideoLoss() }
}

func ms(_ s: Double) -> String { s.isNaN ? "n/a" : String(format: "%.1f ms", s * 1000) }
func sec(_ s: Double) -> String { s.isNaN ? "n/a" : String(format: "%.3f s", s) }

var problems: [String] = []
func check(_ ok: Bool, _ what: String) {
	print("  [\(ok ? "PASS" : "FAIL")] \(what)")
	if !ok { problems.append(what) }
}

func report(_ r: FileReport, hdr: Bool) {
	print("  file: \((r.path as NSString).lastPathComponent)  (\(r.size / 1024) KiB)")
	let v = r.video, a = r.audio
	print("    video: \(v.codec) profile=\(v.profile) tag=\(v.tag) pix_fmt=\(v.pixFmt) \(v.width)x\(v.height) primaries=\(v.primaries) transfer=\(v.transfer) matrix=\(v.matrix) range=\(v.range)")
	print("           packets=\(v.packets) decoded=\(r.decodedFrames) decodeErrorLines=\(r.decodeErrors) start=\(sec(v.startTime)) duration=\(sec(v.duration)) side_data=\(v.sideData)")
	print("    container colour atoms: colr=\(r.colr) mdcv=\(r.hasMdcv) clli=\(r.hasClli)")
	print("    audio: \(a.codec) tag=\(a.tag) \(a.sampleRate) Hz \(a.channels) ch bitrate=\(a.bitrate / 1000) kb/s start=\(sec(a.startTime)) duration=\(sec(a.duration)) decoded=\(sec(r.audioDecodedSeconds))")
	print("    container: duration=\(sec(r.formatDuration)) start=\(sec(r.formatStart))  audio-video start offset = \(ms(a.startTime - v.startTime))")
}

func runScenario(_ sc: Scenario, outDir: URL, directoryOverride: URL? = nil) -> (urls: [URL], recorder: StreamRecorder?) {
	let dir = directoryOverride ?? outDir.appendingPathComponent(sc.name)
	if directoryOverride == nil { try? FileManager.default.removeItem(at: dir) }
	try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

	let responder = KeyframeResponder(latency: Double(sc.keyframeLatencyMs) / 1000)
	var opts = StreamRecorder.Options(directory: dir)
	opts.audio = sc.audio
	if let st = sc.stall { opts.debugStallWriter = st }
	if let m = sc.maxPendingVideo { opts.maxPendingVideoFrames = m }
	if let m = sc.maxPendingAudio { opts.maxPendingAudioBuffers = m }
	if sc.fallbackTags { opts.fallbackColorTags = .hdr10; opts.fallbackHDRMetadata = .p3d65_1000nit }
	let recorder = DispatchQueue.main.sync { StreamRecorder(options: opts, keyframeRequester: responder) }
	let delivery = Delivery(tap: recorder, recorder: RecorderShim(recorder))
	delivery.dropIndexes = Set(sc.dropStreamIndexes)
	delivery.notifyLoss = sc.notifyLoss
	let video = SyntheticVideo(kind: sc.kind, width: sc.width, height: sc.height, fps: sc.fps, responder: responder, delivery: delivery, stripColorTags: sc.stripTags)
	video.nativeHDRMetadata = sc.nativeHDRMetadata
	let audio = SyntheticAudio(tap: recorder)
	audio.hiccup = sc.hiccup

	var states: [StreamRecorder.State] = []
	var maxElapsed = 0.0
	var bag = Set<AnyCancellable>()
	DispatchQueue.main.sync {
		recorder.$state.sink { states.append($0) }.store(in: &bag)
		recorder.$elapsed.sink { maxElapsed = max(maxElapsed, $0) }.store(in: &bag)
	}

	do { try video.makeSession() } catch { print("  encoder setup failed: \(error)"); exit(2) }
	let t0 = Clock.nowNs() + 300_000_000
	if !sc.noAudio { audio.start(t0: t0) }
	let frameNs = Int64(1_000_000_000 / sc.fps)
	let videoDone = DispatchSemaphore(value: 0)
	let videoThread = Thread {
		var i = 0
		var resized = false
		while true {
			let due = t0 + Int64(i) * frameNs
			let tSec = Double(due - t0) / 1e9
			if tSec >= sc.seconds { break }
			Clock.sleep(untilNs: due)
			if let r = sc.resize, !resized, tSec >= r.at { resized = true; try? video.resize(width: r.w, height: r.h) }
			video.encodeNext()
			i += 1
		}
		videoDone.signal()
	}
	videoThread.qualityOfService = .userInteractive
	videoThread.start()

	func wait(until t: Double) { let target = t0 + Int64(t * 1e9); let now = Clock.nowNs(); if target > now { usleep(UInt32((target - now) / 1000)) } }

	wait(until: sc.startAt)
	DispatchQueue.main.sync { delivery.startRecording { recorder.start() } }
	if sc.neverStop { Thread.sleep(forTimeInterval: 3600) }
	wait(until: sc.stopAt ?? (sc.seconds - 1))
	let stopped = DispatchSemaphore(value: 0)
	var urls: [URL] = []
	DispatchQueue.main.sync { delivery.stopRecording { recorder.stop { urls = $0; stopped.signal() } } }
	let t = Date()
	let finishedInTime = stopped.wait(timeout: .now() + 30) == .success
	let stopLatency = Date().timeIntervalSince(t)
	videoDone.wait()
	if !sc.noAudio { audio.stopAndJoin() }
	video.stop()

	print("== \(sc.name)")
	let (state, stats, bytes, elapsed, finished) = DispatchQueue.main.sync { (recorder.state, recorder.stats, recorder.bytesWritten, recorder.elapsed, recorder.finishedURLs) }
	print("  state sequence: \(states.map { "\($0)" }.joined(separator: " -> "))  final=\(state)  stop() took \(String(format: "%.0f", stopLatency * 1000)) ms")
	print("  published: elapsed=\(sec(elapsed)) (peak \(sec(maxElapsed))) bytesWritten=\(bytes / 1024) KiB files=\(finished.count)")
	print("  stats: \(stats)")
	print("  harness: delivered-while-recording=\(delivery.delivered) lost-in-network=\(delivery.lostFrames) keyframe requests=\(responder.requestCount) encodeFailures=\(video.encodeFailures)")
	func us(_ ns: Int64) -> String { String(format: "%.1f us", Double(ns) / 1000) }
	print("  tap call cost: video recording avg=\(us(delivery.activeCalls > 0 ? delivery.activeTotalNs / Int64(delivery.activeCalls) : 0)) max=\(us(delivery.activeMaxNs)) | idle avg=\(us(delivery.idleCalls > 0 ? delivery.idleTotalNs / Int64(delivery.idleCalls) : 0)) max=\(us(delivery.idleMaxNs)) | audio avg=\(us(audio.tapCalls > 0 ? audio.tapTotalNs / Int64(audio.tapCalls) : 0)) max=\(us(audio.tapMaxNs))")
	check(finishedInTime && state == .idle, "recorder ended in idle after stop()")
	check(Set(states.map { "\($0)" }).isSuperset(of: ["waitingForKeyframe", "recording", "finishing"]), "UI state went through waitingForKeyframe, recording, finishing")

	var packets = 0
	var syncDeltas: [Double] = []
	for (idx, u) in urls.enumerated() {
		let r = Probe.analyze(u.path)
		report(r, hdr: sc.kind == .hevcHDR)
		packets += r.video.packets
		check(r.ok && r.video.packets == r.decodedFrames && r.decodeErrors == 0, "segment \(idx + 1): every packet decodes cleanly (packets=\(r.video.packets) decoded=\(r.decodedFrames))")
		if sc.noAudio { print("    (no audio was delivered; audio packets in file: \(r.audio.packets))") }
		if !sc.noAudio { check(abs((r.audio.duration) - (r.video.duration)) < 0.2, "segment \(idx + 1): audio and video durations within 200 ms (\(sec(r.audio.duration)) vs \(sec(r.video.duration)))")
		check(abs(r.audio.startTime - r.video.startTime) < 0.05, "segment \(idx + 1): audio/video start offset < 50 ms") }
		if sc.kind == .hevcHDR {
			check(r.video.codec == "hevc" && r.video.profile == "Main 10" && r.video.pixFmt == "yuv420p10le", "segment \(idx + 1): HEVC Main 10, 10-bit")
			check(r.video.primaries == "bt2020" && r.video.transfer == "smpte2084" && r.video.matrix == "bt2020nc", "segment \(idx + 1): BT.2020 / PQ / bt2020nc tags (ffprobe)")
			if sc.name != "hevc-stripped-nofallback" {
				check(r.colr.contains("primaries=9 transfer=16 matrix=9"), "segment \(idx + 1): container colr atom carries BT.2020 / PQ / BT.2020nc (\(r.colr))")
			} else {
				check(r.colr == "none", "negative control: with tags stripped and no fallback the container has no colr atom (\(r.colr)); ffprobe's tags above come from the bitstream VUI")
			}
			if sc.fallbackHDRMetadataExpected { check(r.hasMdcv && r.hasClli && r.video.sideData.count == 2, "segment \(idx + 1): mdcv + clli written") }
		} else {
			check(r.video.codec == "h264" && r.video.pixFmt == "yuv420p", "segment \(idx + 1): H.264 8-bit")
		}
		// A/V sync: pair each beep with the flash frame nearest to it, compare with what the harness delivered.
		for b in r.beepTimes {
			if let f = r.flashTimes.min(by: { abs($0 - b) < abs($1 - b) }), abs(f - b) < 0.3 { syncDeltas.append(b - f) }
		}
		print("    flashes found=\(r.flashTimes.count) beeps found=\(r.beepTimes.count)")
	}
	if !syncDeltas.isEmpty {
		let flashLog = delivery.flashes, beepLog = audio.beepOnsets
		var expected: [Double] = []
		for (k, f) in flashLog { if let b = beepLog[k] { expected.append(Double(b - f) / 1e9) } }
		let mean = syncDeltas.reduce(0, +) / Double(syncDeltas.count)
		let expMean = expected.isEmpty ? Double.nan : expected.sorted()[expected.count / 2] // median: a delayed (burst) chunk is an outlier on purpose
		print("  A/V SYNC: measured beep-minus-flash in file: mean=\(ms(mean)) min=\(ms(syncDeltas.min()!)) max=\(ms(syncDeltas.max()!)) over \(syncDeltas.count) events; as delivered to the taps: median=\(ms(expMean))")
		print("  A/V SYNC ERROR introduced by recording (file - delivered) = \(ms(mean - expMean))")
		check(abs(mean - expMean) < 0.02, "A/V sync error under 20 ms")
	} else if !sc.noAudio { check(false, "A/V sync: no flash/beep pairs found in output") }

	if sc.expectBackpressure {
		check(stats.videoFramesDroppedBackpressure > 0 && stats.audioBuffersDroppedBackpressure > 0, "back-pressure drops were counted (video \(stats.videoFramesDroppedBackpressure), audio \(stats.audioBuffersDroppedBackpressure))")
		check(stats.peakPendingVideoFrames <= (sc.maxPendingVideo ?? 180) && stats.peakPendingAudioBuffers <= (sc.maxPendingAudio ?? 600), "queues stayed within their bounds (peak video \(stats.peakPendingVideoFrames), audio \(stats.peakPendingAudioBuffers))")
	}
	check(urls.count == sc.expectSegments, "number of files == \(sc.expectSegments) (got \(urls.count))")
	check(packets == stats.videoFramesWritten, "frames in files (\(packets)) == recorder's videoFramesWritten (\(stats.videoFramesWritten))")
	let accounted = stats.videoFramesWritten + stats.videoFramesDiscardedBeforeKeyframe + stats.droppedVideoFrames
	check(accounted == delivery.delivered, "frames delivered (\(delivery.delivered)) == written + discarded/dropped (\(accounted)); nothing lost silently")
	return (urls, recorder)
}

// MARK: - Lifecycle

func runLifecycle(outDir: URL) {
	print("== lifecycle")
	let dir = outDir.appendingPathComponent("lifecycle")
	try? FileManager.default.removeItem(at: dir)
	let rec = DispatchQueue.main.sync { StreamRecorder(options: StreamRecorder.Options(directory: dir)) }
	func onMain<T>(_ f: () -> T) -> T { DispatchQueue.main.sync(execute: f) }
	func stopAndWait() -> [URL] {
		let sem = DispatchSemaphore(value: 0)
		var out: [URL] = []
		onMain { rec.stop { out = $0; sem.signal() } }
		_ = sem.wait(timeout: .now() + 10)
		return out
	}
	check(stopAndWait().isEmpty && onMain({ rec.state }) == .idle, "stop() while idle completes with no files")
	check(onMain { rec.start() } == true, "start() accepted")
	check(onMain { rec.start() } == false, "second start() while running is refused")
	check(onMain({ rec.state }) == .waitingForKeyframe, "state is waitingForKeyframe right after start()")
	let urls = stopAndWait()
	check(urls.isEmpty && onMain({ rec.state }) == .idle, "stop() before any keyframe: no file, back to idle")
	check(!FileManager.default.fileExists(atPath: dir.path) || ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty, "no empty .mov left behind")
	// Unusable directory: ends in .failed with a message, and a later start() works again.
	let bad = DispatchQueue.main.sync { StreamRecorder(options: StreamRecorder.Options(directory: URL(fileURLWithPath: "/System/playstream-nope"))) }
	onMain { _ = bad.start() }
	Thread.sleep(forTimeInterval: 0.5)
	var failedMsg = ""
	if case .failed(let m) = onMain({ bad.state }) { failedMsg = m }
	check(!failedMsg.isEmpty, "unwritable folder reports .failed (\(failedMsg))")
	check(onMain { bad.start() } == true, "start() is accepted again after a failure")
	_ = { () -> Void in let s = DispatchSemaphore(value: 0); onMain { bad.stop { _ in s.signal() } }; _ = s.wait(timeout: .now() + 5) }()
}

// MARK: - Crash test

func runCrash(outDir: URL, seconds: Double) {
	print("== crash (child process recording, SIGKILL after \(Int(seconds)) s)")
	let dir = outDir.appendingPathComponent("crash")
	try? FileManager.default.removeItem(at: dir)
	try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
	let p = Process()
	p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
	p.arguments = ["--child-crash", dir.path]
	p.standardOutput = FileHandle.nullDevice
	try? p.run()
	Thread.sleep(forTimeInterval: seconds)
	kill(p.processIdentifier, SIGKILL)
	p.waitUntilExit()
	let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "mov" }
	check(files.count == 1, "child left a .mov behind")
	for f in files {
		let r = Probe.analyze(f.path, wantSync: false)
		report(r, hdr: true)
		check(r.ok && r.video.packets > 0, "file written by the killed process is readable (video packets=\(r.video.packets))")
		check(r.video.packets == r.decodedFrames && r.decodeErrors == 0, "all frames in the killed file decode (\(r.decodedFrames), error lines \(r.decodeErrors))")
		check(r.audio.packets > 0, "killed file has audio packets (\(r.audio.packets))")
		check(r.video.duration > 2, "killed file kept several seconds of video (\(sec(r.video.duration)); fragment interval is 2 s)")
	}
}

// MARK: - Entry

var args = Array(CommandLine.arguments.dropFirst())
var outPath = FileManager.default.currentDirectoryPath + "/build/recording-harness"
var secondsOverride: Double?
var names: [String] = []
var childDir: String?
while !args.isEmpty {
	let a = args.removeFirst()
	switch a {
	case "--out": outPath = args.removeFirst()
	case "--seconds": secondsOverride = Double(args.removeFirst())
	case "--child-crash": childDir = args.removeFirst()
	default: names.append(a)
	}
}
let outDir = URL(fileURLWithPath: outPath)

let all = ["lifecycle", "hevc-hdr", "h264-sdr-pcm", "hevc-resize", "hevc-notags", "hevc-noaudio", "hevc-stall", "hevc-stripped-nofallback", "hevc-hdrmeta", "crash"]
if names.isEmpty { names = all }

let worker = Thread {
	if let childDir {
		var sc = Scenario(name: "child", kind: .hevcHDR, seconds: 3600, startAt: 1.0)
		sc.neverStop = true
		_ = runScenario(sc, outDir: outDir, directoryOverride: URL(fileURLWithPath: childDir))
		exit(0)
	}
	for n in names {
		var sc: Scenario
		switch n {
		case "hevc-hdr":
			// Starts mid-GOP (3.3 s, GOP is 2 s), keyframe answer takes 250 ms. A 3 frame loss that is
			// reported, then a 12 frame (200 ms) loss that is only visible as a timestamp gap.
			sc = Scenario(name: n, kind: .hevcHDR, dropStreamIndexes: [300, 301, 302] + Array(520...531))
			sc.notifyLoss = true
		case "h264-sdr-pcm":
			sc = Scenario(name: n, kind: .h264SDR, audio: .lossless, hiccup: .none)
			sc.dropStreamIndexes = [200, 201, 202, 203]
			sc.hiccup = .burst(atSec: 5.0, ms: 150)
		case "hevc-resize":
			sc = Scenario(name: n, kind: .hevcHDR, seconds: 15, startAt: 2.2)
			sc.resize = (at: 7.0, w: 1280, h: 720)
			sc.expectSegments = 2
			sc.hiccup = .loss(atSec: 10.0, ms: 400)
		case "hevc-notags":
			sc = Scenario(name: n, kind: .hevcHDR, width: 1280, height: 720, seconds: 8, startAt: 1.5)
			sc.stripTags = true
			sc.fallbackTags = true
			sc.fallbackHDRMetadataExpected = true
		case "hevc-stripped-nofallback":
			// Negative control: tags stripped and no fallback configured, to prove the strip really removes them.
			sc = Scenario(name: n, kind: .hevcHDR, width: 1280, height: 720, seconds: 5, startAt: 1.5)
			sc.stripTags = true
		case "hevc-stall":
			// The writer stops accepting data for 1.5 s (a slow disk). Queues are bounded to 30 video frames / 40 audio buffers.
			sc = Scenario(name: n, kind: .hevcHDR, width: 1280, height: 720, seconds: 12, startAt: 1.5)
			sc.stall = (after: 3.0, duration: 1.5)
			sc.maxPendingVideo = 30
			sc.maxPendingAudio = 40
			sc.expectBackpressure = true
		case "hevc-noaudio":
			sc = Scenario(name: n, kind: .hevcHDR, width: 1280, height: 720, seconds: 7, startAt: 1.5)
			sc.noAudio = true
		case "lifecycle":
			runLifecycle(outDir: outDir)
			continue
		case "hevc-hdrmeta":
			sc = Scenario(name: n, kind: .hevcHDR, width: 1280, height: 720, seconds: 6, startAt: 1.5)
			sc.nativeHDRMetadata = true; sc.fallbackHDRMetadataExpected = true
		case "crash":
			runCrash(outDir: outDir, seconds: 8)
			continue
		default:
			print("unknown scenario \(n)"); continue
		}
		if let s = secondsOverride { sc.seconds = s }
		_ = runScenario(sc, outDir: outDir)
	}
	print("\n== SUMMARY: \(problems.isEmpty ? "all checks passed" : "\(problems.count) check(s) failed")")
	for p in problems { print("  FAIL: \(p)") }
	exit(problems.isEmpty ? 0 : 1)
}
worker.stackSize = 8 << 20
worker.start()
dispatchMain()
