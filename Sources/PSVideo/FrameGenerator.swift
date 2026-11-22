import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import VideoToolbox

/// Frame generation for the Metal path: synthesises in-between pictures so content below the
/// display cadence plays evenly.
public enum VideoFrameGeneration: String, Sendable, CaseIterable, Codable {
	case off
	/// Content below 60 fps -> 60 fps. A 30 fps game arrives either as a 60 fps stream in which every
	/// second picture is a repeat (each repeat is replaced by a generated in-between picture) or as a
	/// 30 fps stream (a picture is generated between each pair). 60 fps content passes through with no
	/// added latency.
	case to60
	/// As `.to60`, and 60 fps content is doubled to 120 fps for a 120 Hz display.
	case to120
}

/// One picture handed to the display queue.
struct GeneratedEmit {
	enum Kind { case real, generated, fallbackRepeat }
	var buffer: CVPixelBuffer
	var arrival: UInt64
	var target: Double
	var interval: Double
	var kind: Kind
	/// Decode-order index of the stream picture this shows (generated: the slot it fills).
	var sourceIndex: Int
}

/// Runs on its own serial queue. Feed decoded frames in decode order with `submit`; pictures come out
/// through `emit` in presentation order with their target times (host seconds, before the renderer's
/// presentation lead).
final class FrameGenerator {
	struct Input {
		var buffer: CVPixelBuffer
		var arrival: UInt64
		var target: Double
		var interval: Double
		var skip: Bool
		/// Frames lost / repaired / decode error just before this one: never interpolate across it.
		var discontinuity: Bool
	}

	var emit: ((GeneratedEmit) -> Void)?
	private let queue = DispatchQueue(label: "PSVideo.framegen", qos: .userInteractive)
	private let setupQueue = DispatchQueue(label: "PSVideo.framegen-setup", qos: .userInitiated)
	private let device: MTLDevice
	private let commandQueue: MTLCommandQueue
	private let stats: StatsCollector
	private var textureCache: CVMetalTextureCache
	private let analyzePSO: MTLComputePipelineState
	private let dither8Y: MTLRenderPipelineState
	private let dither8C: MTLRenderPipelineState
	private let protectY: MTLRenderPipelineState
	private let protectC: MTLRenderPipelineState
	/// Static-overlay guard on/off (diagnostics compare both).
	var staticGuard = ProcessInfo.processInfo.environment["PSVIDEO_FG_NO_GUARD"] == nil

	// Settings (queue).
	private var mode: VideoFrameGeneration = .off

	// VT interpolator (queue). Created on setupQueue.
	private var processor: VTFrameProcessor?
	private var processorSize = (0, 0)
	private var settingUp = false
	/// Diagnostics asked for the interpolator while frame generation is off: keep the session.
	private var diagnosticHold = false
	private var pool8: CVPixelBufferPool?
	private var poolOut: CVPixelBufferPool?

	// Picture analysis.
	private struct Picture {
		var buffer: CVPixelBuffer
		var buffer8: CVPixelBuffer?
		var hist: [Float]
		var input: Input
		var index: Int
	}
	private var lastPicture: Picture?
	private var lastNew: Picture?
	private var index = 0

	// Cadence.
	private var history: [Bool] = [] // true = new picture
	enum Cadence: String { case native, fillRepeats, doubling }
	private var cadence: Cadence = .native
	private(set) var contentFPS: Double = 0

	// Latency hold for generation.
	private var extraDelay = 0.0
	private var procTimes = Ring(capacity: 64)
	private var procScratch = [Double](repeating: 0, count: 64)

	/// Output queue in presentation order. Real pictures are ready at once; an in-between slot waits for
	/// the next real picture, then for its interpolation, and falls back at its deadline. Pictures leave
	/// strictly from the head, so presentation order never inverts, whatever the arrival pattern.
	private final class Slot {
		let isGen: Bool
		var emit: GeneratedEmit?
		var done: Bool
		var prev: Picture?
		var next: Picture?
		var fallback: Input?
		var target: Double
		var interval: Double
		var index: Int
		var started = false
		init(isGen: Bool, emit: GeneratedEmit?, target: Double, interval: Double, index: Int) {
			self.isGen = isGen
			self.emit = emit
			self.done = !isGen
			self.target = target
			self.interval = interval
			self.index = index
		}
	}
	private var slots: [Slot] = []
	private var interpolating = false

