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
//   --phases "wifi:180,clean:180,wifi:180"   link profile over time (wifi = 60-115 ms stall every ~0.5 s then the
//                                   backlog at once; mild = 30-80 ms every ~1 s; clean). Default: mild (clean with --no-jitter)
//   --fixed MS   pin the target (adaptive off)   --max-target MS (200)
//   --rate-flip   live: flip the output device's sample rate mid-run to exercise rebuild handling
//   --seed N

func arg(_ name: String) -> String? {
	guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
	return CommandLine.arguments[i + 1]
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

let mode = arg("--mode") ?? "live"
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

struct StallProfile {
	var durMin: Double, durMax: Double, afterMin: Double, afterMax: Double
	static let mild = StallProfile(durMin: 0.030, durMax: 0.080, afterMin: 0.5, afterMax: 1.2)
	static let wifi = StallProfile(durMin: 0.060, durMax: 0.115, afterMin: 0.33, afterMax: 0.47)
	static func named(_ n: String) -> StallProfile? {
		switch n {
		case "mild": return .mild
		case "wifi": return .wifi
		default: return nil
		}
	}
}

/// Link profile over time: (name, seconds). "clean" = no stalls.
func parsePhases(_ spec: String) -> [(String, Double)] {
	spec.split(separator: ",").compactMap { part in
		let kv = part.split(separator: ":")
		guard kv.count == 2, let d = Double(kv[1]) else { return nil }
		return (String(kv[0]), d)
	}
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
	var nextStall = 0.3
	var burstAt: Double?
	var burstChunks = 0
	var chunksDelivered = 0
	var stalls = 0
	var buf = [Int16](repeating: 0, count: 960)
	let phases: [(String, Double)]

	init(senderRate: Double, ampDb: Double, phases: [(String, Double)], seed: UInt64, burstAt: Double?, burstChunks: Int) {
		interval = 480.0 / senderRate
		amp = pow(10, ampDb / 20) * 32767
		rng = RNG(s: seed &* 7919 &+ 17)
		self.phases = phases
		self.burstAt = burstAt
		self.burstChunks = burstChunks
	}

	func profile(at t: Double) -> StallProfile? {
		var start = 0.0
		for (name, d) in phases {
			if t < start + d { return StallProfile.named(name) }
			start += d
		}
		return phases.last.flatMap { StallProfile.named($0.0) }
	}

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

	/// Delivers every chunk due by time `t` (seconds since start) to `sink`, with its arrival time.
	func deliver(upTo t: Double, _ sink: (UnsafeBufferPointer<Int16>, Double) -> Void) {
		if let b = burstAt, t >= b {
			shift += burstChunks
			burstAt = nil
		}
		while true {
			let tn = Double(n - shift) * interval
			if tn >= nextStall {
				if let p = profile(at: tn) {
					holdStart = nextStall
					holdEnd = holdStart + rng.range(p.durMin, p.durMax)
					nextStall = holdEnd + rng.range(p.afterMin, p.afterMax)
					stalls += 1
				} else {
					nextStall = tn + 0.25
				}
			}
			let te = (tn >= holdStart && tn < holdEnd) ? holdEnd : tn
			if te > t { break }
			fillChunk()
			buf.withUnsafeBufferPointer { sink(UnsafeBufferPointer(rebasing: $0[0..<960]), te) }
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

func makeConfiguration(headless: Bool) -> AudioPipelineConfiguration {
	var cfg = AudioPipelineConfiguration()
	cfg.headless = headless
	if let fixed = arg("--fixed").flatMap(Double.init) {
		cfg.targetBufferMs = fixed
		cfg.adaptive = false
	} else if let t = arg("--target").flatMap(Double.init) {
		cfg.targetBufferMs = t
	}
	if let m = arg("--max-target").flatMap(Double.init) { cfg.maxTargetMs = m }
	return cfg
}

func line(_ s: String) { print(s); fflush(stdout) }

// MARK: - Offline

func defaultPhases(_ seconds: Double) -> [(String, Double)] {
	if let spec = arg("--phases") { return parsePhases(spec) }
	return [(jitter ? "mild" : "clean", seconds)]
}

func runOffline() {
	let phases = defaultPhases(Double(arg("--seconds") ?? "") ?? 120)
	let seconds = arg("--phases") != nil ? phases.reduce(0) { $0 + $1.1 } : (Double(arg("--seconds") ?? "") ?? 120)
	let pipe = AudioPipeline(configuration: makeConfiguration(headless: true))
	let burstAt = arg("--burst-at").flatMap(Double.init)
	let feeder = Feeder(senderRate: senderRate, ampDb: ampDb, phases: phases, seed: seed,
	                    burstAt: burstAt, burstChunks: Int(arg("--burst-chunks") ?? "") ?? 7)
	pipe.audioStreamDidConfigure(channels: 2, sampleRate: 48000)

	let cb = 256  // render quantum (frames); 5.33 ms
	let total = Int(seconds * 48000) / cb * cb
	var out = [Float](repeating: 0, count: total)
	var block = [Float](repeating: 0, count: cb * 2)
	var lastUnderruns = 0
	var eventSamples: [Int] = []
	let cfg0 = pipe.stats
	line(String(format: "offline: %.0f s, %@ (min %.0f max %.0f ms), sender %.0f Hz, phases %@, burst %@", seconds,
	            cfg0.adaptiveTarget ? "adaptive" : "fixed", pipe.targetBufferMs, pipe.maxTargetMs, senderRate,
	            phases.map { "\($0.0):\(Int($0.1))s" }.joined(separator: ","), burstAt.map { "at \($0)s" } ?? "off"))

	// Per-second samples.
	var secTarget: [Double] = [], secBuf: [Double] = [], secGap: [Double] = [], secUnder: [Int] = [], secSkip: [Int] = [], secPlaying: [Double] = []
	var accBuf = 0.0, accN = 0, accPlay = 0.0
	var k = 0
	while k * cb < total {
		let t = Double(k * cb) / 48000
		feeder.deliver(upTo: t) { chunk, te in
			pipe.audioStreamDidReceive(pcm: chunk, frameCount: 480, simulatedArrivalSeconds: te)
		}
		pipe.renderHeadless(into: &block, frameCount: cb)
		for i in 0..<cb { out[k * cb + i] = block[i * 2] }
		let st = pipe.stats
		if st.underruns != lastUnderruns { lastUnderruns = st.underruns; eventSamples.append(k * cb) }
		accBuf += st.bufferedMs
		accPlay += st.isPlaying ? 1 : 0
		accN += 1
		if (k + 1) * cb % 48000 < cb {
			secTarget.append(st.targetMs); secBuf.append(accBuf / Double(accN)); secGap.append(st.longestGapMs)
			secUnder.append(st.underruns); secSkip.append(st.skips); secPlaying.append(accPlay / Double(accN))
			accBuf = 0; accN = 0; accPlay = 0
		}
		k += 1
	}
	let st = pipe.stats

	// Per-phase report.
	var start = 0
	for (name, dur) in phases {
		let end = min(secTarget.count, start + Int(dur))
		guard end > start + 1 else { break }
		let u0 = start == 0 ? 0 : secUnder[start - 1]
		let uEnd = secUnder[end - 1]
		let minutes = Double(end - start) / 60
		let settleFrom = max(start, end - 30)
		let settled = secTarget[settleFrom..<end].reduce(0, +) / Double(end - settleFrom)
		var lastOut = start
		for i in start..<end where abs(secTarget[i] - settled) > max(5, 0.1 * settled) { lastOut = i + 1 }
		let uAfter = secUnder[end - 1] - secUnder[min(end - 1, start + 30)]
		let bufMean = secBuf[settleFrom..<end].reduce(0, +) / Double(end - settleFrom)
		line(String(format: "phase %-5@ %4.0f s: underruns %3d (%.1f/min), after first 30 s %.1f/min | skips %d | target min %.0f max %.0f, settled %.0f ms (stays within band after %d s) | buffered mean (last 30 s) %.0f ms",
		            name, dur, uEnd - u0, Double(uEnd - u0) / minutes, Double(uAfter) / (Double(end - start - 30) / 60), secSkip[end - 1] - (start == 0 ? 0 : secSkip[start - 1]),
		            secTarget[start..<end].min() ?? 0, secTarget[start..<end].max() ?? 0, settled, lastOut - start, bufMean))
		// Timeline: target and buffered level.
		var row = "   t+s :"
		var row2 = "target :"
		var row3 = "buffer :"
		var row4 = "gap10s :"
		for d in [1, 2, 3, 5, 8, 12, 20, 30, 45, 60, 90, 120, 150, 179] where start + d < end {
			row += String(format: " %5d", d)
			row2 += String(format: " %5.0f", secTarget[start + d])
			row3 += String(format: " %5.0f", secBuf[start + d])
			row4 += String(format: " %5.0f", secGap[start + d])
		}
		line(row); line(row2); line(row3); line(row4)
		start = end
	}
	let fills = secBuf.dropFirst(2)
	line(String(format: "overall: chunks fed %d (%d stalls)  underruns %d  skips %d  overruns %d  mean buffered %.1f ms", feeder.chunksDelivered, feeder.stalls, st.underruns, st.skips, st.overruns, fills.reduce(0, +) / Double(max(1, fills.count))))

	// Click analysis: second difference of a smooth sine stays under A*(2*pi*fmax/fs)^2 even when resampled by 4 %.
	let a = pow(10, ampDb / 20)
	let bound = a * pow(2 * Double.pi * 1500 / 48000 * 1.04, 2) * 1.3 + 0.0002
	var nearSilence = [Bool](repeating: false, count: total)
	var run = 0
	for i in 0..<total {
		if out[i] == 0 { run += 1 } else {
			if run >= 24 { for j in max(0, i - run - 400)..<min(total, i + 400) { nearSilence[j] = true } }
			run = 0
		}
	}
	for e in eventSamples { for j in max(0, e - cb)..<min(total, e + 2 * cb + 400) { nearSilence[j] = true } }
	var clicks = 0
	var worst = 0.0
	var worstAt = 0
	var firstClicks: [Int] = []
	if total > 2 {
		for i in 1..<(total - 1) where !nearSilence[i] && !nearSilence[i - 1] && !nearSilence[i + 1] {
			let d2 = Double(abs(out[i + 1] - 2 * out[i] + out[i - 1]))
			if d2 > worst { worst = d2; worstAt = i }
			if d2 > bound { clicks += 1; if firstClicks.count < 8 { firstClicks.append(i) } }
		}
	}
	for c in firstClicks {
		let near = eventSamples.min(by: { abs($0 - c) < abs($1 - c) }).map { $0 - c } ?? 0
		line("  click at \(c) (\(String(format: "%.3f", Double(c) / 48000)) s): nearest underrun callback offset \(near) samples; out[c-3...c+3] = \((-3...3).map { String(format: "%.4f", out[c + $0]) })")
	}
	line(String(format: "click check outside underrun fades: max |d2| %.5f at %.3fs, bound %.5f, exceedances %d",
	            worst, Double(worstAt) / 48000, bound, clicks))
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
	let pipe = AudioPipeline(configuration: makeConfiguration(headless: false))
	pipe.logHandler = { line("  [audio] \($0)") }
	pipe.volume = Float(arg("--volume") ?? "") ?? 1
	let tap = CountingTap()
	pipe.pcmTap = tap
	let burstChunks = Int(arg("--burst-chunks") ?? "") ?? 7
	let burstAt = arg("--burst-at").flatMap(Double.init) ?? (jitter && seconds >= 5 ? 3.0 : nil)
	let feeder = Feeder(senderRate: senderRate, ampDb: ampDb, phases: defaultPhases(seconds), seed: seed, burstAt: burstAt, burstChunks: burstChunks)
	line(String(format: "live: %.0f s, target %.0f ms, sender %.0f Hz, amp %.0f dBFS, volume %.2f, jitter %@, burst %@",
	            seconds, pipe.targetBufferMs, senderRate, ampDb, pipe.volume, jitter ? "on" : "off", burstAt.map { "at \($0)s" } ?? "off"))

	nonisolated(unsafe) var running = true
	let start = machSeconds() + 0.05
	let thread = Thread {
		pipe.audioStreamDidConfigure(channels: 2, sampleRate: 48000)
		while running {
			let t = machSeconds() - start
			feeder.deliver(upTo: t) { chunk, _ in
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
	line("t(s)  buffered  target  play  under  skip  overrun  trim(ppm)  devHz   outLat(ms)  total(ms)  maxgap(ms)")
	while true {
		let t = machSeconds() - start
		if t >= seconds + 0.3 { break }
		if t >= next {
			let s = pipe.stats
			if t > 1.5 && s.isPlaying { samples.append(s.bufferedMs) }
			if t - lastPrint >= 0.5 {
				lastPrint = t
				line(String(format: "%4.1f  %6.1f ms %5.0f   %@    %3d   %3d   %3d    %6d   %6.0f  %8.1f   %8.1f   %6.0f",
				            t, s.bufferedMs, s.targetMs, s.isPlaying ? "y" : "n", s.underruns, s.skips, s.overruns,
				            s.driftTrimPPM, s.outputSampleRate, s.outputLatencyMs, s.totalLatencyMs, s.longestGapMs))
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
