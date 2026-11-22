import AppKit
import CoreMedia
import CoreVideo
import Metal
import PSContracts
import QuartzCore
import simd
import VideoToolbox

/// Path (b): hardware `VTDecompressionSession` (real-time, asynchronous, no temporal processing) into
/// a Metal YCbCr->RGB pass on a `CAMetalLayer`. Only the newest decoded picture is ever drawn: a frame
/// that is superseded before the render queue gets to it is dropped, so there is never a queue of
/// stale frames between decoder and glass.
///
/// HDR: 10-bit biplanar output ('x420'), converted with the BT.2020 NCL matrix into PQ-encoded RGB on
/// an `rgba16Float` drawable tagged ITU-R 2100 PQ with HDR10 EDR metadata, so the system maps it onto
/// the display's EDR headroom (or tone maps it on an SDR display). SDR: 8-bit, BT.709, sRGB-ish layer.
final class MetalVideoRenderer: VideoRenderer {
	let mode = VideoDisplayMode.metal
	let metalLayer = CAMetalLayer()
	var layer: CALayer { metalLayer }

	private let device: MTLDevice
	private let commandQueue: MTLCommandQueue
	private let library: MTLLibrary
	private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
	private var textureCache: CVMetalTextureCache
	private let stats: StatsCollector
	private let renderQueue = DispatchQueue(label: "PSVideo.metal-render", qos: .userInteractive)

	// Decoder (decoderLock): touched by submit / reset, possibly from different threads.
	private let decoderLock = UnfairLock()
	private var session: VTDecompressionSession?
	private var sessionFD: CMVideoFormatDescription?
	private var sessionPixelFormat: OSType = 0
	private var isShutdown = false

	struct RenderConfig: Equatable {
		var hdr = false
		var matrix = kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String
	}

	// Shared with decoder callbacks and the render queue (lock).
	private struct Shared {
		var needsKeyframe = true
		var decodeFailed = false
		var consecutiveErrors = 0
		var pending: (buffer: CVPixelBuffer, arrival: UInt64)?
		var renderScheduled = false
		var lastFrame: CVPixelBuffer?
		var config = RenderConfig()
	}

	private let lock = UnfairLock()
	private var shared = Shared()
	private var appliedLayerConfig: RenderConfig? // render queue only

	var needsKeyframe: Bool { lock.withLock { shared.needsKeyframe } }

	init?(stats: StatsCollector) {
		guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
		var cache: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
		do {
			library = try device.makeLibrary(source: Self.shaderSource, options: nil)
		} catch {
			NSLog("[PSVideo] Metal shader compile failed: %@", "\(error)")
			return nil
		}
		self.device = device
		self.commandQueue = queue
		self.textureCache = cache
		self.stats = stats
		for f in [MTLPixelFormat.rgba16Float, .bgra8Unorm] {
			guard let p = makePipeline(f) else { return nil }
			pipelines[f] = p
		}

		metalLayer.device = device
		metalLayer.framebufferOnly = true
		metalLayer.isOpaque = true
		metalLayer.backgroundColor = NSColor.black.cgColor
		metalLayer.maximumDrawableCount = 3
		metalLayer.displaySyncEnabled = ProcessInfo.processInfo.environment["PSVIDEO_NO_VSYNC"] == nil
		metalLayer.presentsWithTransaction = false
		metalLayer.allowsNextDrawableTimeout = true
		metalLayer.drawableSize = CGSize(width: 1920, height: 1080)
		applyLayerConfig(RenderConfig())
	}

	deinit {
		shutdown()
	}

	func shutdown() {
		decoderLock.withLock {
			isShutdown = true
			teardownSession()
		}
	}

	private func makePipeline(_ format: MTLPixelFormat) -> MTLRenderPipelineState? {
		let d = MTLRenderPipelineDescriptor()
		d.vertexFunction = library.makeFunction(name: "psv_vertex")
		d.fragmentFunction = library.makeFunction(name: "psv_fragment")
		d.colorAttachments[0].pixelFormat = format
		return try? device.makeRenderPipelineState(descriptor: d)
	}

	// MARK: VideoRenderer

	func configure(codec: VideoCodec, color: VideoColorInfo, formatDescription: CMVideoFormatDescription) {
		lock.withLock {
			shared.config = RenderConfig(hdr: color.isHDR, matrix: color.matrix)
		}
	}