	// Thresholds (8-bit luma code values; fractions of sampled pixels).
	let changedLevel: Float = 6       // |diff| above this counts as a changed pixel
	let repeatFraction: Float = 0.004 // fewer changed pixels than this: same picture (encoder refinement)
	let cutHistDistance: Float = 0.5  // L1 distance of normalised 32-bin histograms: scene cut

	// Counters.
	private var generated = 0, fallbacks = 0, cutsSkipped = 0
	private var genWindowStart = 0.0, genWindowCount = 0

	init?(device: MTLDevice, stats: StatsCollector) {
		self.device = device
		self.stats = stats
		guard let q = device.makeCommandQueue() else { return nil }
		commandQueue = q
		var cache: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
		textureCache = cache
		guard VTLowLatencyFrameInterpolationConfiguration.isSupported,
		      let lib = try? device.makeLibrary(source: Self.shaders, options: nil),
		      let f = lib.makeFunction(name: "psv_analyze"),
		      let a = try? device.makeComputePipelineState(function: f)
		else { return nil }
		analyzePSO = a
		func rp(_ frag: String, _ fmt: MTLPixelFormat) -> MTLRenderPipelineState? {
			let d = MTLRenderPipelineDescriptor()
			d.vertexFunction = lib.makeFunction(name: "psv_fg_vertex")
			d.fragmentFunction = lib.makeFunction(name: frag)
			d.colorAttachments[0].pixelFormat = fmt
			return try? device.makeRenderPipelineState(descriptor: d)
		}
		guard let y = rp("psv_dither_y", .r8Unorm), let c = rp("psv_dither_c", .rg8Unorm),
		      let py = rp("psv_protect_y", .r8Unorm), let pc = rp("psv_protect_c", .rg8Unorm) else { return nil }
		dither8Y = y
		dither8C = c
		protectY = py
		protectC = pc
	}

	// MARK: Control

	func setMode(_ m: VideoFrameGeneration) {
		queue.async {
			self.mode = m
			if m == .off {
				self.flushSlots()
				self.cadence = .native
				self.extraDelay = 0
				self.processor?.endSession()
				self.processor = nil
			}
			self.publish()
		}
	}

	func reset() {
		queue.async {
			self.flushSlots()
			self.lastPicture = nil
			self.lastNew = nil
			self.history.removeAll()
			self.cadence = .native
			self.extraDelay = 0
		}
	}

	private let debug = ProcessInfo.processInfo.environment["PSVIDEO_DEBUG_FG"] != nil
	private let depthLock = UnfairLock()
	private var depth = 0

	func submit(_ input: Input) {
		let d = depthLock.withLock { () -> Int in depth += 1; return depth }
		if debug && d > 2 { NSLog("[PSVideo fg] queue depth %d", d) }
		queue.async {
			let t0 = CACurrentMediaTime()
			self.process(input)
			self.depthLock.withLock { self.depth -= 1 }
			if self.debug { NSLog("[PSVideo fg] process %.2f ms (cadence %@)", (CACurrentMediaTime() - t0) * 1000, self.cadence.rawValue) }
		}
	}

	// MARK: Pipeline

