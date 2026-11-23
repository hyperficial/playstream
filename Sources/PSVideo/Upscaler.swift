import CoreVideo
import Foundation
import Metal
import MetalFX
import QuartzCore
import simd

/// How the Metal path scales the 1080p picture to the display's pixel size.
public enum VideoUpscaler: String, Sendable, CaseIterable, Codable {
	/// Today's behaviour: the drawable is the video size and the compositor scales it (bilinear).
	case off
	/// Catmull-Rom bicubic resample to the display's pixel size in the colour-conversion pass. Cheap,
	/// sharper than bilinear, no ringing worth mentioning, works everywhere.
	case bicubic
	/// MetalFX spatial upscaler (Apple's edge-adaptive scaler) to the display's pixel size.
	/// Falls back to `.bicubic` if the device doesn't support MetalFX.
	case metalFXSpatial
	/// AMD FidelityFX Super Resolution 1: EASU edge-adaptive upscale + RCAS sharpening (MIT licence, ported
	/// from AMD's source, see FSR1.swift). Sharpening strength: `VideoPipeline.upscalerSharpness`.
	case fsr1
}

/// Which signal MetalFX sees for HDR. `.pq`: the PQ-encoded R'G'B' (a perceptual [0,1] signal) in
/// MetalFX's perceptual mode. `.linear`: linear light (1.0 = 100 nits) in MetalFX's HDR mode, re-encoded
/// to PQ afterwards. Chosen by measurement (harness `--quality`): linear scored 41.42 dB vs 41.07 dB
/// for PQ and overshoots highlights less, so it is the default.
enum MetalFXHDRDomain: String {
	case pq, linear
}

/// Colour conversion + scaling into an arbitrary target texture (a drawable, or an offscreen texture
/// for diagnostics). One instance per thread of use; not thread safe.
final class FrameScaler {
	struct Uniforms {
		var matrix: simd_float3x3
		var yScale: Float
		var yOffset: Float
		var cScale: Float
		var cOffset: Float
		/// x: 1 = output linear light (PQ EOTF, 1.0 = 100 nits); y: 1 = copy pass encodes linear -> PQ.
		var flags: SIMD4<UInt32> = .zero
	}

	private let device: MTLDevice
	private let library: MTLLibrary
	private var pipelines: [String: MTLRenderPipelineState] = [:]
	let metalFXSupported: Bool
	var hdrDomain: MetalFXHDRDomain = .linear
	/// Sharpening for scalers with a sharpening stage (FSR 1 RCAS), 0...1. 0 = no sharpening pass.
	var sharpness: Float = 0.5
	private let fsrLibrary: MTLLibrary
	private var fsrInput: MTLTexture?
	private var fsrTemp: MTLTexture?

	// MetalFX state, rebuilt when sizes / formats change.
	private struct ScalerKey: Equatable {
		var inW: Int, inH: Int, outW: Int, outH: Int
		var mode: MTLFXSpatialScalerColorProcessingMode
	}
	private var scalerKey: ScalerKey?
	private var scaler: MTLFXSpatialScaler?
	private var intermediate: MTLTexture?
	private var scaled: MTLTexture?
	/// Time it took to (re)build the scaler and its textures last time, ms.
	private(set) var lastRebuildMs: Double = 0

	init?(device: MTLDevice) {
		self.device = device
		do {
			library = try device.makeLibrary(source: Self.shaderSource, options: nil)
		} catch {
			NSLog("[PSVideo] scaler shader compile failed: %@", "\(error)")
			return nil
		}
		metalFXSupported = MTLFXSpatialScalerDescriptor.supportsDevice(device)
		do {
			fsrLibrary = try device.makeLibrary(source: FSR1.shaderSource, options: nil)
		} catch {
			NSLog("[PSVideo] FSR1 shader compile failed: %@", "\(error)")
			return nil
		}
		if let d = ProcessInfo.processInfo.environment["PSVIDEO_MFX_DOMAIN"], let v = MetalFXHDRDomain(rawValue: d) { hdrDomain = v }
	}

