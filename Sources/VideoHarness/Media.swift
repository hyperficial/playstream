// Test media for the upscaler and frame-generation evaluations, built from a high-resolution natural
// image (the system "Sonoma" wallpaper) plus a game-style HUD drawn with CoreText at each resolution.
//
//   ps-video-harness --make-media build/video-test/media
//
// Writes raw 4:2:0 frames (.yuv) that build/video-test/media/encode.sh turns into elementary streams,
// and half-float RGBA references (.rgbah) for objective comparison.

import AppKit
import CoreImage
import CoreText
import Foundation
@_spi(Diagnostics) import PSVideo
import CoreVideo

enum MediaKind { case sdr, hdr }

struct MediaFactory {
	let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAh])
	let source: CIImage
	let altSource: CIImage

	init?() {
		let path = "/System/Library/Desktop Pictures/Sonoma.heic"
		guard let src = CIImage(contentsOf: URL(fileURLWithPath: path)) else { return nil }
		// 16:9 crop from the middle of the square wallpaper.
		let e = src.extent
		let h = e.width * 9 / 16
		source = src.cropped(to: CGRect(x: e.minX, y: e.midY - h / 2, width: e.width, height: h))
			.transformed(by: CGAffineTransform(translationX: -e.minX, y: -(e.midY - h / 2)))
		// A different picture for the scene cut.
		let altPath = "/System/Library/Desktop Pictures/iMac Orange.heic"
		let alt = CIImage(contentsOf: URL(fileURLWithPath: altPath)) ?? src.applyingFilter("CIColorInvert")
		let ae = alt.extent
		altSource = alt.cropped(to: CGRect(x: ae.minX, y: ae.midY - ae.width * 9 / 32, width: ae.width, height: ae.width * 9 / 16))
			.transformed(by: CGAffineTransform(translationX: -ae.minX, y: -(ae.midY - ae.width * 9 / 32)))
	}

	/// Lanczos-scales `img` so that `region` (in image coordinates) fills width x height.
	func scaled(_ img: CIImage, region: CGRect, width: Int, height: Int) -> CIImage {
		let s = CGFloat(width) / region.width
		let moved = img.transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
		let f = CIFilter(name: "CILanczosScaleTransform")!
		f.setValue(moved, forKey: kCIInputImageKey)
		f.setValue(s, forKey: kCIInputScaleKey)
		f.setValue(CGFloat(height) / (region.height * s), forKey: kCIInputAspectRatioKey)
		return f.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
	}

	/// Game-style HUD at width x height (layout in 1920x1080 units, scaled): health bar, ammo counter,
	/// small text, thin lines, a minimap with a moving marker, a per-frame changing timer.
	func hud(width: Int, height: Int, frame: Int) -> CGImage {
		let s = CGFloat(width) / 1920
		let cs = CGColorSpace(name: CGColorSpace.sRGB)!
		let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
		                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
		ctx.scaleBy(x: s, y: s)
		ctx.setShouldAntialias(true)
		// Health bar.
		ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
		ctx.fill(CGRect(x: 40, y: 40, width: 420, height: 34))
		ctx.setFillColor(CGColor(red: 0.2, green: 0.85, blue: 0.3, alpha: 1))
		ctx.fill(CGRect(x: 46, y: 46, width: 300, height: 22))
		// Minimap with a moving marker and thin grid lines.
		let mm = CGRect(x: 1600, y: 40, width: 280, height: 280)
		ctx.setFillColor(CGColor(red: 0.05, green: 0.08, blue: 0.1, alpha: 0.8))
		ctx.fill(mm)
		ctx.setStrokeColor(CGColor(red: 0.6, green: 0.7, blue: 0.8, alpha: 0.9))
		ctx.setLineWidth(1)
		for i in 1..<7 {
			let x = mm.minX + CGFloat(i) * 40, y = mm.minY + CGFloat(i) * 40
			ctx.strokeLineSegments(between: [CGPoint(x: x, y: mm.minY), CGPoint(x: x, y: mm.maxY), CGPoint(x: mm.minX, y: y), CGPoint(x: mm.maxX, y: y)])
		}
		let a = Double(frame) * 2 * .pi / 120
		ctx.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.1, alpha: 1))
		ctx.fillEllipse(in: CGRect(x: mm.midX + 100 * cos(a) - 6, y: mm.midY + 100 * sin(a) - 6, width: 12, height: 12))
		// Thin rotating needle (thin-object test).
		ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
		ctx.setLineWidth(2)
		ctx.strokeLineSegments(between: [CGPoint(x: 960, y: 140), CGPoint(x: 960 + 90 * cos(a * 3), y: 140 + 90 * sin(a * 3))])
		// Text: ammo counter, small labels, a timer that changes every frame.
		func text(_ str: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
			let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
			let attr = NSAttributedString(string: str, attributes: [
				.font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
			])
			ctx.textPosition = CGPoint(x: x, y: y)
			CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
		}
		text("30 / 240", 1640, 980, 54)
		text("MISSION: Reach the marina before the storm. Avoid patrols on the coast road.", 40, 1000, 22)
		text("Speed 87 mph   Wanted ** ", 40, 960, 18)
		text(String(format: "T+%05.2f", Double(frame) / 60), 1600, 340, 28)
		return ctx.makeImage()!
	}

	/// Scene (lanczos from the 6K source) + HUD, composited in sRGB, as a CIImage.
	func composite(scene: CIImage, width: Int, height: Int, frame: Int, withHUD: Bool = true) -> CIImage {
		guard withHUD else { return scene }
		let h = CIImage(cgImage: hud(width: width, height: height, frame: frame))
		return h.composited(over: scene)
	}

	/// Renders to linear BT.2020 floats (RGBA), then to the stream's encoded R'G'B':
	/// SDR: Apple's HDTV (BT.709 video) space; HDR: PQ with SDR white at 203 nits and highlights
	/// expanded towards 1000 nits.
	func encodedRGB(_ img: CIImage, width: Int, height: Int, kind: MediaKind) -> [Float] {
		var out = [Float](repeating: 0, count: width * height * 4)
		switch kind {
		case .sdr:
			var att: [CFString: Any] = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
			                            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
			                            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2]
			let space = CVImageBufferCreateColorSpaceFromAttachments(att as CFDictionary)!.takeRetainedValue()
			att.removeAll()
			out.withUnsafeMutableBytes { ci.render(img, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space) }
		case .hdr:
			out.withUnsafeMutableBytes { ci.render(img, toBitmap: $0.baseAddress!, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!) }
			for i in stride(from: 0, to: out.count, by: 4) {
				let r = max(0, out[i]), g = max(0, out[i + 1]), b = max(0, out[i + 2])
				let y = 0.2627 * r + 0.678 * g + 0.0593 * b
				let t = min(1, max(0, (y - 0.7) / 0.3))
				let boost = 1 + 3.9 * t * t * (3 - 2 * t) // up to ~1000 nits in the brightest areas
				out[i] = pq(r * 203 * boost / 10000)
				out[i + 1] = pq(g * 203 * boost / 10000)
				out[i + 2] = pq(b * 203 * boost / 10000)
			}
		}
		return out
	}

	func pq(_ l: Float) -> Float {
		let m1: Float = 0.1593017578125, m2: Float = 78.84375, c1: Float = 0.8359375, c2: Float = 18.8515625, c3: Float = 18.6875
		let y = pow(min(1, max(0, l)), m1)
		return pow((c1 + c2 * y) / (1 + c3 * y), m2)
	}

	/// R'G'B' -> limited-range Y'CbCr 4:2:0 (2x2 chroma average), 8-bit (SDR, BT.709) or 10-bit LE (HDR, BT.2020).
	func yuv420(_ rgb: [Float], width: Int, height: Int, kind: MediaKind) -> Data {
		let (kr, kb): (Float, Float) = kind == .hdr ? (0.2627, 0.0593) : (0.2126, 0.0722)
		let kg = 1 - kr - kb
		let bits: Float = kind == .hdr ? 4 : 1
		var yP = [UInt16](repeating: 0, count: width * height)
		var cb = [UInt16](repeating: 0, count: width * height / 4)
		var cr = [UInt16](repeating: 0, count: width * height / 4)
		for yy in 0..<height {
			for xx in 0..<width {
				let i = (yy * width + xx) * 4
				let r = min(1, max(0, rgb[i])), g = min(1, max(0, rgb[i + 1])), b = min(1, max(0, rgb[i + 2]))
				let Y = kr * r + kg * g + kb * b
				yP[yy * width + xx] = UInt16(((16 + 219 * Y) * bits).rounded())
			}
		}
		for yy in 0..<(height / 2) {
			for xx in 0..<(width / 2) {
				var sb: Float = 0, sr: Float = 0
				for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
					let i = ((yy * 2 + dy) * width + xx * 2 + dx) * 4
					let r = min(1, max(0, rgb[i])), g = min(1, max(0, rgb[i + 1])), b = min(1, max(0, rgb[i + 2]))
					let Y = kr * r + kg * g + kb * b
					sb += (b - Y) / (2 * (1 - kb))
					sr += (r - Y) / (2 * (1 - kr))
				}
				cb[yy * width / 2 + xx] = UInt16(((128 + 224 * sb / 4) * bits).rounded())
				cr[yy * width / 2 + xx] = UInt16(((128 + 224 * sr / 4) * bits).rounded())
			}
		}
		var d = Data()
		if kind == .hdr {
			for plane in [yP, cb, cr] { plane.withUnsafeBytes { d.append(contentsOf: $0) } }
		} else {
			for plane in [yP, cb, cr] { d.append(contentsOf: plane.map { UInt8(min(255, $0)) }) }
		}
		return d
	}

	static func writeHalf(_ rgb: [Float], to url: URL) throws {
		let h = rgb.map { Float16($0) }
		try h.withUnsafeBytes { Data($0) }.write(to: url)
	}
}

