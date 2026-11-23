import Foundation
import PSAudio

// ps-audio-harness --mode effects
//
// Measures the sound shaping (dynamics, tone, voice boost, limiter) on the headless pipeline:
// virtual time, no audio device, silent. Prints what each preset does to level and frequency
// response, checks that a preset change does not click, and how much time the processing costs.

private struct Signal {
	var frequency: Double
	var levelDb: Double
	/// Right channel relative to left: 1 = centred, -1 = out of phase (nothing in the centre), 0 = left only.
	var right: Double = 1
}

private struct Measured {
	var peakDb: Double
	var rmsDb: Double
	/// Largest second difference of the left channel, relative to what a clean sine of the
	/// same frequency and output level has. About 1 means no click.
	var roughness: Double
	var limiterDb: Double
	var seconds: Double
}

private func db(_ linear: Double) -> Double { linear > 1e-9 ? 20 * log10(linear) : -180 }

/// Runs `seconds` of one sine through a fresh pipeline. `switchAt` calls the closure once at that
/// time (to change a preset mid-run). Measures from `measureFrom` seconds on.
private func run(
	_ signal: Signal, seconds: Double = 2.0, measureFrom: Double = 1.0,
	setup: (AudioPipeline) -> Void, switchAt: Double? = nil, change: ((AudioPipeline) -> Void)? = nil
) -> Measured {
	var cfg = AudioPipelineConfiguration()
	cfg.headless = true
	cfg.adaptive = false
	cfg.targetBufferMs = 40
	let pipe = AudioPipeline(configuration: cfg)
	setup(pipe)
	pipe.audioStreamDidConfigure(channels: 2, sampleRate: 48000)

	let cb = 256
	let total = Int(seconds * 48000) / cb * cb
	var block = [Float](repeating: 0, count: cb * 2)
	var chunk = [Int16](repeating: 0, count: 960)
	let amp = pow(10, signal.levelDb / 20) * 32767
	let w = 2 * Double.pi * signal.frequency / 48000
	var fed = 0
	var peak = 0.0, sum = 0.0, count = 0
	var limiter = 0.0
	var d2 = 0.0
	var p1 = 0.0, p2 = 0.0
	var switched = false
	let started = Date()
	var k = 0
	while k * cb < total {
		let t = Double(k * cb) / 48000
		// The sender is 10 ms chunks, delivered as time passes.
		while Double(fed) / 48000 <= t {
			for i in 0..<480 {
				let v = sin(w * Double(fed + i)) * amp
				chunk[i * 2] = Int16(max(-32767, min(32767, v.rounded())))
				chunk[i * 2 + 1] = Int16(max(-32767, min(32767, (v * signal.right).rounded())))
			}
			chunk.withUnsafeBufferPointer { pipe.audioStreamDidReceive(pcm: $0, frameCount: 480, simulatedArrivalSeconds: Double(fed) / 48000) }
			fed += 480
		}
		if let at = switchAt, !switched, t >= at {
			switched = true
			change?(pipe)
		}
		pipe.renderHeadless(into: &block, frameCount: cb)
		limiter = max(limiter, pipe.stats.limiterReductionDb)
		if t >= measureFrom {
			for i in 0..<cb {
				let l = Double(block[i * 2]), r = Double(block[i * 2 + 1])
				peak = max(peak, abs(l), abs(r))
				sum += l * l
				count += 1
				d2 = max(d2, abs(l - 2 * p1 + p2))
				p2 = p1
				p1 = l
			}
		} else {
			p2 = Double(block[(cb - 2) * 2])
			p1 = Double(block[(cb - 1) * 2])
		}
		k += 1
	}
	let elapsed = Date().timeIntervalSince(started)
	// A sine of amplitude A has a second difference of at most A * (2 - 2 cos w).
	let clean = max(peak, 1e-9) * (2 - 2 * cos(w))
	return Measured(peakDb: db(peak), rmsDb: db((sum / Double(max(1, count))).squareRoot()), roughness: d2 / clean, limiterDb: limiter, seconds: elapsed)
}

