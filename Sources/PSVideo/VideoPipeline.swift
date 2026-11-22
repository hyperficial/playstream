import AppKit
import CoreMedia
import Foundation
import PSContracts

/// Annex-B elementary stream from the protocol core -> CMSampleBuffers -> decode -> screen.
///
/// Create it on the main thread, hand it to the session as its `VideoStreamSink`, and show
/// `VideoView(pipeline:)` / `VideoPlayerView(pipeline:)` somewhere. The stream callbacks run on the
/// core's network thread and never wait on the main thread.
public final class VideoPipeline: VideoStreamSink {
	/// Asked for an IDR out of band when the decoder lost its state (fresh decoder, flush, session reset).
	public weak var keyframeRequester: KeyframeRequesting?
	/// Receives every compressed sample built (passthrough recording).
	public weak var encodedTap: EncodedVideoTap?

	/// Display path. Changing it (main thread) swaps the renderer immediately and asks for a keyframe.
	public var displayMode: VideoDisplayMode {
		get { rendererLock.withLock { renderer.mode } }
		set { setDisplayMode(newValue) }
	}

	/// Frame pacing. `.adaptive` (default) shows frames on a steady grid behind a small adaptive
	/// playout delay; `.off` shows each frame the moment it is decoded. Change on the main thread.
	public var pacingMode: VideoPacingMode {
		get { pacingLock.withLock { pacing.mode } }
		set { setPacingMode(newValue) }
	}

	/// Lower bound of the adaptive playout delay, ms. Default 16.7 (one frame at 60 fps): the delay a
	/// clean link settles at. Any thread, takes effect on the next frame.
	public var minimumPlayoutDelayMs: Double {
		get { pacingLock.withLock { pacing.minMs } }
		set { pacingLock.withLock { pacing.minMs = max(0, newValue); pacing.maxMs = max(pacing.maxMs, pacing.minMs) } }
	}

	/// Upper bound of the adaptive playout delay, ms. Default 50. Stalls longer than this are not
	/// hidden: the picture holds, then catches up (and skips frames if far behind). Raise it (e.g.
	/// 120) to ride out ~100 ms Wi-Fi stalls completely at the cost of that much latency.
	public var maximumPlayoutDelayMs: Double {
		get { pacingLock.withLock { pacing.maxMs } }
		set { pacingLock.withLock { pacing.maxMs = max(0, newValue); pacing.minMs = min(pacing.minMs, pacing.maxMs) } }
	}

	/// Upscaling of the picture to the display's pixel size. Main thread, takes effect on the next frame.
	/// Default `.off`. Only the `.metal` display path has a scaling stage: with `.sampleBufferLayer` the
	/// setting is remembered but inactive (`stats.activeUpscaler == .off`); switch `displayMode` to
	/// `.metal` to use it.
	public var upscaler: VideoUpscaler {
		get { upscalerSetting }
		set {
			dispatchPrecondition(condition: .onQueue(.main))
			upscalerSetting = newValue
			rendererLock.withLock { renderer }.setUpscaler(newValue)
		}
	}
	private var upscalerSetting: VideoUpscaler = .off

	/// Frame generation (main thread). Default `.off`. Needs `displayMode == .metal` and
	/// `pacingMode == .adaptive`; otherwise it is remembered but inactive (see `stats.frameGenerationState`).
	public var frameGeneration: VideoFrameGeneration {
		get { frameGenerationSetting }
		set {
			dispatchPrecondition(condition: .onQueue(.main))
			frameGenerationSetting = newValue
			rendererLock.withLock { renderer }.setFrameGeneration(newValue)
		}
	}
	private var frameGenerationSetting: VideoFrameGeneration = .off
	private var contentPixelSize: CGSize = .zero

	/// Live statistics; cheap value copy, safe from any thread.
	public var stats: VideoStats { collector.snapshot() }

	/// Colour tags of the current stream, nil before the stream header arrived.
	public var colorInfo: VideoColorInfo? { rendererLock.withLock { lastConfig?.color } }

