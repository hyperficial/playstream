import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Picture-to-picture analysis of decoded pictures: is this a new picture or a repeat of the previous
/// one, and the luma histogram (cut detection). Block-based, so a small moving object counts as new
/// (a global changed-pixel fraction misses it) while encoder refinement of a still picture (small
/// differences spread over the picture) does not.
struct ContentAnalysis {
	/// Fraction of 1/4-resolution luma samples that changed by more than `fg.repeatChangedLevel` codes.
	var changedFraction: Float = 1
	/// Largest mean |dY| over a 32x32 block, 8-bit codes.
	var maxBlockMean: Float = 255
	/// Blocks whose mean |dY| exceeds `content.blockLevel`.
	var changedBlocks: Int = 0
	/// Normalised 32-bin luma histogram.
	var hist: [Float] = []
	var isRepeat = false
	var hasPrevious = false
	/// Blocks above 1, 2, 3, 4, 6, 8, 12, 16 codes (diagnostics).
	var blockCounts: [Int] = []
}

final class ContentAnalyzer {
	private let device: MTLDevice
	private let queue: MTLCommandQueue
	private let pso: MTLComputePipelineState
	private var cache: CVMetalTextureCache
	private let out: MTLBuffer
	static let outCount = 48
	static let levels: [Float] = [1, 2, 3, 4, 6, 8, 12, 16]
	private let dump: FileHandle? = ProcessInfo.processInfo.environment["PSV_CONTENT_DUMP"].flatMap { p in FileManager.default.createFile(atPath: p, contents: nil); return FileHandle(forWritingAtPath: p) }

