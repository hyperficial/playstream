import CoreGraphics
import Foundation
import Metal

/// The last pass before present: places the scaled video into a native-resolution drawable (black
/// bars around it, `present.fullLayer`) and composites the in-frame overlay (the app's stats panel),
/// so nothing has to sit above the Metal layer and the layer can be scanned out directly.
final class PresentCompositor {
	/// A premultiplied BGRA image placed at `rect` (drawable pixels, top-left origin).
	struct Overlay {
		var texture: MTLTexture
		var rect: CGRect
	}

	private let device: MTLDevice
	private var placePSO: [MTLPixelFormat: MTLRenderPipelineState] = [:]
	private var overlayPSO: [MTLPixelFormat: MTLRenderPipelineState] = [:]
	private let library: MTLLibrary?
	private(set) var intermediate: MTLTexture?

	init(device: MTLDevice) {
		self.device = device
		library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
		if library == nil { NSLog("[PSVideo] present compositor shaders failed to compile") }
	}

	/// Scaler target for the full-layer layout: video-rect sized, the drawable's pixel format.
	func intermediateTexture(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
		if let t = intermediate, t.width == width, t.height == height, t.pixelFormat == format { return t }
		let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
		d.usage = [.renderTarget, .shaderRead]
		d.storageMode = .private
		intermediate = device.makeTexture(descriptor: d)
		return intermediate
	}

	func releaseIntermediate() { intermediate = nil }

	private func pso(_ cache: inout [MTLPixelFormat: MTLRenderPipelineState], _ fragment: String, _ format: MTLPixelFormat, blend: Bool) -> MTLRenderPipelineState? {
		if let p = cache[format] { return p }
		guard let lib = library else { return nil }
		let d = MTLRenderPipelineDescriptor()
		d.vertexFunction = lib.makeFunction(name: "pc_vertex")
		d.fragmentFunction = lib.makeFunction(name: fragment)
		d.colorAttachments[0].pixelFormat = format
		if blend {
			let a = d.colorAttachments[0]!
			a.isBlendingEnabled = true
			a.rgbBlendOperation = .add
			a.alphaBlendOperation = .add
			a.sourceRGBBlendFactor = .one
			a.sourceAlphaBlendFactor = .one
			a.destinationRGBBlendFactor = .oneMinusSourceAlpha
			a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
		}
		let p = try? device.makeRenderPipelineState(descriptor: d)
		cache[format] = p
		return p
	}

	struct OverlayParams {
		var rect: SIMD4<Float>      // x, y, w, h in clip-space-ready normalized target coords (0...1, top-left)
		var hdr: UInt32
		var whiteScale: Float       // overlay white in PQ-normalized linear light (nits / 10000)
		var opacity: Float
		var pad: Float = 0
	}

	/// Encodes into `cmd` (after the scaler's passes): optional placement of `video` at `videoRect`
	/// (clearing the rest to black), then the overlay. Returns false if nothing could be encoded and
	/// a placement was required.
	@discardableResult
	func encode(cmd: MTLCommandBuffer, target: MTLTexture, video: MTLTexture?, videoRect: CGRect, overlay: Overlay?, hdr: Bool,
	            whiteNits: Double, opacity: Double) -> Bool {
		if video == nil && overlay == nil { return true }
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = target
		pass.colorAttachments[0].loadAction = video != nil ? .clear : .load
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store
		guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return false }
		let tw = Float(target.width), th = Float(target.height)
		if let v = video {
			guard let p = pso(&placePSO, "pc_place", target.pixelFormat, blend: false) else { enc.endEncoding(); return false }
			enc.setRenderPipelineState(p)
			var params = OverlayParams(rect: SIMD4(Float(videoRect.minX) / tw, Float(videoRect.minY) / th, Float(videoRect.width) / tw, Float(videoRect.height) / th),
			                           hdr: 0, whiteScale: 0, opacity: 1)
			enc.setVertexBytes(&params, length: MemoryLayout<OverlayParams>.stride, index: 0)
			enc.setFragmentTexture(v, index: 0)
			enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		}
		if let o = overlay, opacity > 0, let p = pso(&overlayPSO, "pc_overlay", target.pixelFormat, blend: true) {
			enc.setRenderPipelineState(p)
			var params = OverlayParams(rect: SIMD4(Float(o.rect.minX) / tw, Float(o.rect.minY) / th, Float(o.rect.width) / tw, Float(o.rect.height) / th),
			                           hdr: hdr ? 1 : 0, whiteScale: Float(whiteNits / 10000), opacity: Float(opacity))
			enc.setVertexBytes(&params, length: MemoryLayout<OverlayParams>.stride, index: 0)
			enc.setFragmentBytes(&params, length: MemoryLayout<OverlayParams>.stride, index: 0)
			enc.setFragmentTexture(o.texture, index: 0)
			enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		}
		enc.endEncoding()
		return true
	}

	static let shaderSource = """
	#include <metal_stdlib>
	using namespace metal;

	struct Params { float4 rect; uint hdr; float whiteScale; float opacity; float pad; };
	struct VOut { float4 pos [[position]]; float2 uv; };

	// Quad covering `rect` (0...1 target coordinates, top-left origin).
	vertex VOut pc_vertex(uint vid [[vertex_id]], constant Params& p [[buffer(0)]]) {
		float2 c = float2(vid & 1, vid >> 1);
		float2 t = p.rect.xy + c * p.rect.zw;
		VOut o;
		o.pos = float4(t.x * 2 - 1, 1 - t.y * 2, 0, 1);
		o.uv = c;
		return o;
	}

	fragment float4 pc_place(VOut in [[stage_in]], texture2d<float> src [[texture(0)]]) {
		constexpr sampler s(filter::linear, address::clamp_to_edge);
		return float4(src.sample(s, in.uv).rgb, 1);
	}

	static float3 srgb_to_linear(float3 c) {
		return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
	}
	static float3 pq_encode(float3 l) {   // l: linear light, 1.0 = 10000 nits
		const float m1 = 0.1593017578125, m2 = 78.84375, c1 = 0.8359375, c2 = 18.8515625, c3 = 18.6875;
		float3 p = pow(max(l, 0.0), m1);
		return pow((c1 + c2 * p) / (1 + c3 * p), m2);
	}

	// Premultiplied sRGB BGRA overlay -> the drawable's encoding, premultiplied, blended (one, 1 - a).
	fragment float4 pc_overlay(VOut in [[stage_in]], texture2d<float> img [[texture(0)]], constant Params& p [[buffer(0)]]) {
		constexpr sampler s(filter::linear, address::clamp_to_edge);
		float4 c = img.sample(s, in.uv);
		float a = c.a * p.opacity;
		if (a <= 0.0) { return float4(0); }
		float3 straight = c.rgb / max(c.a, 1e-4);
		float3 outc;
		if (p.hdr != 0) {
			float3 lin = srgb_to_linear(straight);
			// BT.709 -> BT.2020 primaries.
			float3x3 m = float3x3(float3(0.6274, 0.0691, 0.0164), float3(0.3293, 0.9195, 0.0880), float3(0.0433, 0.0114, 0.8956));
			outc = pq_encode(m * lin * p.whiteScale);
		} else {
			outc = straight;   // SDR drawable carries video R'G'B' (BT.709): sRGB values written as is
		}
		return float4(outc * a, a);
	}
	"""
}
