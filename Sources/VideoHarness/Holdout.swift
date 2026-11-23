import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
@_spi(Diagnostics) import PSVideo
import UniformTypeIdentifiers

// Hold-out quality test on real footage (no true 60 fps reference exists):
//   extrapolation: predict unique picture U_k from (U_{k-2}, U_{k-1}) one full interval ahead
//                  (factor 1.0 = twice the live distance); "shipped" = what the live decision shows
//                  (the prediction if accepted, else the repeat), "forced" = the prediction always.
//   interpolation: U_{k-1} from (U_{k-2}, U_k) at phase 0.5 (pair spacing twice the live one).
//   baseline:      repeat of the previous unique picture.
// Luma only, 10-bit code values. Region classes by the real change at each pixel between the
// baseline and the target: static (<= 4 codes: HUD, still background), low (4-32), high (> 32).
// Stability: |G - (prev + next)/2| (second temporal difference) of the generated picture vs the
// same quantity for the real picture, on static pixels and overall (popping / flicker).

final class Plane {
	let w: Int, h: Int
	var y: [Float]          // luma, 10-bit codes
	var cb: [Float], cr: [Float] // half resolution, 10-bit codes (for crops)
	init(_ pb: CVPixelBuffer) {
		CVPixelBufferLockBaseAddress(pb, .readOnly)
		defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
		w = CVPixelBufferGetWidthOfPlane(pb, 0); h = CVPixelBufferGetHeightOfPlane(pb, 0)
		let f = CVPixelBufferGetPixelFormatType(pb)
		let ten = f == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
		y = [Float](repeating: 0, count: w * h)
		let cw = CVPixelBufferGetWidthOfPlane(pb, 1), ch = CVPixelBufferGetHeightOfPlane(pb, 1)
		cb = [Float](repeating: 512, count: cw * ch); cr = cb
		let by = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, bry = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
		let bc = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, brc = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
		for j in 0..<h {
			if ten {
				let row = (by + j * bry).assumingMemoryBound(to: UInt16.self)
				for i in 0..<w { y[j * w + i] = Float(row[i] >> 6) }
			} else {
				let row = (by + j * bry).assumingMemoryBound(to: UInt8.self)
				for i in 0..<w { y[j * w + i] = Float(row[i]) * 4 }
			}
		}
		for j in 0..<ch {
			if ten {
				let row = (bc + j * brc).assumingMemoryBound(to: UInt16.self)
				for i in 0..<cw { cb[j * cw + i] = Float(row[2 * i] >> 6); cr[j * cw + i] = Float(row[2 * i + 1] >> 6) }
			} else {
				let row = (bc + j * brc).assumingMemoryBound(to: UInt8.self)
				for i in 0..<cw { cb[j * cw + i] = Float(row[2 * i]) * 4; cr[j * cw + i] = Float(row[2 * i + 1]) * 4 }
			}
		}
	}
}

struct PairScore {
	var psnr = 0.0, psnrBase = 0.0
	var mae = [0.0, 0.0, 0.0], maeBase = [0.0, 0.0, 0.0], frac = [0.0, 0.0, 0.0]
}

func score(_ p: Plane, target t: Plane, base b: Plane) -> PairScore {
	var s = PairScore()
	var se = 0.0, seB = 0.0
	var sum = [0.0, 0.0, 0.0], sumB = [0.0, 0.0, 0.0], n = [0.0, 0.0, 0.0]
	p.y.withUnsafeBufferPointer { P in t.y.withUnsafeBufferPointer { T in b.y.withUnsafeBufferPointer { B in
		for i in 0..<P.count {
			let real = abs(T[i] - B[i])
			let c = real <= 4 ? 0 : (real <= 32 ? 1 : 2)
			let e = Double(abs(P[i] - T[i])), eb = Double(real)
			se += e * e; seB += eb * eb
			sum[c] += e; sumB[c] += eb; n[c] += 1
		}
	} } }
	let N = Double(p.y.count)
	s.psnr = 10 * log10(1023 * 1023 / max(1e-9, se / N))
	s.psnrBase = 10 * log10(1023 * 1023 / max(1e-9, seB / N))
	for c in 0..<3 {
		s.mae[c] = n[c] > 0 ? sum[c] / n[c] : .nan
		s.maeBase[c] = n[c] > 0 ? sumB[c] / n[c] : .nan
		s.frac[c] = n[c] / N
	}
	return s
}