	/// Called on the main thread when the video size or HDR state changes.
	public var onFormatChange: ((_ width: Int, _ height: Int, _ hdr: Bool) -> Void)?

	// MARK: Shared state (rendererLock)

	private let rendererLock = UnfairLock()
	private var renderer: VideoRenderer
	private var lastConfig: (codec: VideoCodec, color: VideoColorInfo, fd: CMVideoFormatDescription)?
	private weak var host: VideoView?

	// MARK: Stream-thread state (streamLock; the core serialises the callbacks, the lock only guards start/stop races)

	private let streamLock = UnfairLock()
	private var codec: VideoCodec = StreamProfile.ps5Max.codec
	private var frameDuration = CMTime(value: 1, timescale: 60)
	private var store = ParameterSetStore(hevc: true)
	private var formatDescription: CMVideoFormatDescription?
	private var nals: [NALUnitRange] = []
	private let factory = SampleFactory()
	private var lastKeyframeRequest: UInt64 = 0
	private var consecutiveRejects = 0
	private var streaming = false
	private var activity: NSObjectProtocol?

	private let pacer = FramePacer()
	private let debugSubmit = ProcessInfo.processInfo.environment["PSVIDEO_DEBUG_FG"] != nil
	private var lastCallEnd: UInt64 = 0
	private var lastPacerPublish: UInt64 = 0
	private var lateFrames = 0
	private var skippedFrames = 0

	private struct PacingSettings {
		var mode: VideoPacingMode
		var minMs = 1000.0 / 60
		var maxMs = 50.0
	}

	private let pacingLock = UnfairLock()
	private var pacing: PacingSettings

	let collector = StatsCollector()

