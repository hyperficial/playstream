import AppKit
import CoreMedia
import CoreVideo
import Metal
import PSContracts
import QuartzCore
import simd
import VideoToolbox

/// Path (b): hardware `VTDecompressionSession` (real-time, asynchronous, no temporal processing) into
/// a Metal YCbCr->RGB pass on a `CAMetalLayer`.
///
/// Pacing off: only the newest decoded picture is drawn, immediately; a frame superseded before the
/// render queue gets to it is dropped.
/// Pacing adaptive: each decoded frame is rendered at once and handed to the compositor with
/// `present(drawable, atTime: target + lead)`, so it reaches the glass on the vsync of its target
/// time. `lead` (the compositor's own latency, ~2.5 refreshes windowed) is learned from presented-time
/// feedback. (CAMetalDisplayLink was tried: its callbacks run 36-41 ms ahead of their presentation
/// time, i.e. ~2 frames more latency than the compositor itself needs.)
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
	/// Conversion + scaling for the render queue.
	private let scaler: FrameScaler
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
		var appliedConfig: RenderConfig?

		// Pacing.
		var paced = false
		var schedules: [Scheduled] = []
		var lastPresentedTime = 0.0
		var refresh = 1.0 / 120
		/// Paced frames waiting for the render queue. Bounded: if drawables come back slowly (window
		/// occluded, headless) old frames are dropped instead of holding decoder buffers, which would
		/// eventually block VTDecompressionSessionDecodeFrame on the network thread.
		/// Paced frames waiting to be rendered, sorted by requested time. Rendered just in time
		/// (`renderAhead` before their requested time) so only ~2 drawables are ever in flight.
		var pacedQueue: [PacedFrame] = []

		// Upscaling.
		var upscaler: VideoUpscaler = .off
		/// Pixel size of the aspect-fit video rect on screen (from the view), or a diagnostic override.
		var outputPixelSize: CGSize = .zero
		var outputOverride: CGSize?
		var activeUpscaler: VideoUpscaler = .off
		var activeOutput = CGSize.zero

		// Frame generation.
		var frameGeneration: VideoFrameGeneration = .off
		var errorSinceLastFrame = false
		/// Display vsync (from the view's display link): last vsync time and period.
		var vsyncPhase = 0.0
		var vsyncPeriod = 0.0
	}

	struct PacedFrame {
		var buffer: CVPixelBuffer
		var arrival: UInt64
		var at: Double
		var interval: Double
		var refresh: Double
		var config: RenderConfig
		var generated = false
	}

	struct Scheduled {
		var arrival: UInt64
		var target: Double?
		var skip: Bool
		var interval: Double
		var discontinuity = false
		var grid = 0.0
		var jitter = 0.0
		var pacerDelay = 0.0
	}


	private let lock = UnfairLock()
	private var shared = Shared()
	var presentedObserver: ((Double, Double) -> Void)?

	private let debugPacing = ProcessInfo.processInfo.environment["PSVIDEO_DEBUG_PACING"] != nil

	var needsKeyframe: Bool { lock.withLock { shared.needsKeyframe } }

	init?(stats: StatsCollector) {
		guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
		var cache: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
		guard let scaler = FrameScaler(device: device) else { return nil }
		self.scaler = scaler
		self.device = device
		self.commandQueue = queue
		self.textureCache = cache
		self.stats = stats

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
		let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 120)
		lock.withLock { shared.refresh = 1 / max(30, hz) }
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

	// MARK: Pacing

	func setPacing(_ mode: VideoPacingMode) {
		let on = mode == .adaptive
		if !on { generator?.reset() }
		let refresh: Double = lock.withLock {
			shared.paced = on
			shared.lastPresentedTime = 0
			return shared.refresh
		}
		stats.update { $0.presentationLeadMs = on ? Self.presentLead(refresh) * 1000 : 0 }
	}

	// MARK: Frame generation

	private var generator: FrameGenerator?
	/// Diagnostics: every decoded picture, and every picture handed to the display queue.
	var decodedFrameObserver: ((CVPixelBuffer) -> Void)?
	var displayObserver: ((GeneratedEmit.Kind, Double, Int) -> Void)?

	func setVsync(timestamp: Double, period: Double) {
		lock.withLock {
			shared.vsyncPhase = timestamp
			shared.vsyncPeriod = period
			if period > 0.002 { shared.refresh = period }
		}
	}

	func setFrameGenerationMethod(_ m: VideoFrameGenerationMethod) {
		frameGenerationMethod = m
		generator?.setMethod(m)
	}
	private var frameGenerationMethod: VideoFrameGenerationMethod = .extrapolate

	func setMaxAddedLatency(_ seconds: Double) {
		maxAddedLatency = seconds
		generator?.maxAddedLatency = seconds
	}
	private var maxAddedLatency = 0.045

	private func makeGenerator() -> FrameGenerator? {
		let g = FrameGenerator(device: device, stats: stats)
		g?.emit = { [weak self] e in self?.enqueue(e) }
		g?.vsync = { [weak self] in
			guard let self else { return nil }
			return self.lock.withLock { self.shared.vsyncPeriod > 0 ? (self.shared.vsyncPhase, self.shared.vsyncPeriod) : nil }
		}
		g?.maxAddedLatency = maxAddedLatency
		g?.setMethod(frameGenerationMethod)
		return g
	}

	func setFrameGeneration(_ m: VideoFrameGeneration) {
		if m != .off && generator == nil {
			generator = makeGenerator()
			if generator == nil { NSLog("[PSVideo] frame generation unavailable on this system") }
		}
		lock.withLock { shared.frameGeneration = generator == nil ? .off : m }
		generator?.setMode(m)
		if generator == nil { stats.update { $0.frameGeneration = m; $0.frameGenerationState = "unavailable" } }
	}

	/// A picture from the generator (real, generated or fallback) -> display queue.
	private func enqueue(_ e: GeneratedEmit) {
		let (refresh, config) = lock.withLock { (shared.refresh, shared.config) }
		appendPaced(PacedFrame(buffer: e.buffer, arrival: e.arrival, at: e.presentAt ?? (e.target + Self.presentLead(refresh)), interval: e.interval,
		                       refresh: refresh, config: config, generated: e.kind == .generated))
		displayObserver?(e.kind, e.target, e.sourceIndex)
	}

	// MARK: Paced presentation

	/// Presentation lead for paced frames without a slot clock: a frame is requested for its target;
	/// `present(atTime:)` shows it at the first vsync at or after that, so on average half a refresh
	/// later. No feedback loop. (Was +half a refresh: that only added latency, the commit slack was
	/// already ample: target - commit >= playout delay - decode - render ~ 11 ms.)
	static func presentLead(_ refresh: Double) -> Double { 0 }

	/// How long before its requested time a paced frame is rendered and committed: two refreshes + 4 ms
	/// (~20.7 ms at 120 Hz) so the compositor always has more than it needs, while keeping only ~2
	/// drawables in flight. A frame decoded later than that is rendered immediately.
	static func renderAhead(_ refresh: Double) -> Double { 2 * refresh + 0.004 }

	static let maxPacedQueue = 16

	private func appendPaced(_ f: PacedFrame) {
		let (overflow, depth): (Bool, Int) = lock.withLock {
			let i = shared.pacedQueue.firstIndex { $0.at > f.at } ?? shared.pacedQueue.count
			shared.pacedQueue.insert(f, at: i)
			if shared.pacedQueue.count > Self.maxPacedQueue {
				shared.pacedQueue.removeFirst()
				return (true, shared.pacedQueue.count)
			}
			return (false, shared.pacedQueue.count)
		}
		stats.pacedCommit(aheadMs: .infinity, queueDepth: depth, drawableWaitMs: 0)
		if overflow { stats.drop(.queueOverflow) }
		renderQueue.async { [weak self] in self?.servicePacedQueue() }
	}

	private lazy var pacedTimer: DispatchSourceTimer = {
		let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
		t.setEventHandler { [weak self] in self?.servicePacedQueue() }
		t.resume()
		return t
	}()

	/// Render queue: render every paced frame that is due, then sleep until the next one is.
	private func servicePacedQueue() {
		while true {
			let now = CACurrentMediaTime()
			let (due, wakeAt): (PacedFrame?, Double?) = lock.withLock {
				guard let f = shared.pacedQueue.first else { return (nil, nil) }
				let start = f.at - Self.renderAhead(f.refresh)
				if start <= now + 0.0005 {
					shared.pacedQueue.removeFirst()
					return (f, nil)
				}
				return (nil, start)
			}
			if let f = due {
				applyConfigIfNeeded(f.config, sample: f.buffer)
				let plan = plan(for: f.buffer)
				let t0 = CACurrentMediaTime()
				let drawable = metalLayer.nextDrawable()
				let waited = (CACurrentMediaTime() - t0) * 1000
				guard let drawable else {
					stats.drop(.noDrawable)
					continue
				}
				let depth = lock.withLock { shared.pacedQueue.count }
				stats.pacedCommit(aheadMs: (f.at - CACurrentMediaTime()) * 1000, queueDepth: depth, drawableWaitMs: waited)
				render(f.buffer, arrival: f.arrival, config: f.config, plan: plan, drawable: drawable, interval: f.interval, refresh: f.refresh, presentAt: f.at, generated: f.generated)
				continue
			}
			if let w = wakeAt {
				pacedTimer.schedule(deadline: .now() + max(0, w - now), repeating: .never, leeway: .microseconds(250))
			}
			return
		}
	}

	/// Diagnostics.
	func interpolateNow(prev: CVPixelBuffer, next: CVPixelBuffer) -> (CVPixelBuffer, Double)? {
		if generator == nil { generator = makeGenerator() }
		return generator?.interpolateNow(prev: prev, next: next)
	}

	func interpolateScaledNow(prev: CVPixelBuffer, next: CVPixelBuffer, width: Int, height: Int) -> (CVPixelBuffer, Double)? {
		if generator == nil { generator = makeGenerator() }
		return generator?.interpolateScaledNow(prev: prev, next: next, width: width, height: height)
	}

	func extrapolateNow(prev: CVPixelBuffer, cur: CVPixelBuffer, factor: Float, force: Bool) -> (CVPixelBuffer?, String, Double, Float, Float, Float) {
		if generator == nil { generator = makeGenerator() }
		guard let g = generator else { return (nil, "unavailable", 0, 0, 0, 0) }
		let r = g.extrapolateNow(prev: prev, cur: cur, factor: factor, force: force)
		return (r.picture, r.decision, r.ms, r.motion?.meanMotion ?? 0, r.motion?.fieldChange ?? 0, r.motion?.residualRatio ?? 0)
	}

	func analyzeNow(_ pb: CVPixelBuffer, previous: CVPixelBuffer?) -> (changed: Float, hist: [Float])? {
		if generator == nil { generator = makeGenerator() }
		return generator?.analyzeNow(pb, previous: previous)
	}

	// MARK: Upscaling

	func setUpscaler(_ u: VideoUpscaler) {
		lock.withLock { shared.upscaler = u }
		stats.update { $0.upscaler = u }
	}

	func setOutputPixelSize(_ size: CGSize) {
		lock.withLock { shared.outputPixelSize = size }
	}

	/// Diagnostics: pretend the video rect is this many pixels (headless runs have no screen).
	func setOutputOverride(_ size: CGSize?) {
		lock.withLock { shared.outputOverride = size }
	}

	private struct Plan {
		var mode: VideoUpscaler
		var drawableSize: CGSize
	}

	/// Picks the scaler and drawable size for this frame and sizes the layer's drawables accordingly.
	/// Called on the render queue before `nextDrawable()`.
	private func plan(for pb: CVPixelBuffer) -> Plan {
		let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
		let (requested, out): (VideoUpscaler, CGSize) = lock.withLock {
			(shared.upscaler, shared.outputOverride ?? shared.outputPixelSize)
		}
		let ow = Int(out.width.rounded()), oh = Int(out.height.rounded())
		let mode = scaler.effectiveMode(requested, input: (w, h), output: (ow, oh))
		let size = mode == .off ? CGSize(width: w, height: h) : CGSize(width: ow, height: oh)
		if metalLayer.drawableSize != size {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			metalLayer.drawableSize = size
			CATransaction.commit()
		}
		let changed: Bool = lock.withLock {
			let c = shared.activeUpscaler != mode || shared.activeOutput != size
			shared.activeUpscaler = mode
			shared.activeOutput = size
			return c
		}
		if changed {
			if mode != .metalFXSpatial { scaler.releaseScaler() }
			stats.update { s in
				s.activeUpscaler = mode
				s.upscaleInputWidth = w
				s.upscaleInputHeight = h
				s.upscaleOutputWidth = Int(size.width)
				s.upscaleOutputHeight = Int(size.height)
			}
		}
		return Plan(mode: mode, drawableSize: size)
	}

	// MARK: VideoRenderer

	func configure(codec: VideoCodec, color: VideoColorInfo, formatDescription: CMVideoFormatDescription) {
		lock.withLock {
			shared.config = RenderConfig(hdr: color.isHDR, matrix: color.matrix)
		}
	}

	func submit(_ sample: CMSampleBuffer, isKeyframe: Bool, arrival: UInt64, schedule: FrameSchedule) -> SubmitResult {
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
			let pts = CMSampleBufferGetPresentationTimeStamp(sample)
			let key = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : arrival
			lock.withLock {
				shared.schedules.append(Scheduled(arrival: key, target: schedule.target, skip: schedule.skip, interval: schedule.interval, discontinuity: schedule.discontinuity, grid: schedule.grid, jitter: schedule.jitter, pacerDelay: schedule.pacerDelay))
				if shared.schedules.count > 32 { shared.schedules.removeFirst(shared.schedules.count - 32) }
			}
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
		generator?.reset()
		decoderLock.withLock { teardownSession() }
		lock.withLock {
			shared.needsKeyframe = true
			shared.decodeFailed = false
			shared.consecutiveErrors = 0
			shared.pending = nil
			shared.lastFrame = nil
			shared.schedules.removeAll()
			shared.pacedQueue.removeAll()
			shared.errorSinceLastFrame = false
			shared.lastPresentedTime = 0
		}
		renderQueue.async { [weak self] in
			guard let self, let d = self.metalLayer.nextDrawable() else { return }
			self.clear(d)
		}
	}

	func displayDidChange(screen: NSScreen?) {
		// The PQ-tagged drawable plus HDR10 EDR metadata lets the system re-map for each display
		// (EDR on the XDR panel, tone mapped on an SDR monitor); force the layer config to be re-applied.
		let hz = Double(screen?.maximumFramesPerSecond ?? 0)
		lock.withLock {
			shared.appliedConfig = nil
			if hz > 0 { shared.refresh = 1 / hz }
		}
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
		let key = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : 0
		let sched: Scheduled? = lock.withLock {
			// Outputs come in decode order (no B-frames); drop entries of frames that never produced one.
			while let f = shared.schedules.first, f.arrival <= key {
				shared.schedules.removeFirst()
				if f.arrival == key { return f }
			}
			return nil
		}
		guard status == noErr, let image, !flags.contains(.frameDropped) else {
			// Reported to the core on the next submit; consecutive errors lead to a decoder reset there.
			lock.withLock {
				shared.decodeFailed = true
				shared.consecutiveErrors += 1
				shared.errorSinceLastFrame = true
			}
			stats.update { $0.decodeErrors += 1 }
			stats.drop(.decodeError)
			return
		}
		stats.frameDecoded(decodeMs: StatsCollector.ms(from: submitted, to: now))
		let arrival = pts.isValid ? CMClockConvertHostTimeToSystemUnits(pts) : submitted
		decodedFrameObserver?(image)
		// Frame generation (paced only): the generator decides what is shown when.
		if let gen = generator {
			let input: FrameGenerator.Input? = lock.withLock {
				guard shared.paced, shared.frameGeneration != .off, let sc = sched, let target = sc.target else { return nil }
				shared.lastFrame = image
				shared.consecutiveErrors = 0
				let disc = sc.discontinuity || shared.errorSinceLastFrame
				shared.errorSinceLastFrame = false
				return FrameGenerator.Input(buffer: image, arrival: arrival, target: target, interval: sc.interval, skip: sc.skip, discontinuity: disc,
				                            grid: sc.grid, jitter: sc.jitter, pacerDelay: sc.pacerDelay)
			}
			if let input {
				gen.submit(input)
				return
			}
		}
		// Paced: render now, ask the compositor to put it on glass at its target time.
		let paced: (target: Double, interval: Double, skip: Bool, config: RenderConfig, refresh: Double)? = lock.withLock {
			guard shared.paced, let sc = sched, let target = sc.target else { return nil }
			shared.lastFrame = image
			shared.consecutiveErrors = 0
			return (target + Self.presentLead(shared.refresh), sc.interval, sc.skip, shared.config, shared.refresh)
		}
		if let p = paced {
			if p.skip { return } // catching up: decoded as a reference, not shown
			appendPaced(PacedFrame(buffer: image, arrival: arrival, at: p.target, interval: p.interval, refresh: p.refresh, config: p.config))
			return
		}

		let (schedule, superseded): (Bool, Bool) = lock.withLock {
			let sup = shared.pending != nil
			shared.pending = (image, arrival)
			shared.lastFrame = image
			shared.consecutiveErrors = 0
			let sch = !shared.renderScheduled
			shared.renderScheduled = true
			return (sch, sup)
		}
		if superseded { stats.drop(.superseded) }
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
		applyConfigIfNeeded(config, sample: item.buffer)
		let plan = plan(for: item.buffer)
		let t0 = CACurrentMediaTime()
		let nd = metalLayer.nextDrawable()
		if debugPacing { NSLog("[PSVideo pacing] nextDrawable waited %.1f ms", (CACurrentMediaTime() - t0) * 1000) }
		guard let drawable = nd else {
			stats.drop(.noDrawable)
			return
		}
		render(item.buffer, arrival: item.arrival, config: config, plan: plan, drawable: drawable, interval: nil, refresh: nil, presentAt: nil)
	}

	private func applyConfigIfNeeded(_ config: RenderConfig, sample: CVPixelBuffer) {
		let needs = lock.withLock { shared.appliedConfig != config }
		guard needs else { return }
		applyLayerConfig(config, sample: sample)
		lock.withLock { shared.appliedConfig = config }
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
	}

	/// Draws `pb` into `drawable` and presents it. `interval`/`refresh` are set on the paced path for
	/// cadence statistics.
	private func render(_ pb: CVPixelBuffer, arrival: UInt64, config: RenderConfig, plan: Plan, drawable: CAMetalDrawable, interval: Double?, refresh: Double?, presentAt: Double?, generated: Bool = false) {
		guard let (yTex, cTex, uniforms) = makeTextures(pb, matrix: config.matrix),
		      let y = CVMetalTextureGetTexture(yTex), let c = CVMetalTextureGetTexture(cTex),
		      let encoded = scaler.encode(queue: commandQueue, y: y, c: c, uniforms: uniforms, mode: plan.mode, hdr: config.hdr, target: drawable.texture),
		      let cmd = encoded.buffers.last
		else {
			stats.drop(.noDrawable)
			return
		}
		// GPU time per frame (all passes) and of the MetalFX pass alone.
		let stats = self.stats
		let first = encoded.buffers.first!
		if let sc = encoded.scalerBuffer {
			sc.addCompletedHandler { b in stats.scalerGPU(ms: (b.gpuEndTime - b.gpuStartTime) * 1000) }
		}
		cmd.addCompletedHandler { [first] b in
			stats.renderGPU(ms: (b.gpuEndTime - first.gpuStartTime) * 1000)
		}

		let arrivalSeconds = hostSeconds(arrival)
		drawable.addPresentedHandler { [weak self] d in
			let t = d.presentedTime
			guard t > 0 else {
				stats.presentNotShown()
				return
			}
			// Arrival-to-glass is about real pictures (a generated one carries the next picture's arrival).
			if !generated { stats.onGlass(ms: (t - arrivalSeconds) * 1000) }
			guard let self else { return }
			self.presentedObserver?(t, arrivalSeconds)
			guard let interval, let refresh else { return }
			// Diagnostics only (never fed back): how far after the requested time the frame was shown.
			if let at = presentAt { stats.presentTiming(errorMs: (t - at) * 1000, refresh: refresh, generated: generated) }
			let last: Double = self.lock.withLock {
				let l = self.shared.lastPresentedTime
				self.shared.lastPresentedTime = t
				return l
			}
			guard last > 0 else { return }
			let dt = t - last
			let expected = max(1, (interval / refresh).rounded())
			let actual = (dt / refresh).rounded()
			stats.presentedInterval(ms: dt * 1000, offCadence: actual != expected, refreshHz: 1 / refresh)
		}
		if let at = presentAt {
			if debugPacing {
				let commit = CACurrentMediaTime()
				drawable.addPresentedHandler { d in
					NSLog("[PSVideo pacing] arrival->at %.1f commit->at %.1f at->shown %.1f commit->shown %.1f ms", (at - arrivalSeconds) * 1000, (at - commit) * 1000, (d.presentedTime - at) * 1000, (d.presentedTime - commit) * 1000)
				}
			}
			cmd.present(drawable, atTime: at)
		} else {
			cmd.present(drawable)
		}
		cmd.addCompletedHandler { _ in
			// Keep the CVMetalTextures (and so the IOSurfaces) alive until the GPU is done.
			_ = yTex
			_ = cTex
		}
		for b in encoded.buffers { b.commit() }
		stats.handedOff(ms: StatsCollector.ms(from: arrival, to: mach_absolute_time()))
	}

	private func makeTextures(_ pb: CVPixelBuffer, matrix: String) -> (CVMetalTexture, CVMetalTexture, FrameScaler.Uniforms)? {
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
	static func uniforms(tenBit: Bool, fullRange: Bool, matrix: String) -> FrameScaler.Uniforms {
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
		return FrameScaler.Uniforms(matrix: m, yScale: toCode / yRange, yOffset: -yLo / yRange, cScale: toCode / cRange, cOffset: -cMid / cRange)
	}

	private func clear(_ drawable: CAMetalDrawable) {
		guard let cmd = commandQueue.makeCommandBuffer() else { return }
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

	/// Renders `pb` through the same conversion + scaling passes into an offscreen rgba16Float texture
	/// of `outputSize` (video size if nil) and returns RGBA half floats (row-major), i.e. exactly what
	/// would be presented, plus the GPU time of the passes. Uses its own scaler instance.
	func renderOffscreen(_ pb: CVPixelBuffer, matrix: String, hdr: Bool, upscaler: VideoUpscaler = .off, outputSize: CGSize? = nil, hdrDomain: MetalFXHDRDomain? = nil, readBack: Bool = true)
		-> (width: Int, height: Int, rgba: [Float16], gpuMs: Double, mode: VideoUpscaler)?
	{
		let w = Int(outputSize?.width ?? CGFloat(CVPixelBufferGetWidth(pb)))
		let h = Int(outputSize?.height ?? CGFloat(CVPixelBufferGetHeight(pb)))
		if offscreenScaler == nil { offscreenScaler = FrameScaler(device: device) }
		guard let fs = offscreenScaler else { return nil }
		if let d = hdrDomain, d != fs.hdrDomain { fs.hdrDomain = d; fs.releaseScaler() }
		let key = "\(w)x\(h)"
		if offscreenTarget?.label != key {
			let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
			d.usage = [.renderTarget, .shaderRead]
			d.storageMode = .shared
			offscreenTarget = device.makeTexture(descriptor: d)
			offscreenTarget?.label = key
		}
		guard let target = offscreenTarget,
		      let (yT, cT, u) = makeTextures(pb, matrix: matrix),
		      let y = CVMetalTextureGetTexture(yT), let c = CVMetalTextureGetTexture(cT)
		else { return nil }
		let mode = upscaler == .off ? .off : fs.effectiveMode(upscaler, input: (y.width, y.height), output: (w, h))
		guard let enc = fs.encode(queue: commandQueue, y: y, c: c, uniforms: u, mode: mode, hdr: hdr, target: target) else { return nil }
		for b in enc.buffers { b.commit() }
		enc.buffers.last!.waitUntilCompleted()
		let gpu = (enc.buffers.last!.gpuEndTime - enc.buffers.first!.gpuStartTime) * 1000
		var out: [Float16] = []
		if readBack {
			out = [Float16](repeating: 0, count: w * h * 4)
			out.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
		}
		_ = (yT, cT)
		return (w, h, out, gpu, mode)
	}

	private var offscreenScaler: FrameScaler?
	private var offscreenTarget: MTLTexture?
}

private let psvDecodeCallback: VTDecompressionOutputCallback = { refCon, frameRefCon, status, flags, image, pts, _ in
	guard let refCon else { return }
	let r = Unmanaged<MetalVideoRenderer>.fromOpaque(refCon).takeUnretainedValue()
	r.didDecode(status: status, flags: flags, image: image, pts: pts, submitted: UInt64(UInt(bitPattern: frameRefCon)))
}