/// Builds the evaluation media. Returns false on failure.
func makeMedia(dir: String) -> Bool {
	guard let f = MediaFactory() else {
		print("cannot load the wallpaper images")
		return false
	}
	let url = URL(fileURLWithPath: dir)
	try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	let full = f.source.extent

	// 1. Upscaling: one still at 1920x1080 and its 3456x1944 reference, both with a natively drawn HUD.
	for kind in [MediaKind.sdr, .hdr] {
		let name = kind == .sdr ? "sdr" : "hdr"
		let lo = f.composite(scene: f.scaled(f.source, region: full, width: 1920, height: 1080), width: 1920, height: 1080, frame: 0)
		let hi = f.composite(scene: f.scaled(f.source, region: full, width: 3456, height: 1944), width: 3456, height: 1944, frame: 0)
		let loRGB = f.encodedRGB(lo, width: 1920, height: 1080, kind: kind)
		let hiRGB = f.encodedRGB(hi, width: 3456, height: 1944, kind: kind)
		var stills = Data()
		let frame = f.yuv420(loRGB, width: 1920, height: 1080, kind: kind)
		for _ in 0..<12 { stills.append(frame) }
		try? stills.write(to: url.appendingPathComponent("still_\(name).yuv"))
		try? MediaFactory.writeHalf(hiRGB, to: url.appendingPathComponent("ref_\(name)_3456x1944.rgbah"))
		print("still \(name): 12 frames 1920x1080 + reference 3456x1944")
	}

	// 2. Frame generation: 4 s of true 60 fps game-like content. A fast camera pan (30 px per 60 fps
	//    frame = 1800 px/s) across a panorama, HUD with moving minimap marker / needle / timer, and a
	//    scene cut at frame 120. Panorama = source scaled to 3840 wide (integer-pixel pan, no resampling).
	let pano = f.scaled(f.source, region: full, width: 3840, height: 2160)
	let pano2 = f.scaled(f.altSource, region: f.altSource.extent, width: 3840, height: 2160)
	for kind in [MediaKind.sdr, .hdr] {
		let name = kind == .sdr ? "sdr" : "hdr"
		let fh = try? FileHandle(forWritingTo: { let u = url.appendingPathComponent("pan_\(name)_true60.yuv"); FileManager.default.createFile(atPath: u.path, contents: nil); return u }())
		for i in 0..<240 {
			let p = i < 120 ? pano : pano2
			let x = CGFloat(i < 120 ? i * 30 : (i - 120) * 30) // pan left to right, 30 px per frame
			let y = CGFloat(500) + 120 * CGFloat(sin(Double(i) / 25)) // a little vertical bob
			let scene = p.transformed(by: CGAffineTransform(translationX: -x, y: -y)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
			let img = f.composite(scene: scene, width: 1920, height: 1080, frame: i)
			let rgb = f.encodedRGB(img, width: 1920, height: 1080, kind: kind)
			fh?.write(f.yuv420(rgb, width: 1920, height: 1080, kind: kind))
		}
		try? fh?.close()
		print("pan \(name): 240 frames of true 60 fps content")
	}

	let script = """
	#!/bin/bash
	# Encodes the evaluation media like the PS5 stream: HEVC, 30 Mbit/s, no B-frames.
	set -euo pipefail
	cd "$(dirname "$0")"
	FF=/opt/homebrew/bin/ffmpeg
	X="bframes=0:scenecut=0:open-gop=0:repeat-headers=1:aud=0:info=0:hrd=0:slices=1:rc-lookahead=0:bitrate=30000:vbv-maxrate=30000:vbv-bufsize=1000"
	SDRC="colorprim=bt709:transfer=bt709:colormatrix=bt709"
	HDRC="colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc"
	enc() { # in fmt filter keyint colour out
		$FF -y -hide_banner -loglevel error -f rawvideo -pix_fmt $2 -s 1920x1080 -r 60 -i $1 -vf "$3" -c:v libx265 -preset ultrafast -tune zerolatency \\
			-x265-params "$X:keyint=$4:min-keyint=$4:$5" -f hevc $6
	}
	# Stills (intra only, 30 Mbit/s like a real frame budget).
	enc still_sdr.yuv yuv420p null 1 "$SDRC" still_sdr.hevc
	enc still_hdr.yuv yuv420p10le null 1 "$HDRC" still_hdr.hevc
	for k in sdr hdr; do
		if [ $k = sdr ]; then P=yuv420p; C="$SDRC"; else P=yuv420p10le; C="$HDRC"; fi
		enc pan_${k}_true60.yuv $P null 600 "$C" pan_${k}_true60.hevc
		# 30 fps game in a 60 fps stream: every second picture repeated.
		enc pan_${k}_true60.yuv $P "fps=30,fps=60" 600 "$C" pan_${k}_30in60.hevc
		# Unstable ~45 fps game: irregular repeats.
		enc pan_${k}_true60.yuv $P "fps=45,fps=60" 600 "$C" pan_${k}_45in60.hevc
	done
	# 30 fps gameplay for 2 s, then 60 fps (menu / cutscene) for 2 s.
	$FF -y -hide_banner -loglevel error -f rawvideo -pix_fmt yuv420p -s 1920x1080 -r 60 -i pan_sdr_true60.yuv \\
		-filter_complex "[0:v]split[a][b];[a]trim=end_frame=120,fps=30,fps=60,setpts=PTS-STARTPTS[x];[b]trim=start_frame=120,setpts=PTS-STARTPTS[y];[x][y]concat=n=2:v=1[o]" \\
		-map "[o]" -c:v libx265 -preset ultrafast -tune zerolatency -x265-params "$X:keyint=600:min-keyint=600:$SDRC" -f hevc pan_sdr_30then60.hevc
	ls -la *.hevc
	"""
	try? script.write(to: url.appendingPathComponent("encode.sh"), atomically: true, encoding: .utf8)
	print("wrote \(dir)/encode.sh")
	return true
}

// MARK: - Upscaling evaluation

/// Renders the last decoded frame through every upscaler at the reference size, offscreen, and compares
/// with the reference (encoded-domain RGB PSNR, whole frame and crops), checks HDR highlights, times
/// the GPU work, and writes PNG crops.
func evaluateUpscaling(refPath: String, dumpDir: String?) {
	guard let refData = FileManager.default.contents(atPath: refPath) else { print("cannot read \(refPath)"); return }
	let W = 3456, H = 1944
	let ref: [Float16] = refData.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
	guard ref.count == W * H * 4 else { print("reference size mismatch"); return }
	let hdr = pipeline.colorInfo?.isHDR ?? false
	let out = CGSize(width: W, height: H)
	struct Crop { let name: String; let rect: (x: Int, y: Int, w: Int, h: Int) }
	let crops = [Crop(name: "hud-text", rect: (40, 60, 1400, 220)), Crop(name: "minimap", rect: (2860, 1340, 540, 560)),
	             Crop(name: "landscape", rect: (1300, 700, 900, 520))]
	func psnr(_ a: [Float16], rect: (x: Int, y: Int, w: Int, h: Int)? = nil) -> Double {
		var se = 0.0, n = 0
		let r = rect ?? (0, 0, W, H)
		for y in r.y..<(r.y + r.h) {
			for x in r.x..<(r.x + r.w) {
				let i = (y * W + x) * 4
				for k in 0..<3 {
					let d = Double(min(1, max(0, a[i + k]))) - Double(min(1, max(0, ref[i + k])))
					se += d * d
					n += 1
				}
			}
		}
		return 10 * log10(1 / max(1e-12, se / Double(n)))
	}
	/// Mean luma gradient magnitude of `a` relative to the reference in a crop (1.0 = as sharp as the reference).
	func edgeRatio(_ a: [Float16], _ r: (x: Int, y: Int, w: Int, h: Int)) -> Double {
		func energy(_ b: [Float16]) -> Double {
			var e = 0.0
			for y in r.y..<(r.y + r.h - 1) {
				for x in r.x..<(r.x + r.w - 1) {
					let i = (y * W + x) * 4
					func l(_ j: Int) -> Double { Double(b[j]) * 0.3 + Double(b[j + 1]) * 0.6 + Double(b[j + 2]) * 0.1 }
					e += abs(l(i + 4) - l(i)) + abs(l(i + W * 4) - l(i))
				}
			}
			return e
		}
		return energy(a) / max(1e-9, energy(ref))
	}
	// HDR: pixels the reference shows above SDR white (PQ 0.58 ~ 203 nits).
	var mask: [Int] = []
	if hdr {
		for i in stride(from: 0, to: ref.count, by: 4) where max(ref[i], ref[i + 1], ref[i + 2]) > 0.60 { mask.append(i) }
	}
	func highlight(_ a: [Float16]) -> String {
		guard !mask.isEmpty else { return "" }
		var sa = 0.0, sr = 0.0, above = 0
		var peakA: Float16 = 0, peakR: Float16 = 0
		for i in mask {
			let ma = max(a[i], a[i + 1], a[i + 2]), mr = max(ref[i], ref[i + 1], ref[i + 2])
			sa += Double(ma); sr += Double(mr)
			if ma > 0.60 { above += 1 }
			peakA = max(peakA, ma); peakR = max(peakR, mr)
		}
		return String(format: "; HDR highlights: %d ref px above SDR white, %.1f%% still above, mean PQ %.4f vs ref %.4f, peak %.4f vs %.4f",
		              mask.count, Double(above) * 100 / Double(mask.count), sa / Double(mask.count), sr / Double(mask.count), Double(peakA), Double(peakR))
	}
	var variants: [(String, VideoUpscaler, Bool?)] = [("off (bilinear, = compositor)", .off, nil), ("bicubic", .bicubic, nil), ("metalFXSpatial", .metalFXSpatial, false)]
	if hdr { variants.append(("metalFXSpatial (linear-light HDR mode)", .metalFXSpatial, true)) }
	log("upscaling 1920x1080 -> \(W)x\(H), \(hdr ? "HDR (PQ)" : "SDR"), reference = lanczos from the 6K source:")
	for (name, mode, linear) in variants {
		guard let first = pipeline.renderLastFrameOffscreen(upscaler: mode, outputSize: out, hdrDomainLinear: linear) else { log("  \(name): render failed"); continue }
		// GPU time: warm, no read-back.
		var t: [Double] = []
		for _ in 0..<40 { if let r = pipeline.renderLastFrameOffscreen(upscaler: mode, outputSize: out, hdrDomainLinear: linear, readBack: false) { t.append(r.gpuMs) } }
		t.sort()
		let cropText = crops.map { String(format: "%@ %.2f", $0.name, psnr(first.rgba, rect: $0.rect)) }.joined(separator: ", ")
			+ String(format: "; edge energy vs ref: text %.2f, landscape %.2f", edgeRatio(first.rgba, crops[0].rect), edgeRatio(first.rgba, crops[2].rect))
		log(String(format: "  %@ [ran %@]: PSNR %.2f dB (%@); GPU %.2f ms median, %.2f p95%@", name, first.mode.rawValue, psnr(first.rgba), cropText,
		           t[t.count / 2], t[min(t.count - 1, Int(Double(t.count) * 0.95))], highlight(first.rgba)))
		if let dir = dumpDir {
			let tag = name.split(separator: " ").first.map(String.init)! + (linear == true ? "-linear" : "")
			dumpCrops(first.rgba, width: W, height: H, hdr: hdr, crops: crops.map { ($0.name, $0.rect) }, prefix: "\(dir)/\(hdr ? "hdr" : "sdr")_\(tag)")
		}
	}
	if let dir = dumpDir { dumpCrops(ref, width: W, height: H, hdr: hdr, crops: crops.map { ($0.name, $0.rect) }, prefix: "\(dir)/\(hdr ? "hdr" : "sdr")_reference") }
}

/// Writes sRGB PNG crops (HDR is shown through CoreImage's PQ -> sRGB conversion; highlights clip).
func dumpCrops(_ rgba: [Float16], width: Int, height: Int, hdr: Bool, crops: [(String, (x: Int, y: Int, w: Int, h: Int))], prefix: String) {
	let space: CGColorSpace = hdr ? CGColorSpace(name: CGColorSpace.itur_2100_PQ)! : {
		let att: [CFString: Any] = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
		                            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
		                            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2]
		return CVImageBufferCreateColorSpaceFromAttachments(att as CFDictionary)!.takeRetainedValue()
	}()
	let data = rgba.withUnsafeBytes { Data($0) }
	let img = CIImage(bitmapData: data, bytesPerRow: width * 8, size: CGSize(width: width, height: height), format: .RGBAh, colorSpace: space)
	let ctx = CIContext()
	for (name, r) in crops {
		// CIImage rows start at the bottom; crops are given top-down.
		let rect = CGRect(x: r.x, y: height - r.y - r.h, width: r.w, height: r.h)
		let u = URL(fileURLWithPath: "\(prefix)_\(name).png")
		try? ctx.writePNGRepresentation(of: img.cropped(to: rect), to: u, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
	}
}