	func submit(_ sample: CMSampleBuffer, isKeyframe: Bool, arrival: UInt64) -> SubmitResult {
		guard let fd = CMSampleBufferGetFormatDescription(sample) else { return .rejected(needsKeyframe: false) }
		let (wantHDR, priorFailure, errorRun): (Bool, Bool, Int) = lock.withLock {
			let f = shared.decodeFailed
			shared.decodeFailed = false
			return (shared.config.hdr, f, shared.consecutiveErrors)
		}

		return decoderLock.withLock {
			// Replaced by another renderer while this frame was in flight: never start a new session.
			if isShutdown { return .rejected(needsKeyframe: true) }
			if errorRun >= 30 && !isKeyframe {
				// Half a second of nothing but decode errors: start over from a keyframe.
				NSLog("[PSVideo] %d consecutive decode errors, resetting decoder", errorRun)
				teardownSession()
				lock.withLock {
					shared.needsKeyframe = true
					shared.consecutiveErrors = 0
				}
				return .rejected(needsKeyframe: true)
			}
			let pixelFormat = wantHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
			if let s = session, let old = sessionFD, !CMFormatDescriptionEqual(old, otherFormatDescription: fd) || pixelFormat != sessionPixelFormat {
				if pixelFormat == sessionPixelFormat && VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: fd) {
					sessionFD = fd
				} else {
					teardownSession()
				}
			}
			if session == nil {
				guard isKeyframe else {
					lock.withLock { shared.needsKeyframe = true }
					return .rejected(needsKeyframe: true)
				}
				guard createSession(fd, pixelFormat: pixelFormat) else {
					return .rejected(needsKeyframe: true)
				}
			}
			guard let session else { return .rejected(needsKeyframe: true) }

			let refcon = UnsafeMutableRawPointer(bitPattern: UInt(mach_absolute_time()))
			var info = VTDecodeInfoFlags()
			let status = VTDecompressionSessionDecodeFrame(
				session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
				frameRefcon: refcon, infoFlagsOut: &info)
			if status != noErr {
				stats.update { $0.decodeErrors += 1 }
				NSLog("[PSVideo] VTDecompressionSessionDecodeFrame failed: %d", status)
				if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr || status == kVTVideoDecoderNotAvailableNowErr {
					// Decoder gone (sleep/wake, GPU change, ...). Recreate on the next keyframe.
					teardownSession()
					lock.withLock { shared.needsKeyframe = true }
					return .rejected(needsKeyframe: true)
				}
				return .rejected(needsKeyframe: bumpErrors())
			}
			if isKeyframe { lock.withLock { shared.needsKeyframe = false } }
			// An asynchronous decode failure of an earlier frame surfaced since the last call.
			if priorFailure && !isKeyframe { return .rejected(needsKeyframe: false) }
			return .accepted
		}
	}

	/// Counts consecutive decode errors; after half a second of nothing but errors, the decoder is reset.
	private func bumpErrors() -> Bool {
		let n = lock.withLock { () -> Int in
			shared.consecutiveErrors += 1
			return shared.consecutiveErrors
		}
		if n >= 30 {
			teardownSession()
			lock.withLock {
				shared.needsKeyframe = true
				shared.consecutiveErrors = 0
			}
			return true
		}
		return false
	}

	func reset() {
		decoderLock.withLock { teardownSession() }
		lock.withLock {
			shared.needsKeyframe = true
			shared.decodeFailed = false
			shared.consecutiveErrors = 0
			shared.pending = nil
			shared.lastFrame = nil
		}
		renderQueue.async { [weak self] in self?.clearToBlack() }
	}

	func displayDidChange(screen: NSScreen?) {
		// The PQ-tagged drawable plus HDR10 EDR metadata lets the system re-map for each display
		// (EDR on the XDR panel, tone mapped on an SDR monitor); force the layer config to be re-applied.
		renderQueue.async { [weak self] in self?.appliedLayerConfig = nil }
	}

	func copyLastPixelBuffer() -> CVPixelBuffer? {
		lock.withLock { shared.lastFrame }
	}

	// MARK: Decoder

	private func createSession(_ fd: CMVideoFormatDescription, pixelFormat: OSType) -> Bool {
		let attrs: [CFString: Any] = [
			kCVPixelBufferPixelFormatTypeKey: pixelFormat,
			kCVPixelBufferMetalCompatibilityKey: true,
			kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
		]
		var callback = VTDecompressionOutputCallbackRecord(
			decompressionOutputCallback: psvDecodeCallback,
			decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
		var s: VTDecompressionSession?
		let hw: [CFString: Any] = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true]
		var status = VTDecompressionSessionCreate(
			allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: hw as CFDictionary,
			imageBufferAttributes: attrs as CFDictionary, outputCallback: &callback, decompressionSessionOut: &s)
		if status != noErr {
			NSLog("[PSVideo] hardware decoder unavailable (%d), trying any decoder", status)
			status = VTDecompressionSessionCreate(
				allocator: kCFAllocatorDefault, formatDescription: fd, decoderSpecification: nil,
				imageBufferAttributes: attrs as CFDictionary, outputCallback: &callback, decompressionSessionOut: &s)
		}
		guard status == noErr, let s else {
			NSLog("[PSVideo] VTDecompressionSessionCreate failed: %d", status)
			return false
		}
		VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
		// HDR10 metadata SEI (if the console sends any) should reach the pixel buffers.
		VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata, value: kCFBooleanTrue)
		session = s
		sessionFD = fd
		sessionPixelFormat = pixelFormat
		lock.withLock { shared.consecutiveErrors = 0 }
		return true
	}

	/// decoderLock held.
	private func teardownSession() {
		guard let s = session else { return }
		VTDecompressionSessionWaitForAsynchronousFrames(s)
		VTDecompressionSessionInvalidate(s)
		session = nil
		sessionFD = nil
	}

	/// VideoToolbox output (decoder thread).
	fileprivate func didDecode(status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, pts: CMTime, submitted: UInt64) {
		let now = mach_absolute_time()
		guard status == noErr, let image, !flags.contains(.frameDropped) else {
			// Reported to the core on the next submit; consecutive errors lead to a decoder reset there.
			lock.withLock {
				shared.decodeFailed = true
				shared.consecutiveErrors += 1
			}
			stats.update { s in
				s.decodeErrors += 1
				s.framesDropped += 1
			}
			return
		}
		stats.frameDecoded(decodeMs: StatsCollector.ms(from: submitted, to: now))
		let arrival = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : submitted
		let (schedule, superseded): (Bool, Bool) = lock.withLock {
			let sup = shared.pending != nil
			shared.pending = (image, arrival)
			shared.lastFrame = image
			shared.consecutiveErrors = 0
			let sch = !shared.renderScheduled
			shared.renderScheduled = true
			return (sch, sup)
		}
		if superseded { stats.update { $0.framesDropped += 1 } }
		if schedule {
			renderQueue.async { [weak self] in self?.renderPending() }
		}
	}

	// MARK: Rendering (render queue)

	private func renderPending() {
		let (item, config): ((buffer: CVPixelBuffer, arrival: UInt64)?, RenderConfig) = lock.withLock {
			let p = shared.pending
			shared.pending = nil
			shared.renderScheduled = false
			return (p, shared.config)
		}
		guard let item else { return }
		if appliedLayerConfig != config { applyLayerConfig(config, sample: item.buffer) }
		draw(item.buffer, arrival: item.arrival, config: config)
	}

	private func applyLayerConfig(_ c: RenderConfig, sample: CVPixelBuffer? = nil) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		if c.hdr {
			metalLayer.pixelFormat = .rgba16Float
			metalLayer.colorspace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
			metalLayer.wantsExtendedDynamicRangeContent = true
			// Reference: content mastered up to 1000 nits; PQ value 1.0 = 10000 nits; SDR white = 100 nits.
			metalLayer.edrMetadata = CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)
			metalLayer.preferredDynamicRange = .high
		} else {
			metalLayer.pixelFormat = .bgra8Unorm
			// The shader writes the stream's R'G'B' untouched. Tag it with the colour space the system
			// itself derives from the decoded buffer (Apple's video convention for BT.709, the same
			// interpretation AVSampleBufferDisplayLayer uses); the plain itur_709 space would apply the
			// camera OETF inverse and crush the shadows.
			var space: CGColorSpace?
			if let sample, let att = CVBufferCopyAttachments(sample, .shouldPropagate) {
				space = CVImageBufferCreateColorSpaceFromAttachments(att)?.takeRetainedValue()
			}
			metalLayer.colorspace = space ?? CGColorSpace(name: CGColorSpace.itur_709)
			metalLayer.wantsExtendedDynamicRangeContent = false
			metalLayer.edrMetadata = nil
			metalLayer.preferredDynamicRange = .standard
		}
		CATransaction.commit()
		appliedLayerConfig = c
	}

	private func draw(_ pb: CVPixelBuffer, arrival: UInt64, config: RenderConfig) {
		let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
		let size = CGSize(width: w, height: h)
		if metalLayer.drawableSize != size {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			metalLayer.drawableSize = size
			CATransaction.commit()
		}
		guard let (yTex, cTex, uniforms) = makeTextures(pb, matrix: config.matrix) else { return }
		guard let drawable = metalLayer.nextDrawable(),
		      let pipeline = pipelines[metalLayer.pixelFormat],
		      let cmd = commandQueue.makeCommandBuffer()
		else {
			stats.update { $0.framesDropped += 1 }
			return
		}
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .dontCare
		pass.colorAttachments[0].storeAction = .store
		guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
		encode(enc, pipeline: pipeline, y: yTex, c: cTex, uniforms: uniforms)

		let arrivalSeconds = Double(arrival) * Double(StatsCollector.timebase.numer) / Double(StatsCollector.timebase.denom) / 1e9
		let stats = self.stats
		drawable.addPresentedHandler { d in
			if d.presentedTime > 0 { stats.onGlass(ms: (d.presentedTime - arrivalSeconds) * 1000) }
		}
		cmd.present(drawable)
		cmd.addCompletedHandler { _ in
			// Keep the CVMetalTextures (and so the IOSurfaces) alive until the GPU is done.
			_ = yTex
			_ = cTex
		}
		cmd.commit()
		stats.handedOff(ms: StatsCollector.ms(from: arrival, to: mach_absolute_time()))
	}

	private func encode(_ enc: MTLRenderCommandEncoder, pipeline: MTLRenderPipelineState, y: CVMetalTexture, c: CVMetalTexture, uniforms: Uniforms) {
		var u = uniforms
		enc.setRenderPipelineState(pipeline)
		enc.setFragmentTexture(CVMetalTextureGetTexture(y), index: 0)
		enc.setFragmentTexture(CVMetalTextureGetTexture(c), index: 1)
		enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
		enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
		enc.endEncoding()
	}

	struct Uniforms {
		var matrix: simd_float3x3
		var yScale: Float
		var yOffset: Float
		var cScale: Float
		var cOffset: Float
	}

	private func makeTextures(_ pb: CVPixelBuffer, matrix: String) -> (CVMetalTexture, CVMetalTexture, Uniforms)? {
		let fmt = CVPixelBufferGetPixelFormatType(pb)
		let tenBit: Bool, fullRange: Bool
		switch fmt {
		case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: tenBit = true; fullRange = false
		case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: tenBit = true; fullRange = true
		case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: tenBit = false; fullRange = false
		case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: tenBit = false; fullRange = true
		default:
			NSLog("[PSVideo] unexpected decoder output format %u", fmt)
			return nil
		}
		guard CVPixelBufferGetPlaneCount(pb) == 2 else { return nil }
		func tex(_ plane: Int, _ f: MTLPixelFormat) -> CVMetalTexture? {
			var t: CVMetalTexture?
			let r = CVMetalTextureCacheCreateTextureFromImage(
				kCFAllocatorDefault, textureCache, pb, nil, f,
				CVPixelBufferGetWidthOfPlane(pb, plane), CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
			return r == kCVReturnSuccess ? t : nil
		}
		guard let y = tex(0, tenBit ? .r16Unorm : .r8Unorm), let c = tex(1, tenBit ? .rg16Unorm : .rg8Unorm) else { return nil }
		return (y, c, Self.uniforms(tenBit: tenBit, fullRange: fullRange, matrix: matrix))
	}

	/// Maps normalised texture samples to Y' in [0,1] and Cb/Cr in [-0.5,0.5], then to non-linear R'G'B'.
	static func uniforms(tenBit: Bool, fullRange: Bool, matrix: String) -> Uniforms {
		// Sample value -> integer code value. 10-bit formats keep the code in the top 10 of 16 bits.
		let toCode: Float = tenBit ? 65535.0 / 64.0 : 255.0
		let maxCode: Float = tenBit ? 1023 : 255
		let s: Float = tenBit ? 4 : 1 // 8-bit -> 10-bit range scale
		let yLo: Float, yRange: Float, cRange: Float
		if fullRange {
			yLo = 0; yRange = maxCode; cRange = maxCode
		} else {
			yLo = 16 * s; yRange = 219 * s; cRange = 224 * s
		}
		let cMid: Float = 128 * s
		let kr: Float, kb: Float
		if matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String) {
			kr = 0.2627; kb = 0.0593
		} else if matrix == (kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4 as String) {
			kr = 0.299; kb = 0.114
		} else {
			kr = 0.2126; kb = 0.0722
		}
		let kg = 1 - kr - kb
		// R = Y + 2(1-kr) Cr ; B = Y + 2(1-kb) Cb ; G = Y - (2 kb (1-kb)/kg) Cb - (2 kr (1-kr)/kg) Cr
		let m = simd_float3x3(columns: (
			SIMD3<Float>(1, 1, 1),
			SIMD3<Float>(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb)),
			SIMD3<Float>(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0)))
		return Uniforms(matrix: m, yScale: toCode / yRange, yOffset: -yLo / yRange, cScale: toCode / cRange, cOffset: -cMid / cRange)
	}

	private func clearToBlack() {
		guard let drawable = metalLayer.nextDrawable(), let cmd = commandQueue.makeCommandBuffer() else { return }
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = drawable.texture
		pass.colorAttachments[0].loadAction = .clear
		pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		pass.colorAttachments[0].storeAction = .store
		cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
		cmd.present(drawable)
		cmd.commit()
	}

	// MARK: Diagnostics

	/// Renders `pb` with the same shader into an offscreen rgba16Float texture and returns the
	/// RGBA half-float pixels (row-major, width*height*4), i.e. exactly what would be presented.
	func renderOffscreen(_ pb: CVPixelBuffer, matrix: String) -> (width: Int, height: Int, rgba: [Float16])? {
		let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
		let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
		d.usage = [.renderTarget, .shaderRead]
		d.storageMode = .shared
		guard let target = device.makeTexture(descriptor: d),
		      let (y, c, u) = makeTextures(pb, matrix: matrix),
		      let pipeline = pipelines[.rgba16Float],
		      let cmd = commandQueue.makeCommandBuffer()
		else { return nil }
		let pass = MTLRenderPassDescriptor()
		pass.colorAttachments[0].texture = target
		pass.colorAttachments[0].loadAction = .dontCare
		pass.colorAttachments[0].storeAction = .store
		guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
		encode(enc, pipeline: pipeline, y: y, c: c, uniforms: u)
		cmd.commit()
		cmd.waitUntilCompleted()
		var out = [Float16](repeating: 0, count: w * h * 4)
		out.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
		return (w, h, out)
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
	};

	// One oversized triangle covering the viewport.
	vertex PSVOut psv_vertex(uint vid [[vertex_id]]) {
		float2 p = float2((vid << 1) & 2, vid & 2);
		PSVOut o;
		o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
		o.uv = float2(p.x, 1.0 - p.y);
		return o;
	}

	fragment float4 psv_fragment(PSVOut in [[stage_in]],
	                             texture2d<float> yTex [[texture(0)]],
	                             texture2d<float> cTex [[texture(1)]],
	                             constant PSVUniforms &u [[buffer(0)]]) {
		constexpr sampler s(filter::linear, address::clamp_to_edge);
		float y = yTex.sample(s, in.uv).r * u.yScale + u.yOffset;
		float2 c = cTex.sample(s, in.uv).rg * u.cScale + u.cOffset;
		float3 rgb = u.matrix * float3(y, c.x, c.y);
		// Output stays in the stream's transfer domain (PQ for HDR, BT.709 for SDR); the layer's
		// colorspace tells the compositor how to interpret it.
		return float4(saturate(rgb), 1.0);
	}
	"""
}

private let psvDecodeCallback: VTDecompressionOutputCallback = { refCon, frameRefCon, status, flags, image, pts, _ in
	guard let refCon else { return }
	let r = Unmanaged<MetalVideoRenderer>.fromOpaque(refCon).takeUnretainedValue()
	r.didDecode(status: status, flags: flags, image: image, pts: pts, submitted: UInt64(UInt(bitPattern: frameRefCon)))
}