	public init(displayMode: VideoDisplayMode = .sampleBufferLayer, pacingMode: VideoPacingMode = .adaptive) {
		nals.reserveCapacity(64)
		pacing = PacingSettings(mode: pacingMode)
		renderer = Self.makeRenderer(displayMode, stats: collector)
		renderer.setPacing(pacingMode)
		collector.update { $0.pacingMode = pacingMode }
		collector.reset(codec: nil, mode: displayMode)
		screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
			self?.screenChanged(self?.host?.window?.screen)
		}
	}

	private var screenObserver: NSObjectProtocol?

	deinit {
		if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
		renderer.shutdown()
		if let activity { ProcessInfo.processInfo.endActivity(activity) }
	}

	private static func makeRenderer(_ mode: VideoDisplayMode, stats: StatsCollector) -> VideoRenderer {
		switch mode {
		case .sampleBufferLayer:
			return SampleBufferLayerRenderer(stats: stats)
		case .metal:
			if let r = MetalVideoRenderer(stats: stats) { return r }
			NSLog("[PSVideo] Metal renderer unavailable, falling back to the sample buffer layer")
			return SampleBufferLayerRenderer(stats: stats)
		}
	}

	// MARK: VideoStreamSink

	public func videoStreamWillStart(profile: StreamProfile) {
		streamLock.withLock {
			codec = profile.codec
			frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, profile.fps)))
			store = ParameterSetStore(hevc: profile.codec.isHEVC)
			formatDescription = nil
			lastKeyframeRequest = 0
			consecutiveRejects = 0
			pacer.reset(fps: profile.fps)
			lastPacerPublish = 0
			lateFrames = 0
			skippedFrames = 0
			streaming = true
			if activity == nil {
				activity = ProcessInfo.processInfo.beginActivity(
					options: [.userInitiated, .idleDisplaySleepDisabled, .latencyCritical], reason: "PlayStream video")
			}
		}
		let r: VideoRenderer = rendererLock.withLock {
			lastConfig = nil
			return renderer
		}
		r.reset()
		collector.reset(codec: profile.codec, mode: r.mode)
		collector.update { $0.width = profile.width; $0.height = profile.height }
	}

	public func videoStreamDidReceive(accessUnit: UnsafeRawBufferPointer, framesLost: Int, frameRecovered: Bool) -> Bool {
		let arrival = mach_absolute_time()
		let r = streamLock.withLock { process(accessUnit, framesLost: framesLost, frameRecovered: frameRecovered, arrival: arrival) }
		if debugSubmit {
			let inside = StatsCollector.ms(from: arrival, to: mach_absolute_time())
			let gap = lastCallEnd == 0 ? 0 : StatsCollector.ms(from: lastCallEnd, to: arrival)
			if inside > 3 || gap > 30 { NSLog("[PSVideo] receive: %.1f ms inside, %.1f ms since previous call returned", inside, gap) }
			lastCallEnd = mach_absolute_time()
		}
		return r
	}

	public func videoStreamDidStop() {
		streamLock.withLock {
			streaming = false
			formatDescription = nil
			store.reset()
			if let a = activity {
				ProcessInfo.processInfo.endActivity(a)
				activity = nil
			}
		}
		rendererLock.withLock { renderer }.reset()
	}

	// MARK: Frame path (stream thread, streamLock held)

	private func process(_ buffer: UnsafeRawBufferPointer, framesLost: Int, frameRecovered: Bool, arrival: UInt64) -> Bool {
		guard let raw = buffer.baseAddress, buffer.count > 0 else { return false }
		let base = raw.assumingMemoryBound(to: UInt8.self)
		let hevc = codec.isHEVC
		AnnexB.scan(base, count: buffer.count, hevc: hevc, into: &nals)

		var hasVCL = false, hasPS = false, keyframe = false
		for n in nals {
			switch AnnexB.kind(of: n.type, hevc: hevc) {
			case .vcl:
				hasVCL = true
				if AnnexB.isKeyframe(type: n.type, hevc: hevc) { keyframe = true }
			case .parameterSet:
				hasPS = true
			default:
				break
			}
		}

		if hasPS && store.update(base: base, nals: nals) {
			rebuildFormatDescription()
		}

		if !hasVCL {
			// Stream header (parameter sets only), or nothing usable.
			if nals.isEmpty { NSLog("[PSVideo] buffer without start codes (%d bytes)", buffer.count) }
			return formatDescription != nil
		}

		collector.update { s in
			s.framesReceived += 1
			s.framesLostInNetwork += max(0, framesLost)
			if frameRecovered { s.framesRecovered += 1 }
			if keyframe { s.keyframesReceived += 1 }
		}

		guard let fd = formatDescription else {
			// No usable parameter sets: nothing can be decoded until a header + keyframe arrive.
			requestKeyframe(force: false)
			return reject(dropped: true)
		}

		let pts = CMClockMakeHostTimeFromSystemUnits(arrival)
		guard let sample = factory.makeSample(
			base: base, nals: nals, hevc: hevc, formatDescription: fd, pts: pts, duration: frameDuration, isKeyframe: keyframe)
		else {
			return reject(dropped: true)
		}

		encodedTap?.encodedVideoDidProduce(sampleBuffer: sample, isKeyframe: keyframe)

		// The pacer always runs (arrival jitter stats are useful with pacing off too); its schedule is
		// only used in adaptive mode.
		let settings = pacingLock.withLock { pacing }
		pacer.minDelay = settings.minMs / 1000
		pacer.maxDelay = settings.maxMs / 1000
		var schedule = pacer.schedule(arrival: hostSeconds(arrival), framesLost: framesLost)
		schedule.discontinuity = framesLost > 0 || frameRecovered
		if settings.mode == .adaptive {
			if schedule.late { lateFrames += 1 }
			if schedule.skip { skippedFrames += 1 }
		} else {
			schedule = FrameSchedule(target: nil, skip: false, late: false, interval: schedule.interval, discontinuity: schedule.discontinuity)
		}
		scheduleObserver?(hostSeconds(arrival), schedule.target ?? .nan, schedule.skip)
		publishPacing(settings.mode, now: arrival)

		let r = rendererLock.withLock { renderer }
		if r.needsKeyframe && !keyframe {
			// Our decoder has no reference state; a P-frame cannot be shown. Ask for an IDR.
			requestKeyframe(force: false)
			return reject(dropped: true)
		}

		let submitStart = mach_absolute_time()
		let result = r.submit(sample, isKeyframe: keyframe, arrival: arrival, schedule: schedule)
		if debugSubmit {
			let ms = StatsCollector.ms(from: submitStart, to: mach_absolute_time())
			if ms > 2 { NSLog("[PSVideo] submit blocked the stream thread %.1f ms", ms) }
		}
		switch result {
		case .accepted:
			consecutiveRejects = 0
			return true
		case .rejected(let needsKeyframe):
			consecutiveRejects += 1
			if needsKeyframe {
				requestKeyframe(force: true)
			} else if consecutiveRejects >= 6 {
				// The core's corrupt-frame reports have not repaired the picture within ~100 ms
				// (e.g. the console keeps referencing a frame we decoded badly): ask for an IDR.
				requestKeyframe(force: false)
			}
			return reject(dropped: needsKeyframe)
		}
	}

	private func publishPacing(_ mode: VideoPacingMode, now: UInt64) {
		guard lastPacerPublish == 0 || StatsCollector.ms(from: lastPacerPublish, to: now) >= 250 else { return }
		lastPacerPublish = now
		let a = pacer.arrivalStats()
		let paced = mode == .adaptive
		let delay = pacer.delay, target = pacer.targetDelay, fps = 1 / pacer.interval
		let late = lateFrames, skipped = skippedFrames
		collector.update { s in
			s.pacingMode = mode
			s.streamFPS = fps
			s.arrivalJitterAvgMs = a.jitterAvg * 1000
			s.arrivalJitterP95Ms = a.jitterP95 * 1000
			s.arrivalMaxGapMs = a.maxGap * 1000
			s.playoutDelayMs = paced ? delay * 1000 : 0
			s.playoutTargetDelayMs = paced ? target * 1000 : 0
			s.framesLate = late
			s.framesSkipped = skipped
		}
	}

	private func setPacingMode(_ mode: VideoPacingMode) {
		dispatchPrecondition(condition: .onQueue(.main))
		let changed: Bool = pacingLock.withLock {
			let c = pacing.mode != mode
			pacing.mode = mode
			return c
		}
		guard changed else { return }
		rendererLock.withLock { renderer }.setPacing(mode)
		collector.update { $0.pacingMode = mode }
	}

	private func reject(dropped: Bool) -> Bool {
		collector.update { s in
			s.framesRejected += 1
			if dropped {
				s.framesDropped += 1
				s.dropsAwaitingKeyframe += 1
			}
		}
		return false
	}

	private func requestKeyframe(force: Bool) {
		let now = mach_absolute_time()
		if !force && lastKeyframeRequest != 0 && StatsCollector.ms(from: lastKeyframeRequest, to: now) < 1000 { return }
		lastKeyframeRequest = now
		collector.update { $0.keyframeRequests += 1 }
		keyframeRequester?.requestKeyframe()
	}

	private func rebuildFormatDescription() {
		guard let (fd, color) = store.makeFormatDescription(codec: codec) else {
			if store.isComplete { formatDescription = nil }
			return
		}
		let old = formatDescription
		formatDescription = fd
		if let old, CMFormatDescriptionEqual(old, otherFormatDescription: fd) { return }

		let dims = CMVideoFormatDescriptionGetDimensions(fd)
		let r: VideoRenderer = rendererLock.withLock {
			lastConfig = (codec, color, fd)
			return renderer
		}
		r.configure(codec: codec, color: color, formatDescription: fd)
		collector.update { s in
			s.width = Int(dims.width)
			s.height = Int(dims.height)
			s.hdrActive = color.isHDR
			s.color = color
		}
		let w = Int(dims.width), h = Int(dims.height), hdr = color.isHDR
		onMain { [weak self] in
			guard let self else { return }
			self.host?.setVideoSize(CGSize(width: w, height: h))
			self.onFormatChange?(w, h, hdr)
		}
	}

	// MARK: Display mode / view (main thread)

	private func setDisplayMode(_ mode: VideoDisplayMode) {
		dispatchPrecondition(condition: .onQueue(.main))
		let current = rendererLock.withLock { renderer }
		guard current.mode != mode else { return }
		let new = Self.makeRenderer(mode, stats: collector)
		new.setPacing(pacingMode)
		new.setUpscaler(upscalerSetting)
		new.setFrameGeneration(frameGenerationSetting)
		new.setOutputPixelSize(contentPixelSize)
		if let o = outputOverride, let m = new as? MetalVideoRenderer { m.setOutputOverride(o) }
		new.presentedObserver = current.presentedObserver
		let config: (codec: VideoCodec, color: VideoColorInfo, fd: CMVideoFormatDescription)? = rendererLock.withLock {
			renderer = new
			return lastConfig
		}
		if let config { new.configure(codec: config.codec, color: config.color, formatDescription: config.fd) }
		current.reset()
		current.shutdown()
		collector.switchMode(new.mode)
		host?.setContentLayer(new.layer)
		new.displayDidChange(screen: host?.window?.screen)
		if streamLock.withLock({ streaming }) {
			streamLock.withLock { requestKeyframe(force: true) }
		}
	}

	func attach(_ view: VideoView) {
		dispatchPrecondition(condition: .onQueue(.main))
		host = view
		let (layer, fd) = rendererLock.withLock { (renderer.layer, lastConfig?.fd) }
		view.setContentLayer(layer)
		if let fd {
			let d = CMVideoFormatDescriptionGetDimensions(fd)
			view.setVideoSize(CGSize(width: Int(d.width), height: Int(d.height)))
		}
	}

	/// The view laid out the video rect: its size in pixels (main thread).
	func contentPixelSizeChanged(_ size: CGSize) {
		contentPixelSize = size
		rendererLock.withLock { renderer }.setOutputPixelSize(size)
	}

	private var outputOverride: CGSize?

	/// Diagnostics: render as if the on-screen video rect were `size` pixels (headless testing).
	@_spi(Diagnostics)
	public func setOutputPixelSizeOverride(_ size: CGSize?) {
		outputOverride = size
		(rendererLock.withLock { renderer } as? MetalVideoRenderer)?.setOutputOverride(size)
	}

	/// Diagnostics: the last decoded picture through the Metal path's conversion + `upscaler` at
	/// `outputSize`, rendered offscreen (rgba16Float, stream transfer domain), plus GPU time.
	@_spi(Diagnostics)
	public func renderLastFrameOffscreen(upscaler: VideoUpscaler, outputSize: CGSize?, hdrDomainLinear: Bool? = nil, readBack: Bool = true)
		-> (width: Int, height: Int, rgba: [Float16], gpuMs: Double, mode: VideoUpscaler)?
	{
		guard let r = rendererLock.withLock({ renderer }) as? MetalVideoRenderer,
		      let pb = r.copyLastPixelBuffer() else { return nil }
		let c = colorInfo
		return r.renderOffscreen(pb, matrix: c?.matrix ?? (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String), hdr: c?.isHDR ?? false,
		                         upscaler: upscaler, outputSize: outputSize,
		                         hdrDomain: hdrDomainLinear.map { $0 ? .linear : .pq }, readBack: readBack)
	}

	/// Diagnostics: interpolate the midpoint of two decoded pictures (frame generation's interpolator,
	/// including its 8-bit conversion). Returns the picture and the interpolation time in ms.
	@_spi(Diagnostics)
	public func interpolateOffscreen(prev: CVPixelBuffer, next: CVPixelBuffer) -> (CVPixelBuffer, Double)? {
		(rendererLock.withLock { renderer } as? MetalVideoRenderer)?.interpolateNow(prev: prev, next: next)
	}

	/// Diagnostics: frame generation's picture analysis (changed-pixel fraction, luma histogram).
	@_spi(Diagnostics)
	public func analyzeOffscreen(_ pb: CVPixelBuffer, previous: CVPixelBuffer?) -> (changed: Float, hist: [Float])? {
		(rendererLock.withLock { renderer } as? MetalVideoRenderer)?.analyzeNow(pb, previous: previous)
	}

	/// Diagnostics: any decoded picture through the Metal conversion (+ upscaler) offscreen.
	@_spi(Diagnostics)
	public func renderOffscreen(pixelBuffer pb: CVPixelBuffer, upscaler: VideoUpscaler = .off, outputSize: CGSize? = nil) -> (width: Int, height: Int, rgba: [Float16])? {
		guard let r = rendererLock.withLock({ renderer }) as? MetalVideoRenderer,
		      let o = r.renderOffscreen(pb, matrix: colorInfo?.matrix ?? (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String), hdr: colorInfo?.isHDR ?? false, upscaler: upscaler, outputSize: outputSize)
		else { return nil }
		return (o.width, o.height, o.rgba)
	}

	/// Diagnostics: each decoded picture (decoder thread), Metal path.
	@_spi(Diagnostics)
	public func setDecodedFrameObserver(_ f: ((CVPixelBuffer) -> Void)?) {
		(rendererLock.withLock { renderer } as? MetalVideoRenderer)?.decodedFrameObserver = f
	}

	/// Diagnostics: each picture frame generation hands to the display queue: kind (0 real, 1 generated,
	/// 2 fallback repeat), target time (host s), decode-order index of the slot.
	@_spi(Diagnostics)
	public func setDisplayObserver(_ f: ((Int, Double, Int) -> Void)?) {
		(rendererLock.withLock { renderer } as? MetalVideoRenderer)?.displayObserver = f.map { cb in { k, t, i in cb(k == .real ? 0 : k == .generated ? 1 : 2, t, i) } }
	}

	func screenChanged(_ screen: NSScreen?) {
		let headroom = Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1)
		collector.update { $0.edrHeadroom = headroom }
		rendererLock.withLock { renderer }.displayDidChange(screen: screen)
	}

	// MARK: Diagnostics

	/// The last decoded picture (CVPixelBuffer with its colour attachments). Diagnostic use.
	public func copyLastDecodedPixelBuffer() -> CVPixelBuffer? {
		rendererLock.withLock { renderer }.copyLastPixelBuffer()
	}

	/// Diagnostics: the pacer's decision for every frame (stream thread): arrival, target presentation
	/// time (host seconds, before the renderer's presentation lead), skipped.
	@_spi(Diagnostics)
	public var scheduleObserver: ((_ arrival: Double, _ target: Double, _ skip: Bool) -> Void)?

	/// Diagnostics: called (on an arbitrary thread) for each frame that reached the glass, with the
	/// presented time and the frame's arrival time (host seconds). Metal path with pacing only.
	@_spi(Diagnostics)
	public var presentedObserver: ((_ presentedTime: Double, _ arrival: Double) -> Void)? {
		get { rendererLock.withLock { renderer }.presentedObserver }
		set { rendererLock.withLock { renderer }.presentedObserver = newValue }
	}
}

// MARK: - Diagnostics SPI (harness / debugging only)

extension VideoPipeline {
	/// Renders the last decoded picture through the Metal path's shader into an offscreen rgba16Float
	/// texture (exactly what would be presented: PQ-encoded BT.2020 RGB for HDR, BT.709 R'G'B' for SDR).
	/// Only available in `.metal` mode.
	@_spi(Diagnostics)
	public func renderLastFrameOffscreen() -> (width: Int, height: Int, rgba: [Float16])? {
		guard let r = rendererLock.withLock({ renderer }) as? MetalVideoRenderer,
		      let pb = r.copyLastPixelBuffer(),
		      let o = r.renderOffscreen(pb, matrix: colorInfo?.matrix ?? (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String), hdr: colorInfo?.isHDR ?? false)
		else { return nil }
		return (o.width, o.height, o.rgba)
	}
}