private func cell(_ value: Double) -> String { String(format: "%7.1f", value) }

func runEffects() {
	var failures: [String] = []
	func expect(_ ok: Bool, _ what: String) {
		line((ok ? "  ok    " : "  FAIL  ") + what)
		if !ok { failures.append(what) }
	}

	line("== Everything off ==")
	let plain = run(Signal(frequency: 1000, levelDb: -20)) { _ in }
	expect(abs(plain.peakDb + 20) < 0.1, String(format: "1 kHz at -20 dB comes out at %.2f dB", plain.peakDb))

	line("")
	line("== Dynamics: 1 kHz sine in, peak level out (dB) ==")
	line("     in      off    light    night")
	var table: [Double: [Double]] = [:]
	for level in stride(from: 0.0, through: -60.0, by: -10.0) {
		var row: [Double] = []
		for mode in AudioDynamics.allCases {
			row.append(run(Signal(frequency: 1000, levelDb: level)) { $0.dynamics = mode }.peakDb)
		}
		table[level] = row
		line(cell(level) + "  " + row.map(cell).joined(separator: "  "))
	}
	if let top = table[0], let quiet = table[-40], let floor = table[-60] {
		expect(top[1] < -4 && top[1] > -10, String(format: "Light takes full scale down to %.1f dB", top[1]))
		expect(quiet[1] > -37 && quiet[1] < -32, String(format: "Light lifts -40 dB to %.1f dB", quiet[1]))
		expect(top[2] < -9 && top[2] > -15, String(format: "Night takes full scale down to %.1f dB", top[2]))
		expect(quiet[2] > -31 && quiet[2] < -25, String(format: "Night lifts -40 dB to %.1f dB", quiet[2]))
		expect((top[2] - quiet[2]) < 20, String(format: "Night: 40 dB of range comes out as %.1f dB", top[2] - quiet[2]))
		expect(abs((floor[2] + 60) - 12) < 0.5, String(format: "Night lifts the quietest sound by %.1f dB", floor[2] + 60))
	}

	line("")
	line("== Tone: change in level by frequency (dB), sine at -30 dB, dynamics off ==")
	let frequencies: [Double] = [50, 110, 160, 300, 1000, 2800, 5000, 10000, 15000]
	line("    Hz   voices   bright     warm   night shelf   voice boost (centre)   (sides)")
	var response: [Double: [Double]] = [:]
	for f in frequencies {
		let voices = run(Signal(frequency: f, levelDb: -30)) { $0.tone = .voices }.peakDb + 30
		let bright = run(Signal(frequency: f, levelDb: -30)) { $0.tone = .bright }.peakDb + 30
		let warm = run(Signal(frequency: f, levelDb: -30)) { $0.tone = .warm }.peakDb + 30
		// The night shelf on its own: night against the same level through night at 1 kHz would
		// mix in the compressor, so measure far below its threshold and take the make-up gain off.
		let night = run(Signal(frequency: f, levelDb: -70)) { $0.dynamics = .night }.peakDb + 70 - 12
		let centre = run(Signal(frequency: f, levelDb: -30)) { $0.voiceBoost = true }.peakDb + 30
		let sides = run(Signal(frequency: f, levelDb: -30, right: -1)) { $0.voiceBoost = true }.peakDb + 30
		response[f] = [voices, bright, warm, night, centre, sides]
		line(String(format: "%6.0f", f) + "  " + [voices, bright, warm].map(cell).joined(separator: "  ") + "       " + cell(night) + "               " + cell(centre) + "   " + cell(sides))
	}
	if let low = response[50], let mid = response[1000], let presence = response[2800], let high = response[10000] {
		expect(low[0] < -3 && presence[0] > 2.5, String(format: "Voices: %.1f dB at 50 Hz, +%.1f dB at 2.8 kHz", low[0], presence[0]))
		expect(high[1] > 3 && abs(mid[1]) < 0.7, String(format: "Bright: +%.1f dB at 10 kHz, %.1f dB at 1 kHz", high[1], mid[1]))
		expect(low[2] > 2 && high[2] < -2, String(format: "Warm: +%.1f dB at 50 Hz, %.1f dB at 10 kHz", low[2], high[2]))
		expect(low[3] < -3.5 && abs(mid[3]) < 0.5, String(format: "Night trims bass by %.1f dB at 50 Hz and leaves 1 kHz alone (%.1f dB)", low[3], mid[3]))
		expect(mid[4] > 4 && mid[4] < 6 && low[4] > -0.1 && low[4] < 1 && high[4] > -0.1 && high[4] < 1.5, String(format: "Voice boost: +%.1f dB on centred 1 kHz, %.1f dB at 50 Hz, %.1f dB at 10 kHz", mid[4], low[4], high[4]))
		expect(abs(mid[5]) < 0.05, String(format: "Voice boost leaves sound that is only at the sides alone (%.2f dB)", mid[5]))
	}

	line("")
	line("== Limiter ==")
	let hot = run(Signal(frequency: 10000, levelDb: 0)) { $0.tone = .bright }
	expect(hot.peakDb <= -0.95, String(format: "Full-scale 10 kHz through Bright (+4 dB) leaves at %.2f dB, limiter cut %.1f dB", hot.peakDb, hot.limiterDb))
	let stacked = run(Signal(frequency: 2800, levelDb: 0)) { $0.tone = .voices; $0.voiceBoost = true; $0.dynamics = .night }
	expect(stacked.peakDb <= -0.95, String(format: "Full-scale 2.8 kHz through Night + Voices + boost leaves at %.2f dB", stacked.peakDb))

	line("")
	line("== Switching while playing (200 Hz at -12 dB; 1.0 = as smooth as a clean sine) ==")
	let steady = run(Signal(frequency: 200, levelDb: -12), seconds: 3, measureFrom: 0.5) { _ in }
	line(String(format: "  steady, everything off: %.2f", steady.roughness))
	let changes: [(String, (AudioPipeline) -> Void, (AudioPipeline) -> Void)] = [
		("off -> night", { _ in }, { $0.dynamics = .night }),
		("night -> off", { $0.dynamics = .night }, { $0.dynamics = .off }),
		("flat -> voices", { _ in }, { $0.tone = .voices }),
		("warm -> bright", { $0.tone = .warm }, { $0.tone = .bright }),
		("voice boost on", { _ in }, { $0.voiceBoost = true }),
		("light+voices -> night+warm+boost", { $0.dynamics = .light; $0.tone = .voices }, { $0.dynamics = .night; $0.tone = .warm; $0.voiceBoost = true }),
	]
	for (name, before, after) in changes {
		let m = run(Signal(frequency: 200, levelDb: -12), seconds: 3, measureFrom: 0.5, setup: before, switchAt: 1.5, change: after)
		expect(m.roughness < 3, String(format: "%@: %.2f", name, m.roughness))
	}

	line("")
	line("== Cost ==")
	let off = run(Signal(frequency: 440, levelDb: -20), seconds: 60, measureFrom: 1) { _ in }
	let all = run(Signal(frequency: 440, levelDb: -20), seconds: 60, measureFrom: 1) { $0.dynamics = .night; $0.tone = .voices; $0.voiceBoost = true }
	let extra = max(0, all.seconds - off.seconds) / 60 * 100
	expect(extra < 1, String(format: "60 s of audio: %.0f ms with everything off, %.0f ms with Night + Voices + boost: %.2f %% of one core extra", off.seconds * 1000, all.seconds * 1000, extra))

	line("")
	line(failures.isEmpty ? "effects: all checks passed" : "effects: \(failures.count) check(s) FAILED")
	exit(failures.isEmpty ? 0 : 1)
}