	init?(device: MTLDevice) {
		var c: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c) == kCVReturnSuccess, let c,
		      let q = device.makeCommandQueue(),
		      let lib = try? device.makeLibrary(source: Self.source, options: nil),
		      let f = lib.makeFunction(name: "content_analyze"),
		      let p = try? device.makeComputePipelineState(function: f),
		      let o = device.makeBuffer(length: Self.outCount * 4, options: .storageModeShared)
		else { return nil }
		self.device = device
		queue = q
		pso = p
		cache = c
		out = o
	}

	private func luma(_ pb: CVPixelBuffer) -> CVMetalTexture? {
		let f = CVPixelBufferGetPixelFormatType(pb)
		let ten = f == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
		var t: CVMetalTexture?
		CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, ten ? .r16Unorm : .r8Unorm,
		                                          CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &t)
		return t
	}

	struct Params {
		var changeLevel: Float   // normalised luma difference counting a sample as changed
		var blockLevel: Float    // 8-bit codes: block mean |dY| counting a block as changed
		var hasPrev: Float
		var pad: Float = 0
	}

	/// Synchronous (~0.3 ms GPU at 1080p). `previous` nil: only the histogram is meaningful.
	func analyze(_ pb: CVPixelBuffer, previous: CVPixelBuffer?, t: TunableValues) -> ContentAnalysis {
		guard let cur = luma(pb), let curT = CVMetalTextureGetTexture(cur), let cmd = queue.makeCommandBuffer(),
		      let enc = cmd.makeComputeCommandEncoder() else { return ContentAnalysis() }
		let prev = previous.flatMap { luma($0) }
		let prevT = prev.flatMap { CVMetalTextureGetTexture($0) } ?? curT
		memset(out.contents(), 0, Self.outCount * 4)
		var p = Params(changeLevel: Float(t.fgRepeatChangedLevel / 255), blockLevel: Float(t.contentBlockLevel), hasPrev: prev == nil ? 0 : 1)
		enc.setComputePipelineState(pso)
		enc.setTexture(curT, index: 0)
		enc.setTexture(prevT, index: 1)
		enc.setBuffer(out, offset: 0, index: 0)
		enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 1)
		let gw = (curT.width + 3) / 4, gh = (curT.height + 3) / 4
		enc.dispatchThreads(MTLSize(width: gw, height: gh, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
		enc.endEncoding()
		cmd.commit()
		cmd.waitUntilCompleted()
		_ = (cur, prev)
		let o = out.contents().bindMemory(to: UInt32.self, capacity: Self.outCount)
		let total = Float(gw * gh)
		var a = ContentAnalysis()
		a.hasPrevious = previous != nil
		a.changedFraction = Float(o[0]) / total
		a.changedBlocks = Int(o[1])
		a.maxBlockMean = Float(o[2]) / 100
		a.hist = (0..<32).map { Float(o[4 + $0]) / total }
		a.blockCounts = (0..<8).map { Int(o[36 + $0]) }
		if let d = dump { d.write((([a.changedFraction, a.maxBlockMean].map { "\($0)" }) + a.blockCounts.map { "\($0)" }).joined(separator: ",").appending("\n").data(using: .utf8)!) }
		// New picture: enough blocks changed clearly. Encoder refinement of a still picture changes many
		// blocks a little (below the block level); a moving object changes a few blocks a lot.
		a.isRepeat = a.hasPrevious && a.changedBlocks < Int(t.contentMinBlocks)
		return a
	}

	static let source = """
	#include <metal_stdlib>
	using namespace metal;
	struct Params { float changeLevel; float blockLevel; float hasPrev; float pad; };

	// One thread per 4x4 pixel cell; an 8x8 threadgroup is one 32x32-pixel block.
	kernel void content_analyze(texture2d<float, access::read> cur [[texture(0)]],
	                            texture2d<float, access::read> prev [[texture(1)]],
	                            device atomic_uint *out [[buffer(0)]],
	                            constant Params &p [[buffer(1)]],
	                            uint2 gid [[thread_position_in_grid]],
	                            uint lid [[thread_index_in_threadgroup]]) {
		threadgroup atomic_uint blockSum;
		threadgroup atomic_uint blockN;
		if (lid == 0) { atomic_store_explicit(&blockSum, 0u, memory_order_relaxed); atomic_store_explicit(&blockN, 0u, memory_order_relaxed); }
		threadgroup_barrier(mem_flags::mem_threadgroup);
		uint w = cur.get_width(), h = cur.get_height();
		uint2 base = gid * 4;
		if (base.x < w && base.y < h) {
			float sum = 0; uint n = 0;
			for (uint y = 0; y < 4; y++) for (uint x = 0; x < 4; x++) {
				uint2 q = base + uint2(x, y);
				if (q.x < w && q.y < h) { sum += abs(cur.read(q).r - prev.read(q).r); n++; }
			}
			// sum in 8-bit codes x 16 (fixed point)
			atomic_fetch_add_explicit(&blockSum, uint(sum * 255.0 * 16.0), memory_order_relaxed);
			atomic_fetch_add_explicit(&blockN, n, memory_order_relaxed);
			uint2 s = base + 1;
			float c = cur.read(min(s, uint2(w - 1, h - 1))).r;
			if (p.hasPrev > 0.5 && abs(c - prev.read(min(s, uint2(w - 1, h - 1))).r) > p.changeLevel) atomic_fetch_add_explicit(&out[0], 1u, memory_order_relaxed);
			atomic_fetch_add_explicit(&out[4 + min(31u, uint(c * 32.0))], 1u, memory_order_relaxed);
		}
		threadgroup_barrier(mem_flags::mem_threadgroup);
		if (lid == 0 && p.hasPrev > 0.5) {
			uint n = atomic_load_explicit(&blockN, memory_order_relaxed);
			if (n > 0) {
				float mean = float(atomic_load_explicit(&blockSum, memory_order_relaxed)) / 16.0 / float(n);
				if (mean > p.blockLevel) atomic_fetch_add_explicit(&out[1], 1u, memory_order_relaxed);
				atomic_fetch_max_explicit(&out[2], uint(mean * 100.0), memory_order_relaxed);
				const float lv[8] = {1, 2, 3, 4, 6, 8, 12, 16};
				for (uint i = 0; i < 8; i++) if (mean > lv[i]) atomic_fetch_add_explicit(&out[36 + i], 1u, memory_order_relaxed);
			}
		}
	}
	"""
}

/// Content frame rate, always on (Metal path): stream pictures per second, new pictures per second,
/// the recent new/repeat pattern and runs of repeats.
final class ContentRateTracker {
	private var times: [(t: Double, new: Bool)] = []
	private var run = 0
	private(set) var pattern = ""
	/// Cumulative runs of consecutive repeats: [1, 2, 3+].
	private(set) var runs = [0, 0, 0]

	func add(isNew: Bool, at t: Double) {
		times.append((t, isNew))
		times.removeAll { t - $0.t > 2 }
		pattern.append(isNew ? "N" : "R")
		if pattern.count > 30 { pattern.removeFirst(pattern.count - 30) }
		if isNew {
			if run > 0 { runs[min(2, run - 1)] += 1 }
			run = 0
		} else {
			run += 1
		}
	}

	/// (pictures/s, new pictures/s) over the last 2 s.
	func rates(now: Double) -> (Double, Double) {
		let recent = times.filter { now - $0.t <= 2 }
		guard let first = recent.first, recent.count > 1 else { return (0, 0) }
		let span = max(0.25, now - first.t)
		return (Double(recent.count) / span, Double(recent.filter { $0.new }.count) / span)
	}
}
