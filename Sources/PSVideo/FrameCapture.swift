import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

/// Captures pictures exactly as handed to the display (after upscaling, real and generated) without
/// stalling presentation: the drawable is copied by a blit encoded into its own command buffer into one
/// of a few staging buffers; if none is free the capture frame is skipped (the display frame never is).
/// Files are written on a utility queue.
///
/// Format: PNG. HDR drawables (rgba16Float, PQ-encoded BT.2020) -> 16-bit RGBA PNG whose code values are
/// the PQ signal x 65535, tagged with the ITU-R BT.2100 PQ colour space (Preview / ImageIO open it, the
/// 10-bit source precision is preserved). SDR drawables (bgra8Unorm, BT.709 video R'G'B') -> 8-bit PNG
/// tagged with the layer's colour space. `index.json` lists every file with its metadata.
final class PresentedFrameCapture: @unchecked Sendable {
	struct Entry: Codable {
		var file: String
		var sequence: Int
		var kind: String          // real | generated | fallback_repeat
		var traceID: Int
		var width: Int
		var height: Int
		var encoding: String
		var presentAt: Double?
		var committed: Double
	}

	private let lock = UnfairLock()
	private var remaining = 0
	private var directory: URL?
	private var completion: (@Sendable ([URL]) -> Void)?
	private var written: [URL] = []
	private var entries: [Entry] = []
	private var inFlight = 0
	private var sequence = 0
	private var skipped = 0
	/// Staging copies waiting to be written (one per picture, ~54 MB each for an HDR 3456x1944 drawable).
	/// Consecutive pictures up to this many are captured; beyond it capture frames are skipped.
	private let maxInFlight = 12
	private let queue = DispatchQueue(label: "PSVideo.capture", qos: .utility)
	private var colorSpace: CGColorSpace?

	var active: Bool { lock.withLock { remaining > 0 } }

	func start(count: Int, directory: URL, completion: @escaping @Sendable ([URL]) -> Void) {
		try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		lock.withLock {
			self.remaining = max(0, count)
			self.directory = directory
			self.completion = completion
			self.written = []
			self.entries = []
			self.sequence = 0
			self.skipped = 0
		}
		if count <= 0 { finishIfDone(force: true) }
	}

