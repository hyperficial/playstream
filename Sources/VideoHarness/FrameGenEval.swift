// Frame-generation evaluations (headless).
//
// --detect-eval truth.txt : decode a stream and compare frame generation's repeat detector with the
//                           ground truth (one 0/1 per frame, 1 = repeated picture).
// --fg-eval               : decode TRUE 60 fps content; interpolate frames k and k+2 (30 fps spacing,
//                           the 30 -> 60 case) and compare with the real frame k+1, against the
//                           "repeat" (what 30 fps shows today) and "blend" baselines.

import AppKit
import CoreImage
import CoreVideo
import Foundation
@_spi(Diagnostics) import PSVideo

final class DetectEval {
	let truth: [Bool]
	private var prev: CVPixelBuffer?
	private var i = 0
	var changedRepeat: [Float] = []
	var changedNew: [Float] = []
	var hist: [[Float]] = []

	init(truthPath: String) {
		truth = (try? String(contentsOfFile: truthPath, encoding: .utf8))?.split(separator: "\n").map { $0 == "1" } ?? []
	}

	func frame(_ pb: CVPixelBuffer) {
		defer { prev = pb; i += 1 }
		guard i < truth.count, let prev, let a = pipeline.analyzeOffscreen(pb, previous: prev) else { return }
		if truth[i] { changedRepeat.append(a.changed) } else { changedNew.append(a.changed) }
	}

	func report() {
		guard !changedRepeat.isEmpty || !changedNew.isEmpty else { log("detect-eval: no frames"); return }
		let r = changedRepeat.sorted(), n = changedNew.sorted()
		let thr: Float = 0.004
		let fp = n.filter { $0 < thr }.count, fn = r.filter { $0 >= thr }.count
		log(String(format: "repeat detector (changed-pixel fraction, threshold %.3f): truth repeats n=%d max %.5f p99 %.5f; truth new n=%d min %.4f p1 %.4f median %.3f; misclassified: %d new-as-repeat, %d repeat-as-new",
		           thr, r.count, r.last ?? 0, r.isEmpty ? 0 : r[Int(Double(r.count - 1) * 0.99)], n.count, n.first ?? 0, n.isEmpty ? 0 : n[Int(Double(n.count - 1) * 0.01)], n.isEmpty ? 0 : n[n.count / 2], fp, fn))
	}
}

final class InterpEval {
	private var frames: [CVPixelBuffer] = []
	private var idx = -1
	private var results: [(k: Int, gen: Double, rep: Double, blend: Double, genHUD: Double, repHUD: Double, genPan: Double, repPan: Double, ms: Double)] = []
	private var cutReport = ""
	private let dump: String?
	private var dumped = Set<Int>()
	private var maxHistNormal: Float = 0
	private var halfStats: [(psnr: Double, ms: Double, sharpHalf: Double, sharpFull: Double)] = []

	init(dumpDir: String?) { dump = dumpDir }