/// Mean |m - (a + c)/2| overall and on pixels static between a and c.
func secondDifference(_ a: Plane, _ m: Plane, _ c: Plane) -> (all: Double, staticPx: Double) {
	var all = 0.0, st = 0.0, ns = 0.0
	for i in 0..<m.y.count {
		let d = Double(abs(m.y[i] - (a.y[i] + c.y[i]) / 2))
		all += d
		if abs(a.y[i] - c.y[i]) <= 4 { st += d; ns += 1 }
	}
	return (all / Double(m.y.count), ns > 0 ? st / ns : .nan)
}

/// Writes [p0 | p1 | p2 | p3] crops (cw x ch around (cx, cy)) as an 8-bit PNG (PQ R'G'B' codes, brightened x1.5 for viewing).
func writeCropStrip(_ planes: [Plane], cx: Int, cy: Int, cw: Int = 480, ch: Int = 270, to url: URL) {
	guard let p0 = planes.first else { return }
	let x0 = max(0, min(p0.w - cw, cx - cw / 2)), y0 = max(0, min(p0.h - ch, cy - ch / 2))
	let W = cw * planes.count
	var px = [UInt8](repeating: 0, count: W * ch * 4)
	for (k, p) in planes.enumerated() {
		let cwid = p.w / 2
		for j in 0..<ch {
			for i in 0..<cw {
				let X = x0 + i, Y = y0 + j
				let yv = (p.y[Y * p.w + X] - 64) / 876
				let cbv = (p.cb[(Y / 2) * cwid + X / 2] - 512) / 896, crv = (p.cr[(Y / 2) * cwid + X / 2] - 512) / 896
				// BT.2020 non-constant luminance.
				let r = yv + 1.4746 * crv, g = yv - 0.16455 * cbv - 0.57135 * crv, b = yv + 1.8814 * cbv
				let o = (j * W + k * cw + i) * 4
				px[o] = UInt8(max(0, min(255, r * 1.5 * 255))); px[o + 1] = UInt8(max(0, min(255, g * 1.5 * 255)))
				px[o + 2] = UInt8(max(0, min(255, b * 1.5 * 255))); px[o + 3] = 255
			}
		}
	}
	guard let provider = CGDataProvider(data: Data(px) as CFData),
	      let img = CGImage(width: W, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
	                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
	      let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
	CGImageDestinationAddImage(dest, img, nil)
	CGImageDestinationFinalize(dest)
}

/// Location of the 480x270 window with the most real change between b and t (coarse search).
func busiestWindow(_ b: Plane, _ t: Plane) -> (Int, Int) {
	var best = -1.0, bx = b.w / 2, by = b.h / 2
	for cy in stride(from: 135, to: b.h - 135, by: 90) {
		for cx in stride(from: 240, to: b.w - 240, by: 160) {
			var s = 0.0
			for j in stride(from: cy - 135, to: cy + 135, by: 6) { for i in stride(from: cx - 240, to: cx + 240, by: 6) { s += Double(abs(t.y[j * b.w + i] - b.y[j * b.w + i])) } }
			if s > best { best = s; bx = cx; by = cy }
		}
	}
	return (bx, by)
}

final class HoldoutRunner {
	let pipeline: VideoPipeline
	let maxPairs: Int
	let dumpDir: URL?
	let csv: URL?
	let methods: Set<String>
	private let queue = DispatchQueue(label: "holdout")
	private let lock = NSLock()
	private var pendingCount = 0
	private var lastDecoded: CVPixelBuffer?
	private var uniques: [(pb: CVPixelBuffer, plane: Plane)] = []
	private var pool: CVPixelBufferPool?
	private(set) var done = false
	var pending: Int { lock.lock(); defer { lock.unlock() }; return pendingCount }

	// Results.
	private var ex: [(shipped: PairScore, forced: PairScore, accepted: Bool, decision: String, ms: Double)] = []
	private var exStab: [(gen: Double, real: Double, genStatic: Double, realStatic: Double)] = []
	private var lastExPred: (k: Int, plane: Plane)?
	private var inp: [(s: PairScore, ms: Double)] = []
	/// Interpolator bottom edge: mean |G - T| over the last 4 rows vs the 20 rows above (codes).
	private var bottomEdge: [(last: Double, above: Double)] = []
	private var inStab: [(gen: Double, real: Double, genStatic: Double, realStatic: Double)] = []
	private var decisions: [String: Int] = [:]
	private var uniqueCount = 0, decodedCount = 0
	private var dumped = 0, dumpedWorse = 0
	private var csvLines: [String] = ["k,method,psnr,psnr_repeat,mae_static,mae_low,mae_high,mae_repeat_static,mae_repeat_low,mae_repeat_high,frac_low,frac_high,accepted,decision"]

	init(pipeline: VideoPipeline, maxPairs: Int, dumpDir: String?, csv: String?, methods: Set<String>) {
		self.pipeline = pipeline
		self.maxPairs = maxPairs
		self.dumpDir = dumpDir.map { URL(fileURLWithPath: $0) }
		self.csv = csv.map { URL(fileURLWithPath: $0) }
		self.methods = methods
		if let d = self.dumpDir { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
	}

	private func copy(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
		if pool == nil {
			let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: CVPixelBufferGetPixelFormatType(pb), kCVPixelBufferWidthKey: CVPixelBufferGetWidth(pb),
			                              kCVPixelBufferHeightKey: CVPixelBufferGetHeight(pb), kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
			                              kCVPixelBufferMetalCompatibilityKey: true]
			CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
		}
		var out: CVPixelBuffer?
		guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let o = out else { return nil }
		CVPixelBufferLockBaseAddress(pb, .readOnly); CVPixelBufferLockBaseAddress(o, [])
		for p in 0..<CVPixelBufferGetPlaneCount(pb) {
			let src = CVPixelBufferGetBaseAddressOfPlane(pb, p)!, dst = CVPixelBufferGetBaseAddressOfPlane(o, p)!
			let sb = CVPixelBufferGetBytesPerRowOfPlane(pb, p), db = CVPixelBufferGetBytesPerRowOfPlane(o, p)
			for j in 0..<CVPixelBufferGetHeightOfPlane(pb, p) { memcpy(dst + j * db, src + j * sb, min(sb, db)) }
		}
		CVPixelBufferUnlockBaseAddress(o, []); CVPixelBufferUnlockBaseAddress(pb, .readOnly)
		CVBufferPropagateAttachments(pb, o)
		return o
	}

	/// Decoder thread.
	func decoded(_ pb: CVPixelBuffer) {
		guard !done, let c = copy(pb) else { return }
		lock.lock(); pendingCount += 1; lock.unlock()
		queue.async { [self] in
			process(c)
			lock.lock(); pendingCount -= 1; lock.unlock()
		}
	}

	private func process(_ pb: CVPixelBuffer) {
		decodedCount += 1
		let prev = lastDecoded
		lastDecoded = pb
		guard let a = pipeline.contentAnalysisOffscreen(pb, previous: prev), prev == nil || !a.isRepeat else { return }
		uniqueCount += 1
		uniques.append((pb, Plane(pb)))
		if uniques.count > 4 { uniques.removeFirst() }
		let k = uniqueCount - 1
		let wantEx = methods.contains("extrapolate") && ex.count < maxPairs
		let wantIn = methods.contains("interpolate") && inp.count < maxPairs
		if !wantEx && !wantIn { done = true; return }
		guard uniques.count >= 3 else { return }
		let n = uniques.count
		let u2 = uniques[n - 3], u1 = uniques[n - 2], u0 = uniques[n - 1]   // U_{k-2}, U_{k-1}, U_k
		// Stability of the previous extrapolated picture now that U_k (its "next") exists.
		if let lp = lastExPred, lp.k == k - 1, n >= 3 {
			let g = secondDifference(u2.plane, lp.plane, u0.plane), r = secondDifference(u2.plane, u1.plane, u0.plane)
			exStab.append((g.all, r.all, g.staticPx, r.staticPx))
		}
		if methods.contains("extrapolate") {
			// Predict U_k from (U_{k-2}, U_{k-1}).
			let live = pipeline.extrapolateOffscreen(prev: u2.pb, cur: u1.pb, factor: 1.0, force: true)
			let accepted = live.decision == "ok"
			decisions[live.decision.hasPrefix("forced") ? String(live.decision.dropFirst(8).dropLast()) : live.decision, default: 0] += 1
			if let pic = live.picture {
				let pp = Plane(pic)
				let forced = score(pp, target: u0.plane, base: u1.plane)
				let shipped = accepted ? forced : score(u1.plane, target: u0.plane, base: u1.plane)
				ex.append((shipped, forced, accepted, live.decision, live.ms))
				lastExPred = (k, pp)
				csvLines.append(line(k, "extrapolate", forced, accepted, live.decision))
				dump(k, "ex", [u1.plane, pp, u0.plane], base: u1.plane, target: u0.plane, s: forced)
			}
		}
		if methods.contains("interpolate"), let r = pipeline.interpolateOffscreen(prev: u2.pb, next: u0.pb) {
			// U_{k-1} from (U_{k-2}, U_k); baseline: repeat U_{k-2}.
			let gp = Plane(r.0)
			let s = score(gp, target: u1.plane, base: u2.plane)
			var eLast = 0.0, eAbove = 0.0
			for j in (gp.h - 24)..<gp.h { for i in 0..<gp.w { let e = Double(abs(gp.y[j * gp.w + i] - u1.plane.y[j * gp.w + i])); if j >= gp.h - 4 { eLast += e } else { eAbove += e } } }
			bottomEdge.append((eLast / Double(4 * gp.w), eAbove / Double(20 * gp.w)))
			inp.append((s, r.1))
			let g = secondDifference(u2.plane, gp, u0.plane), rr = secondDifference(u2.plane, u1.plane, u0.plane)
			inStab.append((g.all, rr.all, g.staticPx, rr.staticPx))
			csvLines.append(line(k - 1, "interpolate", s, true, "ok"))
			dump(k - 1, "in", [u2.plane, gp, u1.plane, u0.plane], base: u2.plane, target: u1.plane, s: s)
		}
	}

	private func line(_ k: Int, _ m: String, _ s: PairScore, _ acc: Bool, _ d: String) -> String {
		[String(k), m, f(s.psnr), f(s.psnrBase), f(s.mae[0]), f(s.mae[1]), f(s.mae[2]), f(s.maeBase[0]), f(s.maeBase[1]), f(s.maeBase[2]),
		 f(s.frac[1]), f(s.frac[2]), acc ? "1" : "0", d.replacingOccurrences(of: ",", with: ";")].joined(separator: ",")
	}

	private func f(_ v: Double) -> String { String(format: "%.3f", v) }

	private func dump(_ k: Int, _ tag: String, _ planes: [Plane], base: Plane, target: Plane, s: PairScore) {
		guard let dir = dumpDir else { return }
		let regular = k % 40 == 0 && dumped < 12
		let worse = s.psnr < s.psnrBase - 1 && dumpedWorse < 6
		guard regular || worse else { return }
		if regular { dumped += 1 } else { dumpedWorse += 1 }
		let (cx, cy) = busiestWindow(base, target)
		let name = String(format: "%@_%04d_%@_gen%.1fdB_rep%.1fdB.png", tag, k, regular ? "sample" : "worse", s.psnr, s.psnrBase)
		writeCropStrip(planes, cx: cx, cy: cy, to: dir.appendingPathComponent(name))
	}

	func report() -> String {
		var out: [String] = ["holdout: decoded \(decodedCount), unique \(uniqueCount)"]
		func med(_ v: [Double]) -> Double { let s = v.filter { $0.isFinite }.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
		func mean(_ v: [Double]) -> Double { let s = v.filter { $0.isFinite }; return s.isEmpty ? .nan : s.reduce(0, +) / Double(s.count) }
		func block(_ name: String, _ ss: [PairScore]) {
			guard !ss.isEmpty else { return }
			let better = ss.filter { $0.psnr > $0.psnrBase }.count
			out.append(String(format: "%@ (n=%d): PSNR mean %.2f med %.2f dB vs repeat mean %.2f med %.2f; beats repeat on %d%% of pairs",
			                  name, ss.count, mean(ss.map { $0.psnr }), med(ss.map { $0.psnr }), mean(ss.map { $0.psnrBase }), med(ss.map { $0.psnrBase }), better * 100 / ss.count))
			out.append(String(format: "   mean abs error (10-bit codes) static/low/high: %.2f / %.2f / %.2f   repeat: %.2f / %.2f / %.2f   (pixel share low %.1f%% high %.1f%%)",
			                  mean(ss.map { $0.mae[0] }), mean(ss.map { $0.mae[1] }), mean(ss.map { $0.mae[2] }),
			                  mean(ss.map { $0.maeBase[0] }), mean(ss.map { $0.maeBase[1] }), mean(ss.map { $0.maeBase[2] }),
			                  mean(ss.map { $0.frac[1] }) * 100, mean(ss.map { $0.frac[2] }) * 100))
		}
		if !ex.isEmpty {
			let acc = ex.filter { $0.accepted }.count
			out.append("extrapolate: accepted by the live rule \(acc)/\(ex.count) (\(acc * 100 / ex.count)%), decisions \(decisions), ms med \(String(format: "%.2f", med(ex.map { $0.ms })))")
			block("extrapolate forced ", ex.map { $0.forced })
			block("extrapolate shipped", ex.map { $0.shipped })
			block("extrapolate accepted-only", ex.filter { $0.accepted }.map { $0.forced })
			block("extrapolate rejected-only (forced)", ex.filter { !$0.accepted }.map { $0.forced })
			if !exStab.isEmpty {
				out.append(String(format: "   stability |G-(prev+next)/2| all %.2f vs real %.2f; static px %.3f vs real %.3f", mean(exStab.map { $0.gen }), mean(exStab.map { $0.real }), mean(exStab.map { $0.genStatic }), mean(exStab.map { $0.realStatic })))
			}
		}
		if !inp.isEmpty {
			block("interpolate (8-bit LLFI)", inp.map { $0.s })
			out.append(String(format: "   bottom edge: last 4 rows error %.2f vs 20 rows above %.2f codes", mean(bottomEdge.map { $0.last }), mean(bottomEdge.map { $0.above })))
			out.append(String(format: "   ms med %.2f; stability all %.2f vs real %.2f; static px %.3f vs real %.3f", med(inp.map { $0.ms }), mean(inStab.map { $0.gen }), mean(inStab.map { $0.real }), mean(inStab.map { $0.genStatic }), mean(inStab.map { $0.realStatic })))
		}
		if let csv { try? csvLines.joined(separator: "\n").write(to: csv, atomically: true, encoding: .utf8) }
		return out.joined(separator: "\n")
	}
}
