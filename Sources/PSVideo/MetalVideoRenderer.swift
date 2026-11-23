import AppKit
import AVFoundation
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
final class MetalVideoRenderer: VideoRenderer, @unchecked Sendable {
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
		var pending: Pending?
		/// Last picture that reached the glass (trace id, presented time), for its on-screen duration.
		var lastShown: (id: Int, t: Double)?
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

		// Presentation path (present.* tunables).
		/// Requested (or, untimed, commit) time of the last present of any kind, for the keep-alive.
		var lastIssue = 0.0
		/// Requested (or commit) time of the last stream picture (real or generated), not a re-present.
		var lastStreamIssue = 0.0
		/// Last picture handed to the display, re-presented by the keep-alive / overlay refresh.
		var lastRendered: (buffer: CVPixelBuffer, config: RenderConfig, interval: Double)?
		/// Mode 1: the last real picture presented as soon as possible (generated pictures are timed from it).
		var lastRealCommit: (source: Int, at: Double, target: Double)?
		/// Requested time of the last timed present (expected on-screen spacing without a grid).
		var lastRequested = 0.0
		/// Panel limits (NSScreen): shortest / longest refresh interval, update granularity (s).
		var screenMin = 1.0 / 120
		var screenMax = 1.0 / 24
		var screenGranularity = 0.0
		weak var screen: NSScreen?
		/// View layout in backing pixels, for the full-layer layout and the overlay position.
		var boundsPixelSize = CGSize.zero
		var contentRectPx = CGRect.zero
		var backingScale = 2.0
		var overlay: (texture: MTLTexture, originPt: CGPoint, sizePx: CGSize)?
		var decodeInFlight = 0
	}

	struct Pending {
		var buffer: CVPixelBuffer
		var arrival: UInt64
		var trace: Int
		var source = -1          // generator source index (mode 1 with frame generation)
		var target = 0.0
		var interval: Double?
	}

	enum RepeatReason { case keepAlive, overlay }

	struct PacedFrame {
		var buffer: CVPixelBuffer
		var arrival: UInt64
		var at: Double
		var interval: Double
		var refresh: Double
		var config: RenderConfig
		var generated = false
		var traceID = 0
		var shown = TraceRecord.Shown.real
		/// Mode 1 generated picture: drop it if a newer real picture was already presented.
		var anchorSource = -1
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
		var traceID = 0
	}


	private let lock = UnfairLock()
	private var shared = Shared()
	var presentedObserver: ((Double, Double) -> Void)?
	var trace: FrameTrace? {
		didSet { generator?.trace = trace }
	}
	let capture = PresentedFrameCapture()

	/// Starts a capture of the next `count` presented pictures (drawables are made readable meanwhile).
	func startCapture(count: Int, directory: URL, completion: @escaping @Sendable ([URL]) -> Void) {
		renderQueue.async { [weak self] in
			guard let self else { return }
			CATransaction.begin(); CATransaction.setDisableActions(true)
			self.metalLayer.framebufferOnly = false
			CATransaction.commit()
			self.capture.start(count: count, directory: directory) { [weak self] urls in
				self?.renderQueue.async {
					CATransaction.begin(); CATransaction.setDisableActions(true)
					self?.metalLayer.framebufferOnly = true
					CATransaction.commit()
				}
				completion(urls)
			}
		}
	}
	var tunables = Tunables() {
		didSet {
			scaler.tunables = tunables
			generator?.tunables = tunables
		}
	}

	private let debugPacing = ProcessInfo.processInfo.environment["PSVIDEO_DEBUG_PACING"] != nil

	var needsKeyframe: Bool { lock.withLock { shared.needsKeyframe } }

	init?(stats: StatsCollector) {
		guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
		var cache: CVMetalTextureCache?
		guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
		guard let scaler = FrameScaler(device: device) else { return nil }
		self.scaler = scaler
		self.compositor = PresentCompositor(device: device)
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
		readScreen(NSScreen.main)
	}

	/// Panel limits for the keep-alive and the stats (variable refresh: any interval in [min, max]).
	private func readScreen(_ screen: NSScreen?) {
		guard let sc = screen else { return }
		let mn = sc.minimumRefreshInterval, mx = sc.maximumRefreshInterval, g = sc.displayUpdateGranularity
		lock.withLock {
			shared.screen = sc
			if mn > 0 { shared.screenMin = mn }
			if mx > 0 { shared.screenMax = mx }
			shared.screenGranularity = g
		}
		stats.update { s in
			s.displayMinRefreshIntervalMs = mn > 0 ? mn * 1000 : nil
			s.displayMaxRefreshIntervalMs = mx > 0 ? mx * 1000 : nil
			s.displayUpdateGranularityMs = g > 0 ? g * 1000 : nil
		}
	}

	// MARK: Presentation modes

	var presentMode: Int { Int(tunables.values.presentMode.rounded()) }

	private var appliedLayer = (count: 3, sync: true, hud: false, mode: -1, full: false)
	private let compositor: PresentCompositor

	/// Render queue: applies drawable count / display sync / HUD tunables to the layer and notes mode
	/// changes. Cheap when nothing changed.
	private func applyPresentProperties() {
		let t = tunables.values
		let count = Int(t.presentDrawableCount.rounded())
		let sync = t.presentDisplaySync >= 0.5 && ProcessInfo.processInfo.environment["PSVIDEO_NO_VSYNC"] == nil
		let hud = t.presentHUD >= 0.5
		let mode = Int(t.presentMode.rounded())
		let full = t.presentFullLayer >= 0.5
		if count != appliedLayer.count || sync != appliedLayer.sync || hud != appliedLayer.hud {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			if count != appliedLayer.count { metalLayer.maximumDrawableCount = count }
			if sync != appliedLayer.sync { metalLayer.displaySyncEnabled = sync }
			if hud != appliedLayer.hud { metalLayer.developerHUDProperties = hud ? ["mode": "default", "logging": "default"] : nil }
			CATransaction.commit()
		}
		if mode != appliedLayer.mode || full != appliedLayer.full || hud != appliedLayer.hud {
			if mode != appliedLayer.mode && appliedLayer.mode >= 0 { trace?.event(.presentModeChange, value: Double(mode), limit: Double(appliedLayer.mode)) }
			if !full { compositor.releaseIntermediate() }
			stats.update { s in
				s.presentMode = mode
				s.presentFullLayer = full
				s.metalHUD = hud
			}
		}
		appliedLayer = (count, sync, hud, mode, full)
		updateDisplaySampler(t.presentSampleDisplayUpdates >= 0.5)
	}

	// MARK: Keep-alive

	private lazy var keepAliveTimer: DispatchSourceTimer = {
		let t = DispatchSource.makeTimerSource(flags: .strict, queue: renderQueue)
		t.setEventHandler { [weak self] in self?.keepAliveCheck() }
		t.resume()
		return t
	}()

	private func keepAliveThreshold() -> Double? {
		let t = tunables.values
		guard t.presentKeepAliveFraction > 0, Int(t.presentMode.rounded()) != 0 || t.presentKeepAliveAllModes >= 0.5 else { return nil }
		return t.presentKeepAliveFraction * lock.withLock { shared.screenMax }
	}

	/// Render queue, after every present: check again when the panel would next run out of time.
	private func scheduleKeepAlive() {
		guard let thr = keepAliveThreshold() else { return }
		let k = tunables.values.presentKeepAliveStreamIntervals
		let (issue, streamIssue, interval) = lock.withLock { (shared.lastIssue, shared.lastStreamIssue, shared.lastRendered?.interval ?? 0) }
		let wait = max(issue + thr, streamIssue + k * interval) - CACurrentMediaTime()
		keepAliveTimer.schedule(deadline: .now() + max(0.0005, wait), repeating: .never, leeway: .microseconds(300))
	}

	/// Render queue: nothing presented for `keepAliveFraction x maxRefreshInterval` -> show the last
	/// picture again (a stall or a paused stream neither drops the panel's rate nor flickers).
	private func keepAliveCheck() {
		guard let thr = keepAliveThreshold() else { return }
		let now = CACurrentMediaTime()
		let commitAhead = tunables.values.presentCommitAheadMs / 1000
		let k = tunables.values.presentKeepAliveStreamIntervals
		let (since, sinceStream, last, blocked, nextDue): (Double, Double, (buffer: CVPixelBuffer, config: RenderConfig, interval: Double)?, Bool, Double?) = lock.withLock {
			(now - shared.lastIssue, now - shared.lastStreamIssue, shared.lastRendered, shared.pending != nil || shared.renderScheduled, shared.pacedQueue.first?.at)
		}
		guard let last, !blocked else { return }
		if since < thr - 0.0003 || sinceStream < k * last.interval - 0.0003 {
			scheduleKeepAlive()
			return
		}
		// A picture is about to be presented anyway: a re-present now could push it back by a refresh.
		if let due = nextDue, due - now < lock.withLock({ shared.screenMin }) + commitAhead { return }
		trace?.event(.keepAlive, value: since * 1000)
		renderRepeat(last.buffer, config: last.config, reason: .keepAlive)
	}

	/// Re-presents a picture that was already shown (keep-alive, overlay change while idle). Not a stream frame.
	private func renderRepeat(_ pb: CVPixelBuffer, config: RenderConfig, reason: RepeatReason) {
		let plan = plan(for: pb)
		guard let drawable = metalLayer.nextDrawable() else { return }
		render(pb, arrival: 0, config: config, plan: plan, drawable: drawable, interval: nil, refresh: nil, presentAt: nil, repeatReason: reason)
	}

	// MARK: Display update cadence (NSScreen.lastDisplayUpdateTimestamp)

	private var displaySampler: Thread?
	private let samplerLock = UnfairLock()
	private var samplerRun = false

	private func updateDisplaySampler(_ on: Bool) {
		let running = samplerLock.withLock { samplerRun }
		guard on != running else { return }
		samplerLock.withLock { samplerRun = on }
		guard on else { return }
		let screen = lock.withLock { shared.screen } ?? NSScreen.main
		let th = Thread { [weak self] in
			var last = 0.0
			while let self, self.samplerLock.withLock({ self.samplerRun }) {
				if let t = screen?.lastDisplayUpdateTimestamp, t != last {
					if last > 0 && t > last { self.stats.displayUpdate(intervalMs: (t - last) * 1000) }
					last = t
				}
				usleep(500)
			}
		}
		th.qualityOfService = .utility
		th.name = "PSVideo.display-sampler"
		th.start()
		displaySampler = th
	}

	// MARK: Overlay and layout

	/// Main thread (any thread is fine): the overlay image as a BGRA premultiplied texture, its top-left
	/// in view points and its size in pixels; nil removes it.
	func setOverlay(texture: MTLTexture?, originPt: CGPoint, sizePx: CGSize) {
		let idle: Bool = lock.withLock {
			shared.overlay = texture.map { ($0, originPt, sizePx) }
			return CACurrentMediaTime() - shared.lastIssue > 0.05
		}
		stats.update { $0.overlayActive = texture != nil }
		// Nothing is being presented (paused, stalled): show the change now.
		if idle { renderQueue.async { [weak self] in self?.refreshForOverlay() } }
	}

	func moveOverlay(to originPt: CGPoint) {
		let idle: Bool = lock.withLock {
			shared.overlay?.originPt = originPt
			return shared.overlay != nil && CACurrentMediaTime() - shared.lastIssue > 0.05
		}
		if idle { renderQueue.async { [weak self] in self?.refreshForOverlay() } }
	}

	private func refreshForOverlay() {
		let (last, busy, since) = lock.withLock { (shared.lastRendered, shared.pending != nil || !shared.pacedQueue.isEmpty, CACurrentMediaTime() - shared.lastIssue) }
		guard let last, !busy, since > 0.05 else { return }
		renderRepeat(last.buffer, config: last.config, reason: .overlay)
	}

	/// The Metal device (for the pipeline's overlay texture uploads).
	var device_: MTLDevice { device }

	/// View layout in backing pixels (bounds, aspect-fit video rect) and the backing scale.
	func setLayout(boundsPx: CGSize, contentRectPx: CGRect, scale: Double) {
		lock.withLock {
			shared.boundsPixelSize = boundsPx
			shared.contentRectPx = contentRectPx
			shared.backingScale = scale
		}
	}

	deinit {
		shutdown()
	}

	func shutdown() {
		samplerLock.withLock { samplerRun = false }
		lock.withLock { shared.lastRendered = nil }
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
		stats.update { $0.presentationLeadMs = on ? self.presentLead(refresh) * 1000 : 0 }
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
		tunables.set("fg.maxAddedLatencyMs", min(300, max(0, seconds * 1000)))
	}

	private func makeGenerator() -> FrameGenerator? {
		let g = FrameGenerator(device: device, stats: stats)
		g?.trace = trace
		g?.emit = { [weak self] e in self?.enqueue(e) }
		g?.vsync = { [weak self] in
			guard let self else { return nil }
			return self.lock.withLock { self.shared.vsyncPeriod > 0 ? (self.shared.vsyncPhase, self.shared.vsyncPeriod) : nil }
		}
		g?.tunables = tunables
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
		let shown: TraceRecord.Shown = e.kind == .generated ? .generated : (e.kind == .fallbackRepeat ? .fallbackRepeat : .real)
		let mode = presentMode
		defer { displayObserver?(e.kind, e.target, e.sourceIndex) }
		if mode == 1 && e.presentAt == nil {
			// Lowest latency with extrapolation: the real picture goes out as soon as possible; the
			// generated one is timed from when that real picture was presented (true half interval).
			if e.kind == .real {
				setPending(Pending(buffer: e.buffer, arrival: e.arrival, trace: e.traceID, source: e.sourceIndex, target: e.target, interval: e.interval))
				return
			}
			renderQueue.async { [weak self] in
				guard let self else { return }
				let anchor = self.lock.withLock { self.shared.lastRealCommit }
				let at: Double
				if let a = anchor, a.source == e.sourceIndex {
					at = a.at + (e.target - a.target)
				} else if let a = anchor, a.source > e.sourceIndex {
					self.stats.drop(.superseded)
					return
				} else {
					at = CACurrentMediaTime() + e.interval
				}
				self.appendPaced(PacedFrame(buffer: e.buffer, arrival: e.arrival, at: at, interval: e.interval, refresh: refresh, config: config,
				                            generated: e.kind == .generated, traceID: e.traceID, shown: shown, anchorSource: e.sourceIndex))
			}
			return
		}
		// Mode 2 (and mode 1 with interpolation, whose real pictures must wait anyway): the slot's exact
		// time, not the vsync-aligned request. Mode 0: as before.
		let at = mode == 0 ? (e.presentAt ?? (e.target + presentLead(refresh))) : e.target
		appendPaced(PacedFrame(buffer: e.buffer, arrival: e.arrival, at: at, interval: e.interval,
		                       refresh: refresh, config: config, generated: e.kind == .generated, traceID: e.traceID, shown: shown))
	}

	/// Newest wins: replaces a picture that was not rendered yet and schedules a render.
	private func setPending(_ p: Pending) {
		let (schedule, superseded): (Bool, Bool) = lock.withLock {
			let sup = shared.pending != nil
			shared.pending = p
			shared.lastFrame = p.buffer
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

	// MARK: Paced presentation

	/// Presentation lead for paced frames without a slot clock: a frame is requested for its target;
	/// `present(atTime:)` shows it at the first vsync at or after that, so on average half a refresh
	/// later. No feedback loop. (Was +half a refresh: that only added latency, the commit slack was
	/// already ample: target - commit >= playout delay - decode - render ~ 11 ms.)
	func presentLead(_ refresh: Double) -> Double { tunables.values.renderPresentLeadRefreshes * refresh }

	/// How long before its requested time a paced frame is rendered and committed: two refreshes + 4 ms
	/// (~20.7 ms at 120 Hz) so the compositor always has more than it needs, while keeping only ~2
	/// drawables in flight. A frame decoded later than that is rendered immediately.
	func renderAhead(_ refresh: Double) -> Double {
		let t = tunables.values
		return t.renderAheadRefreshes * refresh + t.renderAheadExtraMs / 1000
	}


	private func appendPaced(_ f: PacedFrame) {
		let cap = Int(tunables.values.renderQueueCapacity)
		let (overflow, depth): (Bool, Int) = lock.withLock {
			let i = shared.pacedQueue.firstIndex { $0.at > f.at } ?? shared.pacedQueue.count
			shared.pacedQueue.insert(f, at: i)
			if shared.pacedQueue.count > cap {
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
		let mode = presentMode
		let commitAhead = tunables.values.presentCommitAheadMs / 1000
		let ahead: (Double) -> Double = { [unowned self] r in mode == 0 ? self.renderAhead(r) : commitAhead }
		while true {
			let now = CACurrentMediaTime()
			let (due, wakeAt): (PacedFrame?, Double?) = lock.withLock {
				guard let f = shared.pacedQueue.first else { return (nil, nil) }
				let start = f.at - ahead(f.refresh)
				if start <= now + 0.0005 {
					shared.pacedQueue.removeFirst()
					return (f, nil)
				}
				return (nil, start)
			}
			if let f = due {
				if f.anchorSource >= 0, let a = lock.withLock({ shared.lastRealCommit }), a.source > f.anchorSource {
					stats.drop(.superseded) // mode 1: a newer real picture is already on its way
					continue
				}
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
				render(f.buffer, arrival: f.arrival, config: f.config, plan: plan, drawable: drawable, interval: f.interval, refresh: f.refresh, presentAt: f.at, generated: f.generated,
				       traceID: f.traceID, shown: f.shown)
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

	func setSharpness(_ v: Double) {
		tunables.set("scaler.sharpness", min(1, max(0, v)))
	}

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
		/// Full-layer layout: the scaler draws into a video-rect sized texture, placed at `videoRect`.
		var fullLayer = false
		var videoRect = CGRect.zero
	}

	/// Picks the scaler and drawable size for this frame and sizes the layer's drawables accordingly.
	/// Called on the render queue before `nextDrawable()`.
	private func plan(for pb: CVPixelBuffer) -> Plan {
		let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
		let full = tunables.values.presentFullLayer >= 0.5
		let (requested, out, bounds): (VideoUpscaler, CGSize, CGSize) = lock.withLock {
			(shared.upscaler, shared.outputOverride ?? shared.outputPixelSize, shared.outputOverride ?? shared.boundsPixelSize)
		}
		var plan: Plan
		if full && bounds.width >= 16 && bounds.height >= 16 {
			// Native-resolution drawable covering the view; the video aspect-fit inside it.
			let fit = AVMakeRect(aspectRatio: CGSize(width: w, height: h), insideRect: CGRect(origin: .zero, size: bounds)).integral
			let mode = scaler.effectiveMode(requested, input: (w, h), output: (Int(fit.width), Int(fit.height)))
			plan = Plan(mode: mode, drawableSize: CGSize(width: bounds.width.rounded(), height: bounds.height.rounded()), fullLayer: true, videoRect: fit)
		} else {
			let ow = Int(out.width.rounded()), oh = Int(out.height.rounded())
			let mode = scaler.effectiveMode(requested, input: (w, h), output: (ow, oh))
			let size = mode == .off ? CGSize(width: w, height: h) : CGSize(width: ow, height: oh)
			plan = Plan(mode: mode, drawableSize: size)
		}
		let size = plan.drawableSize
		if metalLayer.drawableSize != size {
			CATransaction.begin()
			CATransaction.setDisableActions(true)
			metalLayer.drawableSize = size
			CATransaction.commit()
		}
		let scaledSize = plan.fullLayer ? plan.videoRect.size : size
		let changed: Bool = lock.withLock {
			let c = shared.activeUpscaler != plan.mode || shared.activeOutput != scaledSize
			shared.activeUpscaler = plan.mode
			shared.activeOutput = scaledSize
			return c
		}
		if changed {
			if plan.mode != .metalFXSpatial { scaler.releaseScaler() }
			stats.update { s in
				s.activeUpscaler = plan.mode
				s.upscaleInputWidth = w
				s.upscaleInputHeight = h
				s.upscaleOutputWidth = Int(scaledSize.width)
				s.upscaleOutputHeight = Int(scaledSize.height)
			}
		}
		return plan
	}

	/// Overlay rectangle in drawable pixels for this frame's layout.
	private func overlayRect(_ plan: Plan) -> PresentCompositor.Overlay? {
		let (ov, scale, cr) = lock.withLock { (shared.overlay, shared.backingScale, shared.contentRectPx) }
		guard let ov else { return nil }
		let ds = plan.drawableSize
		var r: CGRect
		if plan.fullLayer || cr.width < 1 || cr.height < 1 {
			r = CGRect(x: ov.originPt.x * scale, y: ov.originPt.y * scale, width: ov.sizePx.width, height: ov.sizePx.height)
		} else {
			// The drawable covers only the video rect (and may be smaller than it): map view pixels into it.
			let sx = ds.width / cr.width, sy = ds.height / cr.height
			r = CGRect(x: (ov.originPt.x * scale - cr.minX) * sx, y: (ov.originPt.y * scale - cr.minY) * sy,
			           width: ov.sizePx.width * sx, height: ov.sizePx.height * sy)
		}
		r = r.integral
		return PresentCompositor.Overlay(texture: ov.texture, rect: r)
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
				shared.schedules.append(Scheduled(arrival: key, target: schedule.target, skip: schedule.skip, interval: schedule.interval, discontinuity: schedule.discontinuity, grid: schedule.grid, jitter: schedule.jitter, pacerDelay: schedule.pacerDelay, traceID: schedule.traceID))
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
			let inFlight = lock.withLock { () -> Int in shared.decodeInFlight += 1; return shared.decodeInFlight }
			stats.decoderInFlight(inFlight)
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
			shared.lastRendered = nil
			shared.lastRealCommit = nil
			shared.lastRequested = 0
			shared.decodeInFlight = 0
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
		readScreen(screen)
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
		lock.withLock { shared.decodeInFlight = max(0, shared.decodeInFlight - 1) }
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
		if let tr = trace, let id = sched?.traceID { tr.update(id) { $0.submitted = hostSeconds(submitted); $0.decoded = hostSeconds(now) } }
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
				                            grid: sc.grid, jitter: sc.jitter, pacerDelay: sc.pacerDelay, traceID: sc.traceID)
			}
			if let input {
				gen.submit(input)
				return
			}
		}
		// Paced: render now, ask the compositor to put it on glass at its target time.
		// Mode 1 skips this (as soon as possible, newest wins); mode 2 uses the bare target.
		let mode = presentMode
		let leadRefreshes = mode == 0 ? tunables.values.renderPresentLeadRefreshes : 0
		let paced: (target: Double, interval: Double, skip: Bool, config: RenderConfig, refresh: Double)? = lock.withLock {
			guard shared.paced, mode != 1, let sc = sched, let target = sc.target else { return nil }
			let lead = leadRefreshes * shared.refresh
			shared.lastFrame = image
			shared.consecutiveErrors = 0
			return (target + lead, sc.interval, sc.skip, shared.config, shared.refresh)
		}
		if let p = paced {
			if p.skip { return } // catching up: decoded as a reference, not shown
			appendPaced(PacedFrame(buffer: image, arrival: arrival, at: p.target, interval: p.interval, refresh: p.refresh, config: p.config, traceID: sched?.traceID ?? 0))
			return
		}

		setPending(Pending(buffer: image, arrival: arrival, trace: sched?.traceID ?? 0, interval: sched?.interval))
	}

	// MARK: Rendering (render queue)

	private func renderPending() {
		let (item, config): (Pending?, RenderConfig) = lock.withLock {
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
		stats.pacedCommit(aheadMs: .infinity, queueDepth: 0, drawableWaitMs: (CACurrentMediaTime() - t0) * 1000)
		if debugPacing { NSLog("[PSVideo pacing] nextDrawable waited %.1f ms", (CACurrentMediaTime() - t0) * 1000) }
		guard let drawable = nd else {
			stats.drop(.noDrawable)
			return
		}
		if presentMode == 1 { stats.asapPresent() }
		render(item.buffer, arrival: item.arrival, config: config, plan: plan, drawable: drawable, interval: item.interval, refresh: nil, presentAt: nil, traceID: item.trace,
		       source: item.source, target: item.target)
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
	/// cadence statistics. `repeatReason` marks a re-present of a picture already shown (keep-alive,
	/// overlay refresh): presented untimed, kept out of the frame statistics and the trace.
	private func render(_ pb: CVPixelBuffer, arrival: UInt64, config: RenderConfig, plan: Plan, drawable: CAMetalDrawable, interval: Double?, refresh: Double?, presentAt: Double?, generated: Bool = false,
	                    traceID: Int = 0, shown: TraceRecord.Shown = .real, source: Int = -1, target: Double? = nil, repeatReason: RepeatReason? = nil) {
		applyPresentProperties()
		let scaleTarget: MTLTexture? = plan.fullLayer
			? compositor.intermediateTexture(width: Int(plan.videoRect.width), height: Int(plan.videoRect.height), format: drawable.texture.pixelFormat)
			: drawable.texture
		guard let scaleTarget, let (yTex, cTex, uniforms) = makeTextures(pb, matrix: config.matrix),
		      let y = CVMetalTextureGetTexture(yTex), let c = CVMetalTextureGetTexture(cTex),
		      let encoded = scaler.encode(queue: commandQueue, y: y, c: c, uniforms: uniforms, mode: plan.mode, hdr: config.hdr, target: scaleTarget),
		      let cmd = encoded.buffers.last
		else {
			stats.drop(.noDrawable)
			return
		}
		// Placement (full layer) and the in-frame overlay: the last pass before present.
		let t = tunables.values
		let overlay = overlayRect(plan)
		if plan.fullLayer || overlay != nil {
			compositor.encode(cmd: cmd, target: drawable.texture, video: plan.fullLayer ? scaleTarget : nil, videoRect: plan.videoRect, overlay: overlay,
			                  hdr: config.hdr, whiteNits: t.overlayHDRWhiteNits, opacity: t.overlayOpacity)
		}
		// GPU time per frame (all passes) and of the MetalFX pass alone.
		let stats = self.stats
		let first = encoded.buffers.first!
		if repeatReason == nil {
			if let sc = encoded.scalerBuffer {
				sc.addCompletedHandler { b in stats.scalerGPU(ms: (b.gpuEndTime - b.gpuStartTime) * 1000) }
			}
			cmd.addCompletedHandler { [first] b in
				stats.renderGPU(ms: (b.gpuEndTime - first.gpuStartTime) * 1000)
			}
		}

		if capture.active && repeatReason == nil {
			let kind = shown == .generated ? "generated" : (shown == .fallbackRepeat ? "fallback_repeat" : "real")
			capture.encodeCopy(device: device, cmd: cmd, texture: drawable.texture, kind: kind, traceID: traceID,
			                   presentAt: presentAt, colorSpace: metalLayer.colorspace)
		}
		let arrivalSeconds = hostSeconds(arrival)
		// Expected on-screen spacing to the previous picture: difference of requested times when both
		// were timed (exact without a grid), else the picture's own interval.
		let expected: Double? = repeatReason != nil ? nil : lock.withLock {
			defer { if let at = presentAt { shared.lastRequested = at } }
			if let at = presentAt, shared.lastRequested > 0, at - shared.lastRequested > 0.001, at - shared.lastRequested < 0.25 { return at - shared.lastRequested }
			return interval
		}
		if let reason = repeatReason {
			drawable.addPresentedHandler { d in
				if d.presentedTime <= 0 && reason == .keepAlive { stats.keepAlive(notShown: true) }
			}
		} else {
			drawable.addPresentedHandler { [weak self] d in
				let t = d.presentedTime
				guard t > 0 else {
					stats.presentNotShown()
					if traceID > 0 { self?.trace?.update(traceID) { $0.shown = .notShown } }
					return
				}
				stats.presented(at: t)
				if let self, let tr = self.trace {
					let r = refresh ?? (1.0 / 120)
					let prev: (id: Int, t: Double)? = self.lock.withLock {
						let p = self.shared.lastShown
						self.shared.lastShown = (traceID, t)
						return p
					}
					if let p = prev, p.id > 0 { tr.update(p.id) { $0.refreshes = ((t - p.t) / r).rounded() } }
					if traceID > 0 { tr.update(traceID) { $0.presented = t } }
				}
				// Arrival-to-glass is about real pictures (a generated one carries the next picture's arrival).
				if !generated {
					stats.onGlass(ms: (t - arrivalSeconds) * 1000)
					stats.arrivalToPresented(ms: (t - arrivalSeconds) * 1000)
				}
				guard let self else { return }
				self.presentedObserver?(t, arrivalSeconds)
				// Diagnostics only (never fed back): how far after the requested time the frame was shown.
				if let at = presentAt {
					stats.requestedToPresented(ms: (t - at) * 1000)
					if let refresh { stats.presentTiming(errorMs: (t - at) * 1000, refresh: refresh, generated: generated) }
				}
				let last: Double = self.lock.withLock {
					let l = self.shared.lastPresentedTime
					self.shared.lastPresentedTime = t
					return l
				}
				guard last > 0 else { return }
				let dt = t - last
				if let e = expected, dt < 0.5 { stats.presentedVRR(intervalMs: dt * 1000, expectedMs: e * 1000) }
				guard let interval, let refresh else { return }
				let expectedRefreshes = max(1, (interval / refresh).rounded())
				let actual = (dt / refresh).rounded()
				stats.presentedInterval(ms: dt * 1000, offCadence: actual != expectedRefreshes, refreshHz: 1 / refresh)
			}
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
		let now = CACurrentMediaTime()
		lock.withLock {
			shared.lastIssue = presentAt ?? now
			if repeatReason == nil { shared.lastStreamIssue = presentAt ?? now }
			if repeatReason == nil { shared.lastRendered = (pb, config, interval ?? shared.lastRendered?.interval ?? 1.0 / 60) }
			if source >= 0 && presentAt == nil { shared.lastRealCommit = (source, now, target ?? now) }
		}
		if repeatReason == .keepAlive { stats.keepAlive(issued: true) }
		scheduleKeepAlive()
		guard repeatReason == nil else { return }
		if traceID > 0, let tr = trace {
			tr.update(traceID) { r in
				r.committed = now
				if let at = presentAt { r.presentAt = at }
				if r.kind == .frame { r.shown = shown }
			}
		}
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
	func renderOffscreen(_ pb: CVPixelBuffer, matrix: String, hdr: Bool, upscaler: VideoUpscaler = .off, outputSize: CGSize? = nil, hdrDomain: MetalFXHDRDomain? = nil, readBack: Bool = true, sharpness: Float? = nil)
		-> (width: Int, height: Int, rgba: [Float16], gpuMs: Double, mode: VideoUpscaler)?
	{
		let w = Int(outputSize?.width ?? CGFloat(CVPixelBufferGetWidth(pb)))
		let h = Int(outputSize?.height ?? CGFloat(CVPixelBufferGetHeight(pb)))
		if offscreenScaler == nil { offscreenScaler = FrameScaler(device: device) }
		guard let fs = offscreenScaler else { return nil }
		if let d = hdrDomain, d != fs.hdrDomain { fs.hdrDomain = d; fs.releaseScaler() }
		if let s = sharpness { fs.sharpness = s }
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