	private func process(_ input: Input) {
		index += 1
		let idx = index
		let w = CVPixelBufferGetWidth(input.buffer), h = CVPixelBufferGetHeight(input.buffer)
		if mode != .off { ensureProcessor(w, h) }

		// 1. Analysis against the previous picture.
		let (changed, hist) = analyze(input.buffer, previous: lastPicture?.buffer)
		let isRepeat = lastPicture != nil && changed < repeatFraction && !input.discontinuity
		var pic = Picture(buffer: input.buffer, buffer8: nil, hist: hist, input: input, index: idx)

		// 2. Cadence.
		history.append(!isRepeat)
		if history.count > 30 { history.removeFirst(history.count - 30) }
		updateCadence(streamInterval: input.interval)

		// 3. Hold time while generating: one stream interval (wait for the next picture) + p95 processing + margin.
		let generating = cadence != .native && processor != nil
		let proc = procTimes.count > 4 ? procTimes.percentile(0.95, scratch: &procScratch) : 0.012
		let wanted = generating ? input.interval + proc + 0.003 : 0
		if wanted > extraDelay {
			extraDelay = wanted
		} else if wanted < extraDelay {
			extraDelay -= min(extraDelay - wanted, 0.10 * input.interval) // slightly shortened intervals, no jump
		}

		if input.skip {
			// Pacer catch-up: keep as reference, don't show.
			lastPicture = pic
			if !isRepeat { lastNew = pic }
			return
		}

		if CACurrentMediaTime() - lastPublish > 0.25 { publish() }

		// 4. Routing.
		if isRepeat {
			let lastSlotWaits = slots.last.map { $0.isGen && !$0.done && $0.next == nil } ?? false
			if lastSlotWaits, let w = slots.last {
				// Second repeat in a row (content below 30 fps): a 0.5-phase picture would be wrong for
				// either slot; show the pictures as they are.
				fallBack(w)
				appendReal(input, index: idx)
			} else if cadence == .fillRepeats && generating, let prev = lastNew {
				appendGen(prev: prev, fallback: input, target: input.target, interval: input.interval, index: idx)
			} else {
				appendReal(input, index: idx)
			}
			lastPicture = pic
			drain()
			return
		}

		// New picture. Needs an 8-bit copy for the interpolator.
		if generating { pic.buffer8 = to8bit(input.buffer) }
		let isCut = lastNew.map { histDistance($0.hist, hist) > cutHistDistance } ?? true
		if cadence == .doubling && generating, let prev = lastNew, prev.index == lastPicture?.index {
			// Gap between two consecutive new pictures (30 fps stream, or 60 -> 120).
			appendGen(prev: prev, fallback: nil, target: (prev.input.target + input.target) / 2,
			          interval: (input.target - prev.input.target) / 2, index: idx)
		}
		for slot in slots where slot.isGen && !slot.done && slot.next == nil {
			if isCut || input.discontinuity {
				if isCut { cutsSkipped += 1 }
				fallBack(slot) // never blend across a cut or a loss
			} else {
				slot.next = pic
			}
		}
		appendReal(input, index: idx)
		lastPicture = pic
		lastNew = pic
		kickInterpolation()
		drain()
	}

	private func appendReal(_ i: Input, index: Int) {
		let e = GeneratedEmit(buffer: i.buffer, arrival: i.arrival, target: i.target + extraDelay, interval: i.interval, kind: .real, sourceIndex: index)
		slots.append(Slot(isGen: false, emit: e, target: e.target, interval: i.interval, index: index))
	}

	private func appendGen(prev: Picture, fallback: Input?, target: Double, interval: Double, index: Int) {
		let slot = Slot(isGen: true, emit: nil, target: target + extraDelay, interval: interval, index: index)
		slot.prev = prev
		slot.fallback = fallback
		slots.append(slot)
		// Deadline: the in-between picture must reach the renderer ~3 ms before its target.
		let wait = slot.target - 0.003 - CACurrentMediaTime()
		queue.asyncAfter(deadline: .now() + max(0, wait)) { [weak self, weak slot] in
			guard let self, let slot, !slot.done else { return }
			self.fallBack(slot)
			self.drain()
		}
	}

	/// No in-between picture for this slot: show the repeat (fill) or nothing (doubling).
	private func fallBack(_ slot: Slot) {
		guard !slot.done else { return }
		slot.done = true
		fallbacks += 1
		if let r = slot.fallback {
			slot.emit = GeneratedEmit(buffer: r.buffer, arrival: r.arrival, target: slot.target, interval: slot.interval, kind: .fallbackRepeat, sourceIndex: slot.index)
		}
		publish()
	}