	func frame(_ pb: CVPixelBuffer) {
		idx += 1
		frames.append(pb)
		if frames.count > 3 { frames.removeFirst() }
		// Evaluate pairs (k-2, k) with truth k-1, k even, every 4th pair to keep up.
		guard idx >= 2, idx % 2 == 0, idx % 8 == 0 || idx == 120 || idx == 122, frames.count == 3 else { return }
		let a = frames[0], truth = frames[1], b = frames[2]
		guard let (gen, ms) = pipeline.interpolateOffscreen(prev: a, next: b),
		      let rg = pipeline.renderOffscreen(pixelBuffer: gen), let rt = pipeline.renderOffscreen(pixelBuffer: truth),
		      let ra = pipeline.renderOffscreen(pixelBuffer: a), let rb = pipeline.renderOffscreen(pixelBuffer: b)
		else { return }
		let W = rt.width
		func psnr(_ x: [Float16], _ y: [Float16], _ r: (Int, Int, Int, Int)? = nil, blendWith z: [Float16]? = nil) -> Double {
			let (x0, y0, w, h) = r ?? (0, 0, W, rt.height)
			var se = 0.0, n = 0
			for yy in y0..<(y0 + h) {
				for xx in x0..<(x0 + w) {
					let i = (yy * W + xx) * 4
					for c in 0..<3 {
						var v = Double(x[i + c])
						if let z { v = (v + Double(z[i + c])) / 2 }
						let d = v - Double(y[i + c])
						se += d * d
						n += 1
					}
				}
			}
			return 10 * log10(1 / max(1e-12, se / Double(n)))
		}
		// Reduced-resolution interpolation (960x540), scaled back: quality and sharpness vs full res.
		if let (half, hms) = pipeline.interpolateScaledOffscreen(prev: a, next: b, width: 960, height: 540),
		   let rh = pipeline.renderOffscreen(pixelBuffer: half) {
			func edge(_ x: [Float16]) -> Double {
				var e = 0.0
				for yy in stride(from: 200, to: 900, by: 2) {
					for xx in stride(from: 200, to: 1700, by: 2) {
						let i = (yy * W + xx) * 4
						e += abs(Double(x[i + 4]) - Double(x[i])) + abs(Double(x[i + W * 4]) - Double(x[i]))
					}
				}
				return e
			}
			halfStats.append((psnr(rh.rgba, rt.rgba), hms, edge(rh.rgba) / max(1e-9, edge(rt.rgba)), edge(rg.rgba) / max(1e-9, edge(rt.rgba))))
		}
		let hud = (1580, 0, 340, 400)   // minimap with moving marker + timer (top-right)
		let pan = (300, 300, 1200, 500) // panning background
		let k = idx - 2
		if idx == 120 || idx == 122 {
			let hd = pipeline.analyzeOffscreen(b, previous: a).map { "changed \(String(format: "%.2f", $0.changed))" } ?? ""
			cutReport += String(format: " pair %d->%d: generated %.2f dB vs truth, repeat %.2f dB (%@);", k, idx, psnr(rg.rgba, rt.rgba), psnr(ra.rgba, rt.rgba), hd)
		} else {
			results.append((k, psnr(rg.rgba, rt.rgba), psnr(ra.rgba, rt.rgba), psnr(ra.rgba, rt.rgba, blendWith: rb.rgba),
			                psnr(rg.rgba, rt.rgba, hud), psnr(ra.rgba, rt.rgba, hud), psnr(rg.rgba, rt.rgba, pan), psnr(ra.rgba, rt.rgba, pan), ms))
		}
		if let ha = pipeline.analyzeOffscreen(a, previous: nil)?.hist, let hb = pipeline.analyzeOffscreen(b, previous: nil)?.hist {
			let d = zip(ha, hb).map { abs($0 - $1) }.reduce(0, +)
			if idx == 120 { cutReport += String(format: " histogram distance at the cut %.2f (threshold 0.5);", d) } else { maxHistNormal = max(maxHistNormal, d) }
		}
		if let dir = dump, [38, 118, 158].contains(k), !dumped.contains(k) {
			dumped.insert(k)
			let hdr = pipeline.colorInfo?.isHDR ?? false
			let tag = hdr ? "hdr" : "sdr"
			let crops: [(String, (x: Int, y: Int, w: Int, h: Int))] = [("hud", (1500, 0, 420, 420)), ("pan", (500, 380, 640, 360)), ("text", (0, 20, 900, 120))]
			dumpCrops(rg.rgba, width: W, height: rt.height, hdr: hdr, crops: crops, prefix: "\(dir)/fg_\(tag)_k\(k)_generated")
			dumpCrops(rt.rgba, width: W, height: rt.height, hdr: hdr, crops: crops, prefix: "\(dir)/fg_\(tag)_k\(k)_truth")
			dumpCrops(ra.rgba, width: W, height: rt.height, hdr: hdr, crops: crops, prefix: "\(dir)/fg_\(tag)_k\(k)_repeat")
		}
	}