	private func pipeline(_ fragment: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
		let key = "\(fragment)/\(format.rawValue)"
		if let p = pipelines[key] { return p }
		let d = MTLRenderPipelineDescriptor()
		let lib = fragment.hasPrefix("fsr_") ? fsrLibrary : library
		d.vertexFunction = lib.makeFunction(name: fragment.hasPrefix("fsr_") ? "fsr_vertex" : "psv_vertex")
		d.fragmentFunction = lib.makeFunction(name: fragment)
		d.colorAttachments[0].pixelFormat = format
		guard let p = try? device.makeRenderPipelineState(descriptor: d) else { return nil }
		pipelines[key] = p
		return p
	}

	/// The mode that will actually run for this input/output size: scaling only when the output is
	/// larger than the video (downscaling is left to the compositor), MetalFX only where supported.
	func effectiveMode(_ requested: VideoUpscaler, input: (Int, Int), output: (Int, Int)) -> VideoUpscaler {
		guard requested != .off, output.0 > input.0, output.1 > input.1 else { return .off }
		if requested == .metalFXSpatial && !metalFXSupported { return .bicubic }
		return requested
	}

	/// Encodes YCbCr -> R'G'B' (stream transfer domain: PQ for HDR, BT.709 for SDR), scaled to
	/// `target`'s size with `mode`. Returns the command buffers in submission order; the caller attaches
	/// present / completion handlers to the last one and commits all of them in order. The first entry
	/// of `gpuStages` is the conversion pass, the second (if any) the MetalFX pass.
	func encode(queue: MTLCommandQueue, y: MTLTexture, c: MTLTexture, uniforms: Uniforms, mode: VideoUpscaler, hdr: Bool, target: MTLTexture)
		-> (buffers: [MTLCommandBuffer], scalerBuffer: MTLCommandBuffer?)?
	{
		switch mode {
		case .off, .bicubic:
			guard let cmd = queue.makeCommandBuffer(),
			      let p = pipeline(mode == .off ? "psv_fragment" : "psv_bicubic", target.pixelFormat)
			else { return nil }
			draw(cmd, pipeline: p, target: target, textures: [y, c], uniforms: uniforms)
			return ([cmd], nil)

		case .fsr1:
			// FSR 1 works on perceptually encoded 0...1 signals (AMD: "after tonemapping"); RCAS's clip
			// limiter assumes a peak of 1.0. PQ R'G'B' is such a signal, so HDR runs in the PQ domain and
			// highlights stay where PQ puts them (no tone mapping, nothing clipped below PQ 1.0).
			let w = target.width, h = target.height
			if fsrInput?.width != y.width || fsrInput?.height != y.height {
				let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: y.width, height: y.height, mipmapped: false)
				d.usage = [.renderTarget, .shaderRead]
				d.storageMode = .private
				fsrInput = device.makeTexture(descriptor: d)
			}
			let sharpen = sharpness > 0.001
			if sharpen && (fsrTemp?.width != w || fsrTemp?.height != h) {
				let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
				d.usage = [.renderTarget, .shaderRead]
				d.storageMode = .private
				fsrTemp = device.makeTexture(descriptor: d)
			}
			guard let input = fsrInput, let convert = queue.makeCommandBuffer(), let scale = queue.makeCommandBuffer(),
			      let pConvert = pipeline("psv_fragment", input.pixelFormat),
			      let pEasu = pipeline("fsr_easu", sharpen ? .rgba16Float : target.pixelFormat)
			else { return nil }
			var u = uniforms
			u.flags = .zero
			draw(convert, pipeline: pConvert, target: input, textures: [y, c], uniforms: u)
			var k = FSR1.easuConstants(inputWidth: y.width, inputHeight: y.height, outputWidth: w, outputHeight: h)
			let easuTarget = sharpen ? fsrTemp! : target
			drawRaw(scale, pipeline: pEasu, target: easuTarget, textures: [input], bytes: &k, length: MemoryLayout<FSR1.EasuConstants>.stride)
			if sharpen, let temp = fsrTemp, let pRcas = pipeline("fsr_rcas", target.pixelFormat) {
				var con = FSR1.rcasSharpness(stops: (1 - min(1, sharpness)) * 2)
				drawRaw(scale, pipeline: pRcas, target: target, textures: [temp], bytes: &con, length: 4)
			}
			return ([convert, scale], scale)

		case .metalFXSpatial:
			let linear = hdr && hdrDomain == .linear
			let key = ScalerKey(inW: y.width, inH: y.height, outW: target.width, outH: target.height,
			                    mode: linear ? .hdr : .perceptual)
			guard prepareScaler(key),
			      let scaler, let intermediate, let scaled,
			      let convert = queue.makeCommandBuffer(), let scale = queue.makeCommandBuffer(),
			      let pConvert = pipeline("psv_fragment", intermediate.pixelFormat),
			      let pCopy = pipeline("psv_copy", target.pixelFormat)
			else { return nil }
			var u = uniforms
			u.flags.x = linear ? 1 : 0
			draw(convert, pipeline: pConvert, target: intermediate, textures: [y, c], uniforms: u)
			scaler.colorTexture = intermediate
			scaler.outputTexture = scaled
			scaler.inputContentWidth = y.width
			scaler.inputContentHeight = y.height
			scaler.encode(commandBuffer: scale)
			var cu = uniforms
			cu.flags = SIMD4<UInt32>(0, linear ? 1 : 0, 0, 0)
			draw(scale, pipeline: pCopy, target: target, textures: [scaled], uniforms: cu)
			return ([convert, scale], scale)
		}
	}

	private func prepareScaler(_ key: ScalerKey) -> Bool {
		if key == scalerKey, scaler != nil { return true }
		let t0 = CACurrentMediaTime()
		let d = MTLFXSpatialScalerDescriptor()
		d.inputWidth = key.inW
		d.inputHeight = key.inH
		d.outputWidth = key.outW
		d.outputHeight = key.outH
		d.colorTextureFormat = .rgba16Float
		d.outputTextureFormat = .rgba16Float
		d.colorProcessingMode = key.mode
		guard let s = d.makeSpatialScaler(device: device) else {
			NSLog("[PSVideo] MetalFX spatial scaler creation failed for %dx%d -> %dx%d", key.inW, key.inH, key.outW, key.outH)
			scaler = nil
			scalerKey = nil
			return false
		}
		let ti = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: key.inW, height: key.inH, mipmapped: false)
		ti.usage = s.colorTextureUsage.union([.renderTarget, .shaderRead])
		ti.storageMode = .private
		let to = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: key.outW, height: key.outH, mipmapped: false)
		to.usage = s.outputTextureUsage.union([.shaderRead])
		to.storageMode = .private
		guard let i = device.makeTexture(descriptor: ti), let o = device.makeTexture(descriptor: to) else { return false }
		scaler = s
		intermediate = i
		scaled = o
		scalerKey = key
		lastRebuildMs = (CACurrentMediaTime() - t0) * 1000
		return true
	}

	/// Drops the MetalFX scaler and its textures (e.g. when switching away from it).
	func releaseScaler() {
		scaler = nil
		intermediate = nil
		scaled = nil
		scalerKey = nil
	}

	private func drawRaw<T>(_ cmd: MTLCommandBuffer, pipeline: MTLRenderPipelineState, target: MTLTexture, textures: [MTLTexture], bytes: inout T, length: Int) {
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = target
		pass.colorAttachments[0].loadAction = .dontCare
		pass.colorAttachments[0].storeAction = .store
		guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
		enc.setRenderPipelineState(pipeline)
		for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
		withUnsafeBytes(of: &bytes) { enc.setFragmentBytes($0.baseAddress!, length: length, index: 0) }
		enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		enc.endEncoding()
	}

	private func draw(_ cmd: MTLCommandBuffer, pipeline: MTLRenderPipelineState, target: MTLTexture, textures: [MTLTexture], uniforms: Uniforms) {
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = target
		pass.colorAttachments[0].loadAction = .dontCare
		pass.colorAttachments[0].storeAction = .store
		guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
		var u = uniforms
		enc.setRenderPipelineState(pipeline)
		for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
		enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
		enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		enc.endEncoding()
	}

	static let shaderSource = """
	#include <metal_stdlib>
	using namespace metal;

	struct PSVOut { float4 position [[position]]; float2 uv; };

	struct PSVUniforms {
		float3x3 matrix;
		float yScale;
		float yOffset;
		float cScale;
		float cOffset;
		uint4 flags;
	};

	// SMPTE ST 2084.
	constant float m1 = 0.1593017578125;
	constant float m2 = 78.84375;
	constant float c1 = 0.8359375;
	constant float c2 = 18.8515625;
	constant float c3 = 18.6875;

	float3 pq_to_linear100(float3 e) {     // PQ signal -> linear light, 1.0 = 100 nits
		float3 p = pow(max(e, 0.0), 1.0 / m2);
		float3 l = pow(max(p - c1, 0.0) / (c2 - c3 * p), 1.0 / m1);
		return l * 100.0;
	}

	float3 linear100_to_pq(float3 l) {
		float3 y = pow(clamp(l / 100.0, 0.0, 1.0), m1);
		return pow((c1 + c2 * y) / (1.0 + c3 * y), m2);
	}

	// One oversized triangle covering the viewport.
	vertex PSVOut psv_vertex(uint vid [[vertex_id]]) {
		float2 p = float2((vid << 1) & 2, vid & 2);
		PSVOut o;
		o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
		o.uv = float2(p.x, 1.0 - p.y);
		return o;
	}

	float3 ycc_to_rgb(float y, float2 c, constant PSVUniforms &u) {
		float3 rgb = u.matrix * float3(y * u.yScale + u.yOffset, c.x * u.cScale + u.cOffset, c.y * u.cScale + u.cOffset);
		return saturate(rgb);
	}

	// Bilinear (also the 'off' path at video size, where it is a 1:1 fetch).
	fragment float4 psv_fragment(PSVOut in [[stage_in]],
	                             texture2d<float> yTex [[texture(0)]],
	                             texture2d<float> cTex [[texture(1)]],
	                             constant PSVUniforms &u [[buffer(0)]]) {
		constexpr sampler s(filter::linear, address::clamp_to_edge);
		float3 rgb = ycc_to_rgb(yTex.sample(s, in.uv).r, cTex.sample(s, in.uv).rg, u);
		if (u.flags.x != 0) rgb = pq_to_linear100(rgb);
		return float4(rgb, 1.0);
	}

	// Catmull-Rom bicubic with 9 bilinear taps.
	float4 catmull_rom(texture2d<float> tex, sampler s, float2 uv) {
		float2 size = float2(tex.get_width(), tex.get_height());
		float2 pos = uv * size;
		float2 t1 = floor(pos - 0.5) + 0.5;
		float2 f = pos - t1;
		float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
		float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
		float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
		float2 w3 = f * f * (-0.5 + 0.5 * f);
		float2 w12 = w1 + w2;
		float2 t0 = (t1 - 1.0) / size;
		float2 t3 = (t1 + 2.0) / size;
		float2 t12 = (t1 + w2 / w12) / size;
		float4 r = 0.0;
		r += tex.sample(s, float2(t0.x, t0.y)) * w0.x * w0.y;
		r += tex.sample(s, float2(t12.x, t0.y)) * w12.x * w0.y;
		r += tex.sample(s, float2(t3.x, t0.y)) * w3.x * w0.y;
		r += tex.sample(s, float2(t0.x, t12.y)) * w0.x * w12.y;
		r += tex.sample(s, float2(t12.x, t12.y)) * w12.x * w12.y;
		r += tex.sample(s, float2(t3.x, t12.y)) * w3.x * w12.y;
		r += tex.sample(s, float2(t0.x, t3.y)) * w0.x * w3.y;
		r += tex.sample(s, float2(t12.x, t3.y)) * w12.x * w3.y;
		r += tex.sample(s, float2(t3.x, t3.y)) * w3.x * w3.y;
		return r;
	}

	fragment float4 psv_bicubic(PSVOut in [[stage_in]],
	                            texture2d<float> yTex [[texture(0)]],
	                            texture2d<float> cTex [[texture(1)]],
	                            constant PSVUniforms &u [[buffer(0)]]) {
		constexpr sampler s(filter::linear, address::clamp_to_edge);
		float y = catmull_rom(yTex, s, in.uv).r;
		float2 c = catmull_rom(cTex, s, in.uv).rg;
		return float4(ycc_to_rgb(y, c, u), 1.0);
	}

	// MetalFX output -> drawable (same size); optional linear -> PQ re-encode.
	fragment float4 psv_copy(PSVOut in [[stage_in]],
	                         texture2d<float> src [[texture(0)]],
	                         constant PSVUniforms &u [[buffer(0)]]) {
		constexpr sampler s(filter::nearest, address::clamp_to_edge);
		float3 rgb = src.sample(s, in.uv).rgb;
		rgb = (u.flags.y != 0) ? linear100_to_pq(rgb) : saturate(rgb);
		return float4(rgb, 1.0);
	}
	"""
}