	private func drain() {
		while let head = slots.first, head.done {
			slots.removeFirst()
			if let e = head.emit { emit?(e) }
		}
	}

	private func flushSlots() {
		for s in slots where !s.done { fallBack(s) }
		drain()
	}

	private func kickInterpolation() {
		guard !interpolating,
		      let slot = slots.first(where: { $0.isGen && !$0.done && !$0.started && $0.next != nil }),
		      let prev = slot.prev?.buffer8, let next = slot.next?.buffer8
		else { return }
		slot.started = true
		interpolate(prev: prev, cur: next, slot: slot)
	}

	// MARK: Cadence

	private func updateCadence(streamInterval: Double) {
		let n = history.count
		guard n >= 12 else { cadence = .native; contentFPS = 1 / streamInterval; return }
		let recent = history.suffix(24)
		let newCount = recent.filter { $0 }.count
		contentFPS = Double(newCount) / Double(recent.count) / streamInterval
		// Isolated repeats (new, repeat, new) and the longest run of repeats.
		var isolated = 0, run = 0, maxRun = 0
		let arr = Array(recent)
		for i in 0..<arr.count {
			if !arr[i] { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
			if i > 0 && i < arr.count - 1 && !arr[i] && arr[i - 1] && arr[i + 1] { isolated += 1 }
		}
		let lowStream = streamInterval > 1.0 / 45 // a genuine 30 fps (or lower) stream
		let previous = cadence
		switch mode {
		case .off:
			cadence = .native
		case .to60, .to120:
			if lowStream && maxRun == 0 {
				cadence = .doubling
			} else if isolated >= 4 && maxRun <= 1 {
				cadence = .fillRepeats // ~30-59 fps content in a 60 fps stream
			} else if previous == .fillRepeats && maxRun <= 1 && isolated >= 2 {
				cadence = .fillRepeats // hysteresis
			} else if mode == .to120 && maxRun == 0 && history.suffix(12).allSatisfy({ $0 }) {
				cadence = .doubling // 60 fps content -> 120
			} else {
				cadence = .native // 60 fps content (to60), static picture, or below 30 fps
			}
		}
		if cadence != previous {
			NSLog("[PSVideo] frame generation: content %.0f fps, cadence %@ -> %@", contentFPS, previous.rawValue, cadence.rawValue)
			if cadence == .native { flushSlots() }
		}
	}

	private func histDistance(_ a: [Float], _ b: [Float]) -> Float {
		var d: Float = 0
		for i in 0..<min(a.count, b.count) { d += abs(a[i] - b[i]) }
		return d
	}

	// MARK: GPU work

	private func lumaTexture(_ pb: CVPixelBuffer) -> CVMetalTexture? {
		let tenBit = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
			|| CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
		var t: CVMetalTexture?
		CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil, tenBit ? .r16Unorm : .r8Unorm,
		                                          CVPixelBufferGetWidthOfPlane(pb, 0), CVPixelBufferGetHeightOfPlane(pb, 0), 0, &t)
		return t
	}