	func report() {
		guard !results.isEmpty else { log("fg-eval: no pairs evaluated"); return }
		func avg(_ f: ((k: Int, gen: Double, rep: Double, blend: Double, genHUD: Double, repHUD: Double, genPan: Double, repPan: Double, ms: Double)) -> Double) -> Double {
			results.map(f).reduce(0, +) / Double(results.count)
		}
		let ms = results.map { $0.ms }.sorted()
		log(String(format: "interpolation at 30 fps spacing (pan 60 px/frame), %d pairs, vs the true in-between frame:", results.count))
		log(String(format: "  whole frame: generated %.2f dB | repeat (30 fps today) %.2f dB | 50/50 blend %.2f dB", avg { $0.gen }, avg { $0.rep }, avg { $0.blend }))
		log(String(format: "  minimap/timer HUD over motion: generated %.2f dB | repeat %.2f dB", avg { $0.genHUD }, avg { $0.repHUD }))
		log(String(format: "  panning background: generated %.2f dB | repeat %.2f dB", avg { $0.genPan }, avg { $0.repPan }))
		log(String(format: "  worst pair: generated %.2f dB (k=%d)", results.map { $0.gen }.min()!, results.min { $0.gen < $1.gen }!.k))
		log(String(format: "  interpolation time incl. 8-bit conversion: median %.2f ms, max %.2f ms", ms[ms.count / 2], ms.last!))
		if !halfStats.isEmpty {
			let n = Double(halfStats.count)
			let t = halfStats.map { $0.ms }.sorted()
			log(String(format: "  960x540 interpolation (scaled back): %.2f dB vs truth (full res above), %.2f ms median; sharpness vs the real frame: half-res %.2f, full-res %.2f",
			           halfStats.map { $0.psnr }.reduce(0, +) / n, t[t.count / 2], halfStats.map { $0.sharpHalf }.reduce(0, +) / n, halfStats.map { $0.sharpFull }.reduce(0, +) / n))
		}
		if !cutReport.isEmpty { log("  scene cut:" + cutReport + String(format: " largest histogram distance between normal pan pairs %.2f", maxHistNormal)) }
	}
}

// MARK: - End-to-end frame generation analysis

final class DisplayLog {
	private let lock = NSLock()
	private(set) var events: [(kind: Int, target: Double, index: Int)] = []
	func add(_ k: Int, _ t: Double, _ i: Int) { lock.lock(); events.append((k, t, i)); lock.unlock() }
	func snapshot() -> [(kind: Int, target: Double, index: Int)] { lock.lock(); defer { lock.unlock() }; return events }
}

/// Cadence of everything frame generation handed to the display, on the vsync grid, per phase, and
/// whether each slot shows new content (real or generated) or a repeat.
func summarizeGeneration(_ log_: DisplayLog, truth: [Bool], phases: [(String, Int, Int)]) {
	let ev = log_.snapshot()
	guard ev.count > 10 else { log("frame generation: no display events (pacing on, metal mode, --frame-gen?)"); return }
	let refresh = 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 120)
	for (name, from, to) in phases {
		let sel = ev.filter { $0.index >= from && $0.index < to }
		guard sel.count > 3 else { continue }
		var hist = [Int](repeating: 0, count: 8)
		var n = 0, outOfOrder = 0
		var prevSlot: Int?
		var lastT = -Double.infinity
		for e in sel {
			if e.target < lastT { outOfOrder += 1 }
			lastT = e.target
			let slot = Int((e.target / refresh).rounded())
			if let p = prevSlot { hist[min(7, max(0, slot - p))] += 1; n += 1 }
			prevSlot = slot
		}
		let real = sel.filter { $0.kind == 0 }, gen = sel.filter { $0.kind == 1 }, fb = sel.filter { $0.kind == 2 }
		// Slots showing a repeated picture: fallbacks, plus real emissions of truth-repeat frames.
		let repeatsShown = fb.count + real.filter { $0.index - 1 < truth.count && $0.index >= 1 && truth[$0.index - 1] }.count
		let histText = (0...7).filter { hist[$0] > 0 }.map { "\($0 == 7 ? "7+" : "\($0)"):\(String(format: "%.1f%%", Double(hist[$0]) * 100 / Double(max(1, n))))" }.joined(separator: " ")
		log(String(format: "  %@: %d pictures shown (real %d, generated %d, fallback repeats %d); repeated pictures on screen %d (%.1f%%); refreshes per picture { %@ }%@",
		           name, sel.count, real.count, gen.count, fb.count, repeatsShown, Double(repeatsShown) * 100 / Double(sel.count), histText, outOfOrder > 0 ? " OUT OF ORDER \(outOfOrder)" : ""))
	}
}
