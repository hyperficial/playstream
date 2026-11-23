import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Zero-delay frame generation by extrapolation: estimates motion between the previous real picture
/// and the current one (GPU block matching on a 1/8 -> 1/4 resolution luma pyramid), then warps the
/// current picture forward by a fraction of that motion at full resolution and full bit depth.
///
/// Failure handling:
/// - static-overlay guard: pixels identical (3x3) in the previous and current picture are copied
///   untouched (HUD, minimap, subtitles);
/// - low-confidence blocks (motion does not explain the change) are not moved;
/// - disocclusion: the warp samples the current picture (backward warp), so holes fill from it;
/// - the caller skips prediction across cuts / losses and when the motion field changed a lot between
///   the last two intervals (`fieldChange`), which is where extrapolation overshoots.
final class MotionExtrapolator {
	struct Motion {
		/// Mean |vector| in full-resolution pixels per interval.
		var meanMotion: Float
		/// Mean |vector - previous interval's vector| (pixels): how much the motion changed.
		var fieldChange: Float
		/// Motion-compensated residual / uncompensated difference (0 = motion explains everything, 1 = nothing).
		var residualRatio: Float
		/// The previous field is valid for `fieldChange`.
		var hasPreviousField: Bool
		var ms: Double
	}

	private let device: MTLDevice
	private let queue: MTLCommandQueue
	private var cache: CVMetalTextureCache
	private let downsample4: MTLComputePipelineState
	private let downsample2: MTLComputePipelineState
	private let coarse: MTLComputePipelineState
	private let refine: MTLComputePipelineState
	private let median: MTLComputePipelineState
	private let fill: MTLComputePipelineState
	private let warpY16: MTLRenderPipelineState, warpC16: MTLRenderPipelineState
	private let warpY8: MTLRenderPipelineState, warpC8: MTLRenderPipelineState

	// Pyramids: index 0 = 1/4 resolution, 1 = 1/8.
	private struct Pyramid { var q4: MTLTexture; var q8: MTLTexture; var q16: MTLTexture; weak var owner: CVPixelBuffer? }
	private var lastPyramid: (id: ObjectIdentifier, pyr: Pyramid)?
	private var fineSize = (0, 0)
	private var coarseBuf: MTLBuffer?
	private var midBuf: MTLBuffer?
	private var fineBuf: MTLBuffer?
	private var prevFineBuf: MTLBuffer?   // last interval's filtered field (full-res px)
	private var filteredBuf: MTLBuffer?   // this interval's filtered field
	private var motionTex: MTLTexture?
	private var statsBuf: MTLBuffer?
	private var hasPrevField = false
	private var pool: CVPixelBufferPool?
	private var poolKey = (0, 0, OSType(0))

	/// Live-adjustable internals (search ranges, confidence and overlay thresholds).
	var tunables = Tunables()

	/// GPU time of the last estimate / warp (excluding queueing), ms.
	private(set) var lastGPUms = 0.0
	private(set) var lastWarpGPUms = 0.0
	static let block = 8         // block size at each pyramid level
	static let fullBlock = 32    // fine block size in full-resolution pixels