	/// Called on the render queue while encoding a frame. Encodes the copy into `cmd` (after rendering,
	/// before present) if a staging slot is free.
	func encodeCopy(device: MTLDevice, cmd: MTLCommandBuffer, texture: MTLTexture, kind: String, traceID: Int,
	                presentAt: Double?, colorSpace: CGColorSpace?) {
		let claim: Int? = lock.withLock {
			guard remaining > 0, inFlight < maxInFlight, !texture.isFramebufferOnly else {
				if remaining > 0 { skipped += 1 }
				return nil
			}
			remaining -= 1
			inFlight += 1
			sequence += 1
			return sequence
		}
		guard let seq = claim else { return }
		let bpp = texture.pixelFormat == .rgba16Float ? 8 : 4
		let w = texture.width, h = texture.height, bpr = w * bpp
		guard let buf = device.makeBuffer(length: bpr * h, options: .storageModeShared), let blit = cmd.makeBlitCommandEncoder() else {
			lock.withLock { inFlight -= 1 }
			return
		}
		blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
		          sourceSize: MTLSize(width: w, height: h, depth: 1), to: buf, destinationOffset: 0,
		          destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * h)
		blit.endEncoding()
		let hdr = bpp == 8
		let committed = CACurrentMediaTime()
		let space = colorSpace
		cmd.addCompletedHandler { [weak self] _ in
			self?.queue.async { self?.write(buf: buf, w: w, h: h, hdr: hdr, seq: seq, kind: kind, traceID: traceID, presentAt: presentAt, committed: committed, space: space) }
		}
	}

	private func write(buf: MTLBuffer, w: Int, h: Int, hdr: Bool, seq: Int, kind: String, traceID: Int, presentAt: Double?, committed: Double, space: CGColorSpace?) {
		defer {
			lock.withLock { inFlight -= 1 }
			finishIfDone(force: false)
		}
		guard let dir = lock.withLock({ directory }) else { return }
		let url = dir.appendingPathComponent(String(format: "frame_%04d_%@.png", seq, kind))
		var image: CGImage?
		if hdr {
			// Half-float RGBA (PQ code values in 0...1) -> 16-bit RGBA.
			let n = w * h * 4
			let src = buf.contents().bindMemory(to: Float16.self, capacity: n)
			var dst = [UInt16](repeating: 0, count: n)
			for i in 0..<n { dst[i] = UInt16(max(0, min(1, Float(src[i]))) * 65535 + 0.5) }
			let data = dst.withUnsafeBytes { Data($0) }
			if let provider = CGDataProvider(data: data as CFData) {
				image = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
				                space: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!,
				                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
				                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
			}
		} else {
			let data = Data(bytes: buf.contents(), count: w * h * 4)
			if let provider = CGDataProvider(data: data as CFData) {
				image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
				                space: space ?? CGColorSpace(name: CGColorSpace.itur_709)!,
				                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
				                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
			}
		}
		guard let img = image, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
		CGImageDestinationAddImage(dest, img, nil)
		guard CGImageDestinationFinalize(dest) else { return }
		let e = Entry(file: url.lastPathComponent, sequence: seq, kind: kind, traceID: traceID, width: w, height: h,
		              encoding: hdr ? "16-bit RGBA PNG, BT.2020 PQ code values x 65535 (ITU-R BT.2100 PQ)" : "8-bit PNG, BT.709 video R'G'B' (layer colour space)",
		              presentAt: presentAt, committed: committed)
		lock.withLock {
			written.append(url)
			entries.append(e)
		}
	}

	/// Layer path (no drawables): writes a decoded / displayed pixel buffer through CoreImage.
	func captureBuffer(_ pb: CVPixelBuffer, kind: String, hdr: Bool) {
		let claim: Int? = lock.withLock {
			guard remaining > 0, inFlight < maxInFlight else { return nil }
			remaining -= 1
			inFlight += 1
			sequence += 1
			return sequence
		}
		guard let seq = claim else { return }
		queue.async { [weak self] in
			guard let self else { return }
			defer {
				self.lock.withLock { self.inFlight -= 1 }
				self.finishIfDone(force: false)
			}
			guard let dir = self.lock.withLock({ self.directory }) else { return }
			let url = dir.appendingPathComponent(String(format: "frame_%04d_%@.png", seq, kind))
			let ci = CIContext()
			let img = CIImage(cvPixelBuffer: pb)
			let space = hdr ? CGColorSpace(name: CGColorSpace.itur_2100_PQ)! : CGColorSpace(name: CGColorSpace.itur_709)!
			try? ci.writePNGRepresentation(of: img, to: url, format: hdr ? .RGBA16 : .RGBA8, colorSpace: space)
			let e = Entry(file: url.lastPathComponent, sequence: seq, kind: kind, traceID: 0, width: CVPixelBufferGetWidth(pb),
			              height: CVPixelBufferGetHeight(pb), encoding: hdr ? "16-bit PNG, PQ (layer path: decoded picture before the layer's scaling)" : "8-bit PNG (layer path: decoded picture)",
			              presentAt: nil, committed: CACurrentMediaTime())
			self.lock.withLock {
				self.written.append(url)
				self.entries.append(e)
			}
		}
	}

	private func finishIfDone(force: Bool) {
		let done: (([URL]) -> Void, [URL], [Entry], URL?, Int)? = lock.withLock {
			guard let c = completion, force || (remaining == 0 && inFlight == 0) else { return nil }
			completion = nil
			remaining = 0
			return (c, written, entries, directory, skipped)
		}
		guard let (c, urls, entries, dir, skippedCount) = done else { return }
		if let dir {
			let index: [String: Any] = ["frames": entries.sorted { $0.sequence < $1.sequence }.map { e -> [String: Any] in
				var d: [String: Any] = ["file": e.file, "sequence": e.sequence, "kind": e.kind, "traceID": e.traceID,
				                        "width": e.width, "height": e.height, "encoding": e.encoding, "committed": e.committed]
				if let p = e.presentAt { d["presentAt"] = p }
				return d
			}, "skipped_capture_frames": skippedCount]
			if let data = try? JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys]) {
				try? data.write(to: dir.appendingPathComponent("index.json"))
			}
		}
		c(urls.sorted { $0.lastPathComponent < $1.lastPathComponent })
	}
}
