import CoreAudio
import Darwin
import Foundation
import PSAudio
import PSContracts

// ps-audio-harness: feeds a synthetic sine sweep to AudioPipeline the way the network would.
//
//   live    (default)  real-time feed through the real output device, quiet (-30 dBFS by default)
//   offline            virtual-time run against the headless pipeline: thousands of x real time,
//                      silent, analyses the rendered samples for clicks
//
// Options:
//   --mode live|offline   --seconds N (default 6 live / 120 offline)   --target MS (35)
//   --sender-rate HZ (48050: sender clock vs the 48000 Hz consumer)    --amp-db DB (-30)
//   --volume V (live, default 1; use 0 for numbers only)               --no-jitter
//   --burst-at S --burst-chunks N   one burst without a preceding gap (default 3.0 s / 7 chunks live;
//                                   off unless given in offline mode)
//   --rate-flip   live: flip the output device's sample rate mid-run to exercise rebuild handling
//   --seed N

func arg(_ name: String) -> String? {
	guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
	return CommandLine.arguments[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

let mode = arg("--mode") ?? "live"
let targetMs = Double(arg("--target") ?? "") ?? 35
let senderRate = Double(arg("--sender-rate") ?? "") ?? 48050
let ampDb = Double(arg("--amp-db") ?? "") ?? -30
let jitter = !flag("--no-jitter")
let seed = UInt64(arg("--seed") ?? "") ?? 1

struct RNG {
	var s: UInt64
	mutating func next() -> Double {
		s = s &* 6364136223846793005 &+ 1442695040888963407
		return Double((s >> 11) & 0x1FFFFFFFFFFFFF) / Double(0x20000000000000)
	}
	mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

/// Produces 480-frame chunks on the sender's clock, with network-style gaps and bursts.
final class Feeder {
	let interval: Double
	let amp: Double
	var rng: RNG
	var n = 0
	var shift = 0
	var phase = 0.0
	var sampleIndex = 0
	var holdStart = -1.0, holdEnd = -1.0
	var nextStall: Double
	var burstAt: Double?
	var burstChunks = 0
	var chunksDelivered = 0
	var stalls = 0
	var buf = [Int16](repeating: 0, count: 960)

	init(senderRate: Double, ampDb: Double, jitter: Bool, seed: UInt64, burstAt: Double?, burstChunks: Int) {
		interval = 480.0 / senderRate
		amp = pow(10, ampDb / 20) * 32767
		rng = RNG(s: seed &* 7919 &+ 17)
		nextStall = jitter ? rng.range(0.4, 0.9) : .infinity
		self.burstAt = burstAt
		self.burstChunks = burstChunks
		self.jitter = jitter
	}
	let jitter: Bool

	func fillChunk() {
		for i in 0..<480 {
			let pos = Double(sampleIndex % (4 * 48000)) / Double(4 * 48000)
			let tri = pos < 0.5 ? pos * 2 : 2 - pos * 2  // up then down: no frequency jump at the wrap
			let f = 300.0 * pow(5.0, tri)
			phase += 2 * .pi * f / 48000
			if phase > 2 * .pi { phase -= 2 * .pi }
			let v = Int16(max(-32767, min(32767, sin(phase) * amp)))
			buf[i * 2] = v
			buf[i * 2 + 1] = v
			sampleIndex += 1
		}
	}

	/// Delivers every chunk due by time `t` (seconds since start) to `sink`.
	func deliver(upTo t: Double, _ sink: (UnsafeBufferPointer<Int16>) -> Void) {
		if let b = burstAt, t >= b {
			shift += burstChunks
			burstAt = nil
		}
		while true {
			let tn = Double(n - shift) * interval
			if tn >= nextStall {
				holdStart = nextStall
				holdEnd = holdStart + rng.range(0.030, 0.080)
				nextStall = holdEnd + rng.range(0.5, 1.2)
				stalls += 1
			}
			let te = (tn >= holdStart && tn < holdEnd) ? holdEnd : tn
			if te > t { break }
			fillChunk()
			buf.withUnsafeBufferPointer { sink(UnsafeBufferPointer(rebasing: $0[0..<960])) }
			chunksDelivered += 1
			n += 1
		}
	}

	/// Next time at which something may be due.
	func nextWake() -> Double {
		let tn = Double(n - shift) * interval
		return (tn >= holdStart && tn < holdEnd) ? holdEnd : tn
	}
}

func line(_ s: String) { print(s); fflush(stdout) }

// MARK: - Offline

func runOffline() {
	let seconds = Double(arg("--seconds") ?? "") ?? 120
	var cfg = AudioPipelineConfiguration()
	cfg.targetBufferMs = targetMs
	cfg.headless = true
	let pipe = AudioPipeline(configuration: cfg)
	let burstAt = arg("--burst-at").flatMap(Double.init)
	let feeder = Feeder(senderRate: senderRate, ampDb: ampDb, jitter: jitter, seed: seed,
	                    burstAt: burstAt, burstChunks: Int(arg("--burst-chunks") ?? "") ?? 7)
	pipe.audioStreamDidConfigure(channels: 2, sampleRate: 48000)

	let cb = 256  // render quantum (frames); 5.33 ms
	let total = Int(seconds * 48000) / cb * cb
	var out = [Float](repeating: 0, count: total)
	var block = [Float](repeating: 0, count: cb * 2)
	var fills: [Double] = []
	var fillTimeline: [(Double, Double)] = []
	var lastUnderruns = 0
	var eventSamples: [Int] = []  // render positions where an underrun happened
	line(String(format: "offline: %.0f s, target %.0f ms, sender %.0f Hz, jitter %@, burst %@", seconds, targetMs, senderRate,
	            jitter ? "on" : "off", burstAt.map { "at \($0)s" } ?? "off"))
	var maxFill = 0.0, minFill = 1e9
	var k = 0
	while k * cb < total {
		let t = Double(k * cb) / 48000
		feeder.deliver(upTo: t) { chunk in
			pipe.audioStreamDidReceive(pcm: chunk, frameCount: 480)
		}
		pipe.renderHeadless(into: &block, frameCount: cb)
		for i in 0..<cb { out[k * cb + i] = block[i * 2] }
		let st = pipe.stats
		if st.underruns != lastUnderruns { lastUnderruns = st.underruns; eventSamples.append(k * cb) }
		if st.isPlaying && t > 2 {
			fills.append(st.bufferedMs)
			maxFill = max(maxFill, st.bufferedMs)
			minFill = min(minFill, st.bufferedMs)
		}
		if k % (48000 * 10 / cb) == 0 || (burstAt != nil && abs(t - (burstAt! + 0.0)) < 0.006) {
			fillTimeline.append((t, st.bufferedMs))
		}
		k += 1
	}
	let st = pipe.stats
	line("t(s)   buffered(ms)")
	for (t, f) in fillTimeline { line(String(format: "%6.1f %7.1f", t, f)) }
	let mean = fills.reduce(0, +) / Double(max(1, fills.count))
	// Thirds of the run, to show there is no creep.
	let third = max(1, fills.count / 3)
	func avg(_ a: ArraySlice<Double>) -> Double { a.reduce(0, +) / Double(max(1, a.count)) }
	line(String(format: "buffered while playing (after 2 s): mean %.1f  min %.1f  max %.1f ms; thirds of run: %.1f / %.1f / %.1f",
	            mean, minFill, maxFill, avg(fills[0..<third]), avg(fills[third..<(2 * third)]), avg(fills[(2 * third)...])))
	line("chunks fed \(feeder.chunksDelivered) (\(feeder.stalls) gaps)  underruns \(st.underruns)  skips \(st.skips)  overruns \(st.overruns)  trim now \(st.driftTrimPPM) ppm")

	// Click analysis: second difference of a smooth sine stays under A*(2*pi*fmax/fs)^2 even when resampled by 1.5%.
	let a = pow(10, ampDb / 20)
	let bound = a * pow(2 * Double.pi * 1500 / 48000 * 1.015, 2) * 1.3 + 0.0002
	// Exempt underrun callbacks and neighbourhoods of exact silence (fade-out / priming) - those are counted as underruns.
	var nearSilence = [Bool](repeating: false, count: total)
	var run = 0
	for i in 0..<total {
		if out[i] == 0 { run += 1 } else {
			if run >= 24 { for j in max(0, i - run - 400)..<min(total, i + 400) { nearSilence[j] = true } }
			run = 0
		}
	}
	for e in eventSamples { for j in e..<min(total, e + cb + 400) { nearSilence[j] = true } }
	var clicks = 0
	var worst = 0.0
	var worstAt = 0
	var firstClicks: [Int] = []
	if total > 2 {
		for i in 1..<(total - 1) where !nearSilence[i] && !nearSilence[i - 1] && !nearSilence[i + 1] {
			let d2 = Double(abs(out[i + 1] - 2 * out[i] + out[i - 1]))
			if d2 > worst { worst = d2; worstAt = i }
			if d2 > bound { clicks += 1; if firstClicks.count < 12 { firstClicks.append(i) } }
		}
	}
	for c in firstClicks {
		let near = eventSamples.min(by: { abs($0 - c) < abs($1 - c) }).map { $0 - c } ?? 0
		line("  click at \(c): nearest underrun callback offset \(near) samples; out[c-3...c+3] = \((-3...3).map { String(format: "%.4f", out[c + $0]) })")
	}
	line(String(format: "click check outside silence gaps: max |d2| %.5f at %.3fs, bound %.5f, exceedances %d %@",
	            worst, Double(worstAt) / 48000, bound, clicks, firstClicks.map { String(format: "%.3fs", Double($0) / 48000) }.description))
	pipe.audioStreamDidStop()
}

// MARK: - Live

func machSeconds() -> Double {
	var tb = mach_timebase_info_data_t()
	mach_timebase_info(&tb)
	return Double(mach_absolute_time()) * Double(tb.numer) / Double(tb.denom) / 1e9
}
func sleepUntil(_ t: Double) {
	var tb = mach_timebase_info_data_t()
	mach_timebase_info(&tb)
	let ticks = UInt64(t * 1e9 * Double(tb.denom) / Double(tb.numer))
	mach_wait_until(ticks)
}

final class CountingTap: PCMAudioTap {
	var chunks = 0
	var configured = false
	var lastHost: UInt64 = 0
	func pcmAudioDidConfigure(channels: Int, sampleRate: Int) { configured = true }
	func pcmAudioDidReceive(pcm: UnsafeBufferPointer<Int16>, frameCount: Int, hostTime: UInt64) {
		chunks += 1
		lastHost = hostTime
	}
}

func runLive() {
	let seconds = Double(arg("--seconds") ?? "") ?? 6
	var cfg = AudioPipelineConfiguration()
	cfg.targetBufferMs = targetMs
	let pipe = AudioPipeline(configuration: cfg)
	pipe.logHandler = { line("  [audio] \($0)") }
	pipe.volume = Float(arg("--volume") ?? "") ?? 1
	let tap = CountingTap()
	pipe.pcmTap = tap
	let burstChunks = Int(arg("--burst-chunks") ?? "") ?? 7
	let burstAt = arg("--burst-at").flatMap(Double.init) ?? (jitter && seconds >= 5 ? 3.0 : nil)
	let feeder = Feeder(senderRate: senderRate, ampDb: ampDb, jitter: jitter, seed: seed, burstAt: burstAt, burstChunks: burstChunks)
	line(String(format: "live: %.0f s, target %.0f ms, sender %.0f Hz, amp %.0f dBFS, volume %.2f, jitter %@, burst %@",
	            seconds, targetMs, senderRate, ampDb, pipe.volume, jitter ? "on" : "off", burstAt.map { "at \($0)s" } ?? "off"))

	nonisolated(unsafe) var running = true
	let start = machSeconds() + 0.05
	let thread = Thread {
		pipe.audioStreamDidConfigure(channels: 2, sampleRate: 48000)
		while running {
			let t = machSeconds() - start
			feeder.deliver(upTo: t) { chunk in
				pipe.audioStreamDidReceive(pcm: chunk, frameCount: 480)
			}
			sleepUntil(start + min(feeder.nextWake(), t + 0.02))
		}
	}
	thread.qualityOfService = .userInteractive
	thread.start()

	var flipped = 0
	var origRate = 0.0
	var samples: [Double] = []
	var next = 0.0
	var lastPrint = -1.0
	line("t(s)  buffered  target  play  under  skip  overrun  trim(ppm)  devHz   outLat(ms)  total(ms)")
	while true {
		let t = machSeconds() - start
		if t >= seconds + 0.3 { break }
		if t >= next {
			let s = pipe.stats
			if t > 1.5 && s.isPlaying { samples.append(s.bufferedMs) }
			if t - lastPrint >= 0.5 {
				lastPrint = t
				line(String(format: "%4.1f  %6.1f ms %5.0f   %@    %3d   %3d   %3d    %6d   %6.0f  %8.1f   %8.1f",
				            t, s.bufferedMs, s.targetMs, s.isPlaying ? "y" : "n", s.underruns, s.skips, s.overruns,
				            s.driftTrimPPM, s.outputSampleRate, s.outputLatencyMs, s.totalLatencyMs))
			}
			next = t + 0.02
		}
		if flag("--rate-flip"), let dev = defaultOutputDevice() {
			if flipped == 0 && t > seconds * 0.35 {
				origRate = deviceRate(dev)
				let other: Double = origRate == 48000 ? 44100 : 48000
				line("  [harness] flipping device \(dev) sample rate \(origRate) -> \(other)")
				var r = other
				var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
				let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, 8, &r)
				line("  [harness] set rate status \(st)")
				flipped = 1
			} else if flipped == 1 && t > seconds * 0.35 + 1.5 {
				line("  [harness] restoring device sample rate to \(origRate)")
				var r = origRate
				var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
				_ = AudioObjectSetPropertyData(dev, &addr, 0, nil, 8, &r)
				flipped = 2
			}
		}
		usleep(5000)
	}
	running = false
	let s = pipe.stats
	if flipped == 1, let dev = defaultOutputDevice() {
		var r = origRate
		var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
		_ = AudioObjectSetPropertyData(dev, &addr, 0, nil, 8, &r)
	}
	pipe.audioStreamDidStop()
	let mean = samples.reduce(0, +) / Double(max(1, samples.count))
	line(String(format: "summary: buffered while playing mean %.1f min %.1f max %.1f ms | underruns %d skips %d overruns %d | chunks fed %d (%d gaps) tap saw %d | output builds %d",
	            mean, samples.min() ?? 0, samples.max() ?? 0, s.underruns, s.skips, s.overruns, feeder.chunksDelivered, feeder.stalls, tap.chunks, s.outputBuilds))

	// Reuse check: second session on the same object.
	pipe.audioStreamDidConfigure(channels: 2, sampleRate: 48000)
	let silence = [Int16](repeating: 0, count: 960)
	var playingSeen = false
	for _ in 0..<40 {
		silence.withUnsafeBufferPointer { pipe.audioStreamDidReceive(pcm: $0, frameCount: 480) }
		usleep(10_000)
		if pipe.stats.isPlaying { playingSeen = true }
	}
	line("reuse: second session on the same object reached playing=\(playingSeen), builds \(pipe.stats.outputBuilds)")
	pipe.audioStreamDidStop()
}

func defaultOutputDevice() -> AudioDeviceID? {
	var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
	var id = AudioDeviceID(0)
	var size = UInt32(4)
	return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
}
func deviceRate(_ dev: AudioDeviceID) -> Double {
	var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
	var r = 0.0
	var size = UInt32(8)
	_ = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &r)
	return r
}

switch mode {
case "offline": runOffline()
default: runLive()
}