	init?(device: MTLDevice) {
		self.device = device
		guard let q = device.makeCommandQueue() else { return nil }
		queue = q
		var c: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &c) == kCVReturnSuccess, let c else { return nil }
		cache = c
		guard let lib = try? device.makeLibrary(source: Self.shaders, options: nil) else { return nil }
		func cp(_ n: String) -> MTLComputePipelineState? { lib.makeFunction(name: n).flatMap { try? device.makeComputePipelineState(function: $0) } }
		func rp(_ n: String, _ f: MTLPixelFormat) -> MTLRenderPipelineState? {
			let d = MTLRenderPipelineDescriptor()
			d.vertexFunction = lib.makeFunction(name: "mx_vertex")
			d.fragmentFunction = lib.makeFunction(name: n)
			d.colorAttachments[0].pixelFormat = f
			return try? device.makeRenderPipelineState(descriptor: d)
		}
		guard let d4 = cp("mx_down4"), let d2 = cp("mx_down2"), let co = cp("mx_coarse"), let re = cp("mx_refine"), let me = cp("mx_median"), let fi = cp("mx_fill"),
		      let y16 = rp("mx_warp_y", .r16Unorm), let c16 = rp("mx_warp_c", .rg16Unorm),
		      let y8 = rp("mx_warp_y", .r8Unorm), let c8 = rp("mx_warp_c", .rg8Unorm)
		else { return nil }
		downsample4 = d4; downsample2 = d2; coarse = co; refine = re; median = me; fill = fi
		warpY16 = y16; warpC16 = c16; warpY8 = y8; warpC8 = c8
	}

	private static func tenBit(_ pb: CVPixelBuffer) -> Bool {
		let f = CVPixelBufferGetPixelFormatType(pb)
		return f == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || f == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
	}

	private func planeTexture(_ pb: CVPixelBuffer, _ plane: Int) -> CVMetalTexture? {
		let ten = Self.tenBit(pb)
		let fmt: MTLPixelFormat = plane == 0 ? (ten ? .r16Unorm : .r8Unorm) : (ten ? .rg16Unorm : .rg8Unorm)
		var t: CVMetalTexture?
		CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, fmt,
		                                          CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
		return t
	}

	private func makeTex(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture? {
		let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: w, height: h, mipmapped: false)
		d.usage = [.shaderRead, .shaderWrite]
		d.storageMode = .private
		return device.makeTexture(descriptor: d)
	}

	private func pyramid(_ pb: CVPixelBuffer, _ cmd: MTLCommandBuffer, keep: inout [CVMetalTexture]) -> Pyramid? {
		let id = ObjectIdentifier(pb)
		if let l = lastPyramid, l.id == id, l.pyr.owner === pb { return l.pyr }
		guard let y = planeTexture(pb, 0), let yt = CVMetalTextureGetTexture(y) else { return nil }
		keep.append(y)
		let w4 = yt.width / 4, h4 = yt.height / 4
		guard let q4 = makeTex(w4, h4, .r16Float), let q8 = makeTex(w4 / 2, h4 / 2, .r16Float), let q16 = makeTex(w4 / 4, h4 / 4, .r16Float),
		      let enc = cmd.makeComputeCommandEncoder() else { return nil }
		enc.setComputePipelineState(downsample4)
		enc.setTexture(yt, index: 0); enc.setTexture(q4, index: 1)
		enc.dispatchThreads(MTLSize(width: w4, height: h4, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
		enc.setComputePipelineState(downsample2)
		enc.setTexture(q4, index: 0); enc.setTexture(q8, index: 1)
		enc.dispatchThreads(MTLSize(width: q8.width, height: q8.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
		enc.setTexture(q8, index: 0); enc.setTexture(q16, index: 1)
		enc.dispatchThreads(MTLSize(width: q16.width, height: q16.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
		enc.endEncoding()
		return Pyramid(q4: q4, q8: q8, q16: q16, owner: pb)
	}

	/// Motion from `prev` to `cur` (both decoded pictures, same size). Keeps the field for `warp`.
	func estimate(prev: CVPixelBuffer, cur: CVPixelBuffer) -> Motion? {
		let t0 = CACurrentMediaTime()
		guard let cmd = queue.makeCommandBuffer() else { return nil }
		var keep: [CVMetalTexture] = []
		guard let pp = pyramid(prev, cmd, keep: &keep), let pc = pyramid(cur, cmd, keep: &keep) else { return nil }
		func grid(_ t: MTLTexture) -> (Int, Int) { ((t.width + Self.block - 1) / Self.block, (t.height + Self.block - 1) / Self.block) }
		let (cw, ch) = grid(pc.q16), (mw, mh) = grid(pc.q8), (fw, fh) = grid(pc.q4)
		if fineSize != (fw, fh) {
			fineSize = (fw, fh)
			coarseBuf = device.makeBuffer(length: cw * ch * 16, options: .storageModePrivate)
			midBuf = device.makeBuffer(length: mw * mh * 16, options: .storageModePrivate)
			fineBuf = device.makeBuffer(length: fw * fh * 16, options: .storageModeShared)
			prevFineBuf = device.makeBuffer(length: fw * fh * 16, options: .storageModeShared)
			filteredBuf = device.makeBuffer(length: fw * fh * 16, options: .storageModeShared)
			let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: fw, height: fh, mipmapped: false)
			d.usage = [.shaderRead, .shaderWrite]
			d.storageMode = .private
			motionTex = device.makeTexture(descriptor: d)
			statsBuf = device.makeBuffer(length: 16, options: .storageModeShared)
			hasPrevField = false
		}
		guard let coarseBuf, let midBuf, let fineBuf, let prevFineBuf, let filteredBuf, let motionTex, let statsBuf,
		      let enc = cmd.makeComputeCommandEncoder() else { return nil }
		memset(statsBuf.contents(), 0, 16)
		let tg = MTLSize(width: 8, height: 8, depth: 1)
		// 1/16: exhaustive +-8 (= +-128 full-res px).
		var cdims = SIMD4<Int32>(Int32(cw), Int32(ch), Int32(cw), Int32(ch))
		let tv = tunables.values
		var range = Int32(tv.exSearchRange16)
		enc.setComputePipelineState(coarse)
		enc.setTexture(pc.q16, index: 0); enc.setTexture(pp.q16, index: 1)
		enc.setBuffer(coarseBuf, offset: 0, index: 0)
		enc.setBytes(&cdims, length: 16, index: 1)
		enc.setBytes(&range, length: 4, index: 2)
		enc.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1), threadsPerThreadgroup: tg)
		// 1/8: refine +-2 around the coarse candidates.
		var mdims = SIMD4<Int32>(Int32(cw), Int32(ch), Int32(mw), Int32(mh))
		var r2 = Int32(tv.exRefineRange8)
		enc.setComputePipelineState(refine)
		enc.setTexture(pc.q8, index: 0); enc.setTexture(pp.q8, index: 1)
		enc.setBuffer(coarseBuf, offset: 0, index: 0)
		enc.setBuffer(midBuf, offset: 0, index: 3)
		enc.setBytes(&mdims, length: 16, index: 1)
		enc.setBytes(&r2, length: 4, index: 2)
		enc.dispatchThreads(MTLSize(width: mw, height: mh, depth: 1), threadsPerThreadgroup: tg)
		// 1/4: refine +-1.
		var fdims = SIMD4<Int32>(Int32(mw), Int32(mh), Int32(fw), Int32(fh))
		var r1 = Int32(tv.exRefineRange4)
		enc.setTexture(pc.q4, index: 0); enc.setTexture(pp.q4, index: 1)
		enc.setBuffer(midBuf, offset: 0, index: 0)
		enc.setBuffer(fineBuf, offset: 0, index: 3)
		enc.setBytes(&fdims, length: 16, index: 1)
		enc.setBytes(&r1, length: 4, index: 2)
		enc.dispatchThreads(MTLSize(width: fw, height: fh, depth: 1), threadsPerThreadgroup: tg)
		// Median + statistics into the filtered field (shared memory, read back for the global motion).
		var dims = SIMD4<Int32>(Int32(mw), Int32(mh), Int32(fw), Int32(fh))
		enc.setComputePipelineState(median)
		enc.setBuffer(fineBuf, offset: 0, index: 3)
		enc.setBuffer(prevFineBuf, offset: 0, index: 4)
		enc.setBuffer(statsBuf, offset: 0, index: 5)
		enc.setBuffer(filteredBuf, offset: 0, index: 6)
		enc.setBytes(&dims, length: 16, index: 1)
		enc.dispatchThreads(MTLSize(width: fw, height: fh, depth: 1), threadsPerThreadgroup: tg)
		enc.endEncoding()
		cmd.commit()
		cmd.waitUntilCompleted()
		// Blocks that show no change (flat or static) cannot be matched; give them the global motion
		// (median of the blocks that changed) so smooth regions move with the scene. Static HUD pixels
		// are protected by the guard in the warp.
		let f = filteredBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: fw * fh)
		var gx: [Float] = [], gy: [Float] = []
		let changedSad = Float(tv.exChangedBlockSad)
		for i in 0..<(fw * fh) where f[i].w >= changedSad { gx.append(f[i].x); gy.append(f[i].y) }
		gx.sort(); gy.sort()
		var global = SIMD2<Float>(gx.isEmpty ? 0 : gx[gx.count / 2], gy.isEmpty ? 0 : gy[gy.count / 2])
		guard let cmd2 = queue.makeCommandBuffer(), let enc2 = cmd2.makeComputeCommandEncoder() else { return nil }
		enc2.setComputePipelineState(fill)
		enc2.setBuffer(filteredBuf, offset: 0, index: 6)
		enc2.setBytes(&dims, length: 16, index: 1)
		enc2.setBytes(&global, length: 8, index: 2)
		var fillParams = SIMD2<Float>(changedSad, Float(tv.exBlockConfidence))
		enc2.setBytes(&fillParams, length: 8, index: 3)
		enc2.setTexture(motionTex, index: 0)
		enc2.dispatchThreads(MTLSize(width: fw, height: fh, depth: 1), threadsPerThreadgroup: tg)
		enc2.endEncoding()
		cmd2.commit()
		cmd2.waitUntilCompleted()
		lastGPUms = (cmd.gpuEndTime - cmd.gpuStartTime + cmd2.gpuEndTime - cmd2.gpuStartTime) * 1000
		_ = keep
		if ProcessInfo.processInfo.environment["PSV_MX_DEBUG"] != nil {
			let f = filteredBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: fw * fh)
			let raw = fineBuf.contents().bindMemory(to: SIMD4<Float>.self, capacity: fw * fh)
			var xs: [Float] = [], ys: [Float] = [], conf = 0, rx: [Float] = []
			for i in 0..<(fw * fh) {
				xs.append(f[i].x); ys.append(f[i].y); rx.append(raw[i].x * 4)
				if f[i].z < 0.6 * f[i].w || f[i].w < 0.25 { conf += 1 }
			}
			xs.sort(); ys.sort(); rx.sort()
			NSLog("[mx] estimate GPU %.2f ms, wall %.2f ms", lastGPUms, (CACurrentMediaTime() - t0) * 1000)
			NSLog("[mx] field %dx%d: dx median %.1f (p10 %.1f p90 %.1f), raw dx median %.1f, dy median %.1f, confident %.0f%%",
			      fw, fh, xs[xs.count / 2], xs[xs.count / 10], xs[xs.count * 9 / 10], rx[rx.count / 2], ys[ys.count / 2], Double(conf) * 100 / Double(fw * fh))
		}
		// This interval's filtered field becomes next interval's "previous".
		self.prevFineBuf = filteredBuf
		self.filteredBuf = prevFineBuf
		lastPyramid = (ObjectIdentifier(cur), pc)
		let s = statsBuf.contents().bindMemory(to: UInt32.self, capacity: 4)
		let n = Float(fw * fh)
		let sad = Float(s[0]) / 1024, sad0 = Float(s[1]) / 1024
		let m = Motion(meanMotion: Float(s[2]) / 64 / n, fieldChange: Float(s[3]) / 64 / n,
		               residualRatio: sad0 > 0.5 ? min(1, sad / sad0) : 0, hasPreviousField: hasPrevField,
		               ms: (CACurrentMediaTime() - t0) * 1000)
		hasPrevField = true
		return m
	}

	/// Forgets the previous field (after a cut / loss), so the next `fieldChange` is not trusted.
	func resetHistory() { hasPrevField = false; lastPyramid = nil }

	/// Warps `cur` forward by `factor` of the last estimated motion (0.5 = half an interval ahead) into a
	/// new picture of the same format and size, with the static-overlay guard against `prev`.
	func warp(cur: CVPixelBuffer, prev: CVPixelBuffer, factor: Float) -> CVPixelBuffer? {
		guard let motionTex else { return nil }
		let w = CVPixelBufferGetWidth(cur), h = CVPixelBufferGetHeight(cur), fmt = CVPixelBufferGetPixelFormatType(cur)
		if pool == nil || poolKey != (w, h, fmt) {
			let a: [String: Any] = [kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
			                        kCVPixelBufferPixelFormatTypeKey as String: fmt, kCVPixelBufferMetalCompatibilityKey as String: true,
			                        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
			var p: CVPixelBufferPool?
			CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, a as CFDictionary, &p)
			pool = p
			poolKey = (w, h, fmt)
		}
		var out: CVPixelBuffer?
		guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess, let o = out,
		      let cmd = queue.makeCommandBuffer() else { return nil }
		CVBufferPropagateAttachments(cur, o)
		let ten = Self.tenBit(cur)
		var keep: [CVMetalTexture] = []
		var u = SIMD4<Float>(factor, Float(Self.fullBlock), Float(fineSize.0), Float(fineSize.1))
		let tv = tunables.values
		var ov = SIMD2<Float>(Float(tv.exOverlayRatio), Float(tv.exOverlayMaxCodes / 255))
		for plane in 0..<2 {
			guard let c = planeTexture(cur, plane), let p = planeTexture(prev, plane), let d = planeTexture(o, plane) else { return nil }
			keep += [c, p, d]
			let pass = MTLRenderPassDescriptor()
			pass.colorAttachments[0].texture = CVMetalTextureGetTexture(d)
			pass.colorAttachments[0].loadAction = .dontCare
			pass.colorAttachments[0].storeAction = .store
			guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
			enc.setRenderPipelineState(plane == 0 ? (ten ? warpY16 : warpY8) : (ten ? warpC16 : warpC8))
			enc.setFragmentTexture(CVMetalTextureGetTexture(c), index: 0)
			enc.setFragmentTexture(CVMetalTextureGetTexture(p), index: 1)
			enc.setFragmentTexture(motionTex, index: 2)
			enc.setFragmentBytes(&u, length: 16, index: 0)
			enc.setFragmentBytes(&ov, length: 8, index: 1)
			enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			enc.endEncoding()
		}
		cmd.commit()
		cmd.waitUntilCompleted()
		lastWarpGPUms = (cmd.gpuEndTime - cmd.gpuStartTime) * 1000
		_ = keep
		return o
	}

	static let shaders = """
	#include <metal_stdlib>
	using namespace metal;

	// 4x4 box average with 4 bilinear taps (each tap averages a 2x2 quad).
	kernel void mx_down4(texture2d<float, access::sample> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
	                     uint2 g [[thread_position_in_grid]]) {
		if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
		constexpr sampler ls(filter::linear, address::clamp_to_edge, coord::pixel);
		float2 o = float2(g * 4);
		float s = src.sample(ls, o + float2(1, 1)).r + src.sample(ls, o + float2(3, 1)).r
		        + src.sample(ls, o + float2(1, 3)).r + src.sample(ls, o + float2(3, 3)).r;
		dst.write(float4(s / 4.0), g);
	}

	kernel void mx_down2(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],
	                     uint2 g [[thread_position_in_grid]]) {
		if (g.x >= dst.get_width() || g.y >= dst.get_height()) return;
		float s = src.read(g * 2).r + src.read(g * 2 + uint2(1, 0)).r + src.read(g * 2 + uint2(0, 1)).r + src.read(g * 2 + uint2(1, 1)).r;
		dst.write(float4(s / 4.0), g);
	}

	constant int B = 8;

	// SAD of the 8x8 block at `o` in cur against prev displaced by `d` (clamped at the borders).
	float block_sad(texture2d<float, access::read> cur, texture2d<float, access::read> prev, int2 o, int2 d) {
		int2 mx = int2(cur.get_width() - 1, cur.get_height() - 1);
		float s = 0.0;
		for (int y = 0; y < B; y++) for (int x = 0; x < B; x++) {
			int2 p = clamp(o + int2(x, y), int2(0), mx);
			int2 q = clamp(o + int2(x, y) + d, int2(0), mx);
			s += abs(cur.read(uint2(p)).r - prev.read(uint2(q)).r);
		}
		return s;
	}

	// Coarse level (1/8): exhaustive search; small bias towards short vectors (static areas stay static).
	kernel void mx_coarse(texture2d<float, access::read> cur [[texture(0)]], texture2d<float, access::read> prev [[texture(1)]],
	                      device float4 *out [[buffer(0)]], constant int4 &dims [[buffer(1)]], constant int &range [[buffer(2)]],
	                      uint2 g [[thread_position_in_grid]]) {
		if (int(g.x) >= dims.x || int(g.y) >= dims.y) return;
		int2 o = int2(g) * B;
		float sad0 = block_sad(cur, prev, o, int2(0));
		float best = sad0;
		int2 bd = int2(0);
		for (int dy = -range; dy <= range; dy++) for (int dx = -range; dx <= range; dx++) {
			float s = block_sad(cur, prev, o, int2(dx, dy)) + 0.0005 * float(abs(dx) + abs(dy));
			if (s < best) { best = s; bd = int2(dx, dy); }
		}
		out[g.y * dims.x + g.x] = float4(float2(bd), best, sad0);
	}

	// Fine level (1/4): candidates from the coarse field (own + 4 neighbours, scaled x2) and zero, each refined +-2.
	kernel void mx_refine(texture2d<float, access::read> cur [[texture(0)]], texture2d<float, access::read> prev [[texture(1)]],
	                      device const float4 *coarse [[buffer(0)]], constant int4 &dims [[buffer(1)]], constant int &r [[buffer(2)]],
	                      device float4 *out [[buffer(3)]], uint2 g [[thread_position_in_grid]]) {
		if (int(g.x) >= dims.z || int(g.y) >= dims.w) return;
		int2 o = int2(g) * B;
		int2 c = clamp(int2(g) / 2, int2(0), int2(dims.x - 1, dims.y - 1));
		int2 cands[6];
		cands[0] = int2(0);
		int2 offs[5] = { int2(0, 0), int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
		for (int i = 0; i < 5; i++) {
			int2 cc = clamp(c + offs[i], int2(0), int2(dims.x - 1, dims.y - 1));
			cands[i + 1] = int2(coarse[cc.y * dims.x + cc.x].xy) * 2;
		}
		float sad0 = block_sad(cur, prev, o, int2(0));
		// Start from the block's own coarse prediction (ties keep it: smooth fields in ambiguous areas).
		float best = block_sad(cur, prev, o, cands[1]);
		int2 bd = cands[1];
		for (int i = 0; i < 6; i++) for (int dy = -r; dy <= r; dy++) for (int dx = -r; dx <= r; dx++) {
			int2 d = cands[i] + int2(dx, dy);
			float s = block_sad(cur, prev, o, d);
			if (s < best - 1e-4) { best = s; bd = d; }
		}
		out[g.y * dims.z + g.x] = float4(float2(bd), best, sad0);
	}

	// 3x3 median of the fine field (outlier removal), confidence, global statistics, and the motion
	// texture used by the warp: xy = displacement cur -> prev in full-resolution pixels, z = confidence.
	kernel void mx_median(device const float4 *fine [[buffer(3)]], device const float4 *prevField [[buffer(4)]],
	                      device atomic_uint *stats [[buffer(5)]], device float4 *filtered [[buffer(6)]], constant int4 &dims [[buffer(1)]],
	                      uint2 g [[thread_position_in_grid]]) {
		if (int(g.x) >= dims.z || int(g.y) >= dims.w) return;
		float xs[9], ys[9];
		int n = 0;
		for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
			int2 q = clamp(int2(g) + int2(dx, dy), int2(0), int2(dims.z - 1, dims.w - 1));
			float4 v = fine[q.y * dims.z + q.x];
			xs[n] = v.x; ys[n] = v.y; n++;
		}
		for (int i = 0; i < 9; i++) for (int j = i + 1; j < 9; j++) {
			if (xs[j] < xs[i]) { float t = xs[i]; xs[i] = xs[j]; xs[j] = t; }
			if (ys[j] < ys[i]) { float t = ys[i]; ys[i] = ys[j]; ys[j] = t; }
		}
		uint idx = g.y * dims.z + g.x;
		float4 me = fine[idx];
		float2 d = float2(xs[4], ys[4]) * 4.0; // 1/4 resolution -> full resolution pixels
		float2 pd = prevField[idx].xy;
		atomic_fetch_add_explicit(&stats[0], uint(me.z * 1024.0), memory_order_relaxed);
		atomic_fetch_add_explicit(&stats[1], uint(me.w * 1024.0), memory_order_relaxed);
		atomic_fetch_add_explicit(&stats[2], uint(length(d) * 64.0), memory_order_relaxed);
		atomic_fetch_add_explicit(&stats[3], uint(length(d - pd) * 64.0), memory_order_relaxed);
		// Filtered vector (full-res px); also next interval's "previous field".
		filtered[idx] = float4(d, me.z, me.w);
	}

	// Motion texture for the warp: blocks that changed keep their vector (confidence 0 if the match does
	// not explain the change); blocks that did not change take the global motion.
	// p = (changed-block SAD threshold, block confidence ratio)
	kernel void mx_fill(device const float4 *filtered [[buffer(6)]], constant int4 &dims [[buffer(1)]], constant float2 &global [[buffer(2)]],
	                    constant float2 &p [[buffer(3)]],
	                    texture2d<float, access::write> motion [[texture(0)]], uint2 g [[thread_position_in_grid]]) {
		if (int(g.x) >= dims.z || int(g.y) >= dims.w) return;
		float4 v = filtered[g.y * dims.z + g.x];
		bool changed = v.w >= p.x;
		float2 d = changed ? v.xy : global;
		float conf = (!changed || v.z < p.y * v.w) ? 1.0 : 0.0;
		motion.write(float4(d, conf, 0.0), g);
	}

	struct MXOut { float4 position [[position]]; float2 uv; };
	vertex MXOut mx_vertex(uint vid [[vertex_id]]) {
		float2 q = float2((vid << 1) & 2, vid & 2);
		MXOut o;
		o.position = float4(q * 2.0 - 1.0, 0.0, 1.0);
		o.uv = float2(q.x, 1.0 - q.y);
		return o;
	}

	// u = (factor, full-res block size, field width, field height)
	float4 motion_at(texture2d<float> motion, float2 fullPx, float4 u) {
		constexpr sampler ls(filter::linear, address::clamp_to_edge);
		float2 uv = fullPx / (u.y * float2(u.z, u.w));
		return motion.sample(ls, uv);
	}

	// Overlay test at q: does "static" (C = P at q) explain the picture clearly better than "moved with the
	// motion" (C(q) = P(q + d))? HUD, minimap, subtitles are static over a moving scene.
	bool overlay_y(texture2d<float> cur, texture2d<float> prev, float2 q, float2 d, float2 size, float2 ov) {
		constexpr sampler ls(filter::linear, address::clamp_to_edge);
		float sStatic = 0.0, sMove = 0.0;
		float2 offs[5] = { float2(0, 0), float2(-2, 0), float2(2, 0), float2(0, -2), float2(0, 2) };
		for (int i = 0; i < 5; i++) {
			float2 t = q + offs[i];
			float c = cur.sample(ls, t / size).r;
			sStatic += abs(c - prev.sample(ls, t / size).r);
			sMove += abs(c - prev.sample(ls, (t + d) / size).r);
		}
		return sStatic < ov.x * sMove && sStatic < 5.0 * ov.y;
	}

	bool overlay_c(texture2d<float> cur, texture2d<float> prev, float2 q, float2 d, float2 size, float2 ov) {
		constexpr sampler ls(filter::linear, address::clamp_to_edge);
		float sStatic = 0.0, sMove = 0.0;
		float2 offs[5] = { float2(0, 0), float2(-1, 0), float2(1, 0), float2(0, -1), float2(0, 1) };
		for (int i = 0; i < 5; i++) {
			float2 t = q + offs[i];
			float2 c = cur.sample(ls, t / size).rg;
			float2 a = abs(c - prev.sample(ls, t / size).rg), b = abs(c - prev.sample(ls, (t + d) / size).rg);
			sStatic += a.x + a.y;
			sMove += b.x + b.y;
		}
		return sStatic < ov.x * sMove && sStatic < 10.0 * ov.y;
	}

	// Copy overlays; warp everything else from where it comes from, except when that source is an overlay
	// (then keep the current pixel rather than drag the HUD along with the scene).
	fragment float mx_warp_y(MXOut in [[stage_in]], texture2d<float> cur [[texture(0)]], texture2d<float> prev [[texture(1)]],
	                         texture2d<float> motion [[texture(2)]], constant float4 &u [[buffer(0)]], constant float2 &ov [[buffer(1)]]) {
		constexpr sampler ls(filter::linear, address::clamp_to_edge);
		float2 size = float2(cur.get_width(), cur.get_height());
		float2 p = in.position.xy;
		float4 mv = motion_at(motion, p, u);
		if (overlay_y(cur, prev, p, mv.xy, size, ov)) return cur.sample(ls, p / size).r;
		float2 src = p + u.x * mv.z * mv.xy;
		if (overlay_y(cur, prev, src, mv.xy, size, ov)) return cur.sample(ls, p / size).r;
		return cur.sample(ls, src / size).r;
	}

	fragment float2 mx_warp_c(MXOut in [[stage_in]], texture2d<float> cur [[texture(0)]], texture2d<float> prev [[texture(1)]],
	                          texture2d<float> motion [[texture(2)]], constant float4 &u [[buffer(0)]], constant float2 &ov [[buffer(1)]]) {
		constexpr sampler ls(filter::linear, address::clamp_to_edge);
		float2 size = float2(cur.get_width(), cur.get_height());
		float2 p = in.position.xy;
		float4 mv = motion_at(motion, p * 2.0, u); // chroma pixel -> luma pixel position
		float2 dc = mv.xy * 0.5;
		if (overlay_c(cur, prev, p, dc, size, ov)) return cur.sample(ls, p / size).rg;
		float2 src = p + u.x * mv.z * dc;
		if (overlay_c(cur, prev, src, dc, size, ov)) return cur.sample(ls, p / size).rg;
		return cur.sample(ls, src / size).rg;
	}
	"""
}