	/// Fraction of (1/4-resolution) luma samples that changed by more than `changedLevel` codes, and
	/// the normalised 32-bin luma histogram of `pb`.
	private func analyze(_ pb: CVPixelBuffer, previous: CVPixelBuffer?) -> (Float, [Float]) {
		guard let cur = lumaTexture(pb), let curT = CVMetalTextureGetTexture(cur),
		      let cmd = commandQueue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder(),
		      let buf = device.makeBuffer(length: 34 * 4, options: .storageModeShared)
		else { return (1, []) }
		memset(buf.contents(), 0, 34 * 4)
		let prev = previous.flatMap { lumaTexture($0) }
		let prevT = prev.flatMap { CVMetalTextureGetTexture($0) } ?? curT
		var params = SIMD2<Float>(changedLevel / 255, previous == nil ? 0 : 1)
		enc.setComputePipelineState(analyzePSO)
		enc.setTexture(curT, index: 0)
		enc.setTexture(prevT, index: 1)
		enc.setBuffer(buf, offset: 0, index: 0)
		enc.setBytes(&params, length: 8, index: 1)
		let gw = curT.width / 4, gh = curT.height / 4
		enc.dispatchThreads(MTLSize(width: gw, height: gh, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
		enc.endEncoding()
		cmd.commit()
		cmd.waitUntilCompleted()
		_ = (cur, prev)
		let p = buf.contents().bindMemory(to: UInt32.self, capacity: 34)
		let total = Float(gw * gh)
		let changed = Float(p[0]) / total
		let hist = (0..<32).map { Float(p[2 + $0]) / total }
		return (changed, hist)
	}

	/// 10-bit -> 8-bit 4:2:0 with triangular dither (the interpolator takes 8-bit only). 8-bit input is
	/// used as is.
	private func to8bit(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
		let fmt = CVPixelBufferGetPixelFormatType(pb)
		if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange { return pb }
		guard let pool8 else { return nil }
		var out: CVPixelBuffer?
		guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool8, &out) == kCVReturnSuccess, let o = out else { return nil }
		CVBufferPropagateAttachments(pb, o)
		func tex(_ b: CVPixelBuffer, _ plane: Int, _ f: MTLPixelFormat) -> CVMetalTexture? {
			var t: CVMetalTexture?
			CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, b, nil, f,
			                                          CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane), plane, &t)
			return t
		}
		guard let sy = tex(pb, 0, .r16Unorm), let sc = tex(pb, 1, .rg16Unorm), let dy = tex(o, 0, .r8Unorm), let dc = tex(o, 1, .rg8Unorm),
		      let cmd = commandQueue.makeCommandBuffer() else { return nil }
		// Fixed dither pattern: a static pixel dithers identically in every frame, so the
		// interpolator and the static-overlay guard see it as static.
		var seed: UInt32 = 0x9E3779B9
		for (src, dst, pso) in [(sy, dy, dither8Y), (sc, dc, dither8C)] {
			let pass = MTLRenderPassDescriptor()
			pass.colorAttachments[0].texture = CVMetalTextureGetTexture(dst)
			pass.colorAttachments[0].loadAction = .dontCare
			pass.colorAttachments[0].storeAction = .store
			guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return nil }
			enc.setRenderPipelineState(pso)
			enc.setFragmentTexture(CVMetalTextureGetTexture(src), index: 0)
			enc.setFragmentBytes(&seed, length: 4, index: 0)
			enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			enc.endEncoding()
		}
		cmd.commit()
		cmd.waitUntilCompleted()
		_ = (sy, sc, dy, dc)
		return o
	}

	/// Static-overlay guard: where the previous and next real pictures are identical in a 3x3
	/// neighbourhood (HUD, subtitles, minimap frame), take the real pixels instead of the interpolated
	/// ones, which drag static overlays along with the motion behind them. Returns a new buffer.
	private func protectStatic(prev: CVPixelBuffer, next: CVPixelBuffer, interp: CVPixelBuffer) -> CVPixelBuffer {
		guard staticGuard, let poolOut else { return interp }
		var out: CVPixelBuffer?
		guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &out) == kCVReturnSuccess, let o = out,
		      let cmd = commandQueue.makeCommandBuffer() else { return interp }
		CVBufferPropagateAttachments(interp, o)
		func tex(_ b: CVPixelBuffer, _ plane: Int, _ f: MTLPixelFormat) -> CVMetalTexture? {
			var t: CVMetalTexture?
			CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, b, nil, f,
			                                          CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane), plane, &t)
			return t
		}
		var keep: [CVMetalTexture] = []
		for (plane, fmt, pso) in [(0, MTLPixelFormat.r8Unorm, protectY), (1, .rg8Unorm, protectC)] {
			guard let a = tex(prev, plane, fmt), let b = tex(next, plane, fmt), let i = tex(interp, plane, fmt), let d = tex(o, plane, fmt) else { return interp }
			keep += [a, b, i, d]
			let pass = MTLRenderPassDescriptor()
			pass.colorAttachments[0].texture = CVMetalTextureGetTexture(d)
			pass.colorAttachments[0].loadAction = .dontCare
			pass.colorAttachments[0].storeAction = .store
			guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return interp }
			enc.setRenderPipelineState(pso)
			enc.setFragmentTexture(CVMetalTextureGetTexture(a), index: 0)
			enc.setFragmentTexture(CVMetalTextureGetTexture(b), index: 1)
			enc.setFragmentTexture(CVMetalTextureGetTexture(i), index: 2)
			enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
			enc.endEncoding()
		}
		cmd.commit()
		cmd.waitUntilCompleted()
		_ = keep
		return o
	}

	private func ensureProcessor(_ w: Int, _ h: Int) {
		if processor != nil && processorSize == (w, h) { return }
		guard !settingUp else { return }
		guard w <= 1920, h <= 1080, w * h <= 1920 * 1080 else { return } // processor limit
		settingUp = true
		processor?.endSession()
		processor = nil
		setupQueue.async { [weak self] in
			// Model loading takes ~0.6 s: never on the frame path.
			guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: w, frameHeight: h, numberOfInterpolatedFrames: 1) else {
				self?.queue.async { self?.settingUp = false }
				return
			}
			let p = VTFrameProcessor()
			do { try p.startSession(configuration: cfg) } catch {
				NSLog("[PSVideo] frame interpolation session failed: %@", "\(error)")
				self?.queue.async { self?.settingUp = false }
				return
			}
			func pool(_ attrs: [String: Any]) -> CVPixelBufferPool? {
				var a = attrs
				a[kCVPixelBufferWidthKey as String] = w
				a[kCVPixelBufferHeightKey as String] = h
				a[kCVPixelBufferPixelFormatTypeKey as String] = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
				a[kCVPixelBufferMetalCompatibilityKey as String] = true
				a[kCVPixelBufferIOSurfacePropertiesKey as String] = [String: Any]()
				var pl: CVPixelBufferPool?
				CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 6] as CFDictionary, a as CFDictionary, &pl)
				return pl
			}
			let p8 = pool(cfg.sourcePixelBufferAttributes), po = pool(cfg.destinationPixelBufferAttributes)
			self?.queue.async {
				guard let self else { return }
				self.settingUp = false
				guard self.mode != .off || self.diagnosticHold else { p.endSession(); return }
				self.processor = p
				self.processorSize = (w, h)
				self.pool8 = p8
				self.poolOut = po
				NSLog("[PSVideo] frame interpolation ready (%dx%d)", w, h)
			}
		}
	}

	private func interpolate(prev: CVPixelBuffer, cur: CVPixelBuffer, slot: Slot) {
		guard let proc = processor, let poolOut else { fallBack(slot); drain(); return }
		var dst: CVPixelBuffer?
		let t = slot.index
		guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &dst) == kCVReturnSuccess, let d = dst,
		      let fPrev = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: CMTime(value: CMTimeValue(2 * t), timescale: 120)),
		      let fCur = VTFrameProcessorFrame(buffer: cur, presentationTimeStamp: CMTime(value: CMTimeValue(2 * t + 2), timescale: 120)),
		      let fDst = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value: CMTimeValue(2 * t + 1), timescale: 120)),
		      let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: fCur, previousFrame: fPrev, interpolationPhase: [0.5], destinationFrames: [fDst])
		else { fallBack(slot); drain(); return }
		CVBufferPropagateAttachments(cur, d)
		interpolating = true
		let started = CACurrentMediaTime()
		proc.process(parameters: params) { [weak self] _, error in
			let ms = CACurrentMediaTime() - started
			self?.queue.async {
				guard let self else { return }
				self.interpolating = false
				self.procTimes.push(ms, limit: 64)
				self.stats.update { $0.frameGenerationTimeMs = ms * 1000 }
				if !slot.done {
					if let error {
						NSLog("[PSVideo] frame interpolation failed: %@", "\(error)")
						self.fallBack(slot)
					} else {
						let out = self.protectStatic(prev: prev, next: cur, interp: d)
						slot.emit = GeneratedEmit(buffer: out, arrival: slot.next?.input.arrival ?? 0, target: slot.target,
						                          interval: slot.interval, kind: .generated, sourceIndex: slot.index)
						slot.done = true
						self.generated += 1
						self.genWindowCount += 1
						self.publish()
					}
				}
				self.kickInterpolation()
				self.drain()
			}
		}
	}

	private var lastPublish = 0.0

	private func publish() {
		let now = CACurrentMediaTime()
		lastPublish = now
		if genWindowStart == 0 { genWindowStart = now }
		var genFPS: Double?
		if now - genWindowStart >= 1 {
			genFPS = Double(genWindowCount) / (now - genWindowStart)
			genWindowStart = now
			genWindowCount = 0
		}
		let (m, c, cf, g, fb, cut, extra) = (mode, cadence, contentFPS, generated, fallbacks, cutsSkipped, extraDelay)
		stats.update { s in
			s.frameGeneration = m
			s.frameGenerationState = c.rawValue
			s.contentFPS = cf
			s.framesGenerated = g
			s.frameGenerationFallbacks = fb
			s.frameGenerationCutsSkipped = cut
			s.frameGenerationAddedLatencyMs = extra * 1000
			if let genFPS { s.generatedFPS = genFPS }
		}
	}

	/// Diagnostics: interpolate the midpoint of two decoded pictures synchronously (any bit depth).
	func interpolateNow(prev: CVPixelBuffer, next: CVPixelBuffer) -> (CVPixelBuffer, Double)? {
		var result: (CVPixelBuffer, Double)?
		queue.sync {
			diagnosticHold = true
			ensureProcessor(CVPixelBufferGetWidth(prev), CVPixelBufferGetHeight(prev))
		}
		// Wait for the session (model load) if needed.
		for _ in 0..<300 where queue.sync(execute: { processor == nil }) { Thread.sleep(forTimeInterval: 0.01) }
		queue.sync {
			guard let proc = processor, let poolOut, let p8 = to8bit(prev), let n8 = to8bit(next) else { return }
			var dst: CVPixelBuffer?
			guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, poolOut, &dst) == kCVReturnSuccess, let d = dst,
			      let a = VTFrameProcessorFrame(buffer: p8, presentationTimeStamp: CMTime(value: 0, timescale: 120)),
			      let b = VTFrameProcessorFrame(buffer: n8, presentationTimeStamp: CMTime(value: 2, timescale: 120)),
			      let o = VTFrameProcessorFrame(buffer: d, presentationTimeStamp: CMTime(value: 1, timescale: 120)),
			      let params = VTLowLatencyFrameInterpolationParameters(sourceFrame: b, previousFrame: a, interpolationPhase: [0.5], destinationFrames: [o])
			else { return }
			CVBufferPropagateAttachments(next, d)
			let sem = DispatchSemaphore(value: 0)
			let t0 = CACurrentMediaTime()
			var ok = false
			proc.process(parameters: params) { _, e in ok = e == nil; sem.signal() }
			sem.wait()
			if ok { result = (protectStatic(prev: p8, next: n8, interp: d), (CACurrentMediaTime() - t0) * 1000) }
		}
		return result
	}

	/// Diagnostics: the analysis numbers for two pictures.
	func analyzeNow(_ pb: CVPixelBuffer, previous: CVPixelBuffer?) -> (changed: Float, hist: [Float]) {
		queue.sync { analyze(pb, previous: previous) }
	}

	func histogramDistance(_ a: [Float], _ b: [Float]) -> Float { histDistance(a, b) }

	static let shaders = """
	#include <metal_stdlib>
	using namespace metal;

	kernel void psv_analyze(texture2d<float, access::read> cur [[texture(0)]],
	                        texture2d<float, access::read> prev [[texture(1)]],
	                        device atomic_uint *out [[buffer(0)]],
	                        constant float2 &p [[buffer(1)]],
	                        uint2 gid [[thread_position_in_grid]]) {
		uint2 pos = gid * 4 + 1;
		if (pos.x >= cur.get_width() || pos.y >= cur.get_height()) return;
		float c = cur.read(pos).r;
		float d = abs(c - prev.read(pos).r);
		if (p.y > 0.5 && d > p.x) atomic_fetch_add_explicit(&out[0], 1u, memory_order_relaxed);
		uint bin = min(31u, uint(c * 32.0));
		atomic_fetch_add_explicit(&out[2 + bin], 1u, memory_order_relaxed);
	}

	struct FGOut { float4 position [[position]]; float2 uv; };
	vertex FGOut psv_fg_vertex(uint vid [[vertex_id]]) {
		float2 q = float2((vid << 1) & 2, vid & 2);
		FGOut o;
		o.position = float4(q * 2.0 - 1.0, 0.0, 1.0);
		o.uv = float2(q.x, 1.0 - q.y);
		return o;
	}

	float hash(uint2 p, uint s) {
		uint h = p.x * 1973u + p.y * 9277u + s * 26699u;
		h = (h ^ (h >> 13)) * 0x5bd1e995u;
		return float(h & 0xffffu) / 65535.0;
	}

	// 10-bit code (top bits of 16) -> 8-bit with triangular-PDF dither of +-1 LSB.
	fragment float psv_dither_y(FGOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant uint &seed [[buffer(0)]]) {
		constexpr sampler s(filter::nearest);
		uint2 p = uint2(in.position.xy);
		float v = src.sample(s, in.uv).r * (65535.0 / 256.0); // 10-bit code / 4
		float n = hash(p, seed) + hash(p, seed + 7u) - 1.0;
		return clamp(floor(v + 0.5 + n * 0.5), 0.0, 255.0) / 255.0;
	}

	// Max |prev - next| over a 3x3 neighbourhood below ~3 codes: static -> real pixel.
	fragment float psv_protect_y(FGOut in [[stage_in]], texture2d<float, access::read> a [[texture(0)]],
	                             texture2d<float, access::read> b [[texture(1)]], texture2d<float, access::read> i [[texture(2)]]) {
		int2 p = int2(in.position.xy);
		int2 mx = int2(a.get_width() - 1, a.get_height() - 1);
		float m = 0.0;
		for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
			uint2 q = uint2(clamp(p + int2(dx, dy), int2(0), mx));
			m = max(m, abs(a.read(q).r - b.read(q).r));
		}
		uint2 c = uint2(p);
		return m < 3.5 / 255.0 ? 0.5 * (a.read(c).r + b.read(c).r) : i.read(c).r;
	}

	fragment float2 psv_protect_c(FGOut in [[stage_in]], texture2d<float, access::read> a [[texture(0)]],
	                              texture2d<float, access::read> b [[texture(1)]], texture2d<float, access::read> i [[texture(2)]]) {
		int2 p = int2(in.position.xy);
		int2 mx = int2(a.get_width() - 1, a.get_height() - 1);
		float m = 0.0;
		for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
			uint2 q = uint2(clamp(p + int2(dx, dy), int2(0), mx));
			float2 d = abs(a.read(q).rg - b.read(q).rg);
			m = max(m, max(d.x, d.y));
		}
		uint2 c = uint2(p);
		return m < 3.5 / 255.0 ? 0.5 * (a.read(c).rg + b.read(c).rg) : i.read(c).rg;
	}

	fragment float2 psv_dither_c(FGOut in [[stage_in]], texture2d<float> src [[texture(0)]], constant uint &seed [[buffer(0)]]) {
		constexpr sampler s(filter::nearest);
		uint2 p = uint2(in.position.xy);
		float2 v = src.sample(s, in.uv).rg * (65535.0 / 256.0);
		float2 n = float2(hash(p, seed + 3u) + hash(p, seed + 11u) - 1.0, hash(p, seed + 5u) + hash(p, seed + 13u) - 1.0);
		return clamp(floor(v + 0.5 + n * 0.5), 0.0, 255.0) / 255.0;
	}
	"""
}
