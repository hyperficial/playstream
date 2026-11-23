import AppKit
import AVFoundation
import SwiftUI

/// Layer-hosting view that shows a `VideoPipeline`: black background, video aspect-fit (letterbox /
/// pillarbox bars). Works in fullscreen and follows the window across displays. If several views are
/// created for one pipeline, the most recently created one shows the video.
public final class VideoView: NSView {
	public let pipeline: VideoPipeline
	private let rootLayer = VideoRootLayer()
	private var screenObserver: NSObjectProtocol?
	/// Asks for the screen's maximum refresh rate while the view is on screen, so ProMotion does not
	/// drop the panel below 120 Hz under the video (60 fps content then gets a steady 2-refresh cadence).
	private var refreshKeeper: CADisplayLink?

	public init(pipeline: VideoPipeline) {
		self.pipeline = pipeline
		super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
		rootLayer.backgroundColor = NSColor.black.cgColor
		// Assign the layer before wantsLayer: layer-hosting, AppKit never draws into it.
		layer = rootLayer
		wantsLayer = true
		layerContentsRedrawPolicy = .never
		rootLayer.onContentPixelSize = { [weak pipeline] size in pipeline?.contentPixelSizeChanged(size) }
		rootLayer.onLayout = { [weak pipeline] bounds, rect, scale in pipeline?.layoutChanged(boundsPx: bounds, contentRectPx: rect, scale: scale) }
		pipeline.attach(self)
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

	public override var isOpaque: Bool { true }
	public override var acceptsFirstResponder: Bool { false }

	func setContentLayer(_ layer: CALayer) {
		rootLayer.setContent(layer)
	}

	func setVideoSize(_ size: CGSize) {
		rootLayer.videoSize = size
	}

	/// Direct-to-display layout (`present.fullLayer`): the content layer covers the whole view and no
	/// PSVideo layer paints (the renderer draws the bars into its native-resolution drawable).
	func setFullLayer(_ on: Bool) {
		guard rootLayer.fullLayer != on else { return }
		rootLayer.fullLayer = on
		rootLayer.backgroundColor = on ? nil : NSColor.black.cgColor
		rootLayer.setNeedsLayout()
	}

	private var fullScreenObservers: [NSObjectProtocol] = []

	private func reportFullScreen() {
		pipeline.nativeFullScreenChanged(window.map { $0.styleMask.contains(.fullScreen) })
	}

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
		screenObserver = nil
		refreshKeeper?.invalidate()
		refreshKeeper = nil
		fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
		fullScreenObservers = []
		reportFullScreen()
		guard let window else { return }
		for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
			fullScreenObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.reportFullScreen() })
		}
		let link = displayLink(target: self, selector: #selector(refreshTick(_:)))
		link.add(to: .main, forMode: .common)
		refreshKeeper = link
		applyRefreshRange()
		screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
			self?.screenDidChange()
		}
		screenDidChange()
	}

	public override func viewDidChangeBackingProperties() {
		super.viewDidChangeBackingProperties()
		let scale = window?.backingScaleFactor ?? 2
		rootLayer.contentsScale = scale
		rootLayer.content?.contentsScale = scale
		rootLayer.setNeedsLayout()
	}

	@objc private func refreshTick(_ link: CADisplayLink) {
		// Vsync phase and period for frame generation's slot clock.
		pipeline.vsyncTick(timestamp: link.targetTimestamp, period: link.targetTimestamp - link.timestamp)
	}

	private func applyRefreshRange() {
		let hz = Float(window?.screen?.maximumFramesPerSecond ?? 120)
		refreshKeeper?.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
	}

	private func screenDidChange() {
		applyRefreshRange()
		viewDidChangeBackingProperties()
		pipeline.screenChanged(window?.screen)
	}

	deinit {
		if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
		fullScreenObservers.forEach { NotificationCenter.default.removeObserver($0) }
		refreshKeeper?.invalidate()
	}
}

/// Root layer: keeps the content layer aspect-fit inside its bounds.
final class VideoRootLayer: CALayer {
	private(set) var content: CALayer?
	/// Pixel size of the video rect after layout (drives the Metal path's upscaler).
	var onContentPixelSize: ((CGSize) -> Void)?
	/// Bounds and aspect-fit video rect in backing pixels (top-left origin), and the backing scale.
	var onLayout: ((CGSize, CGRect, Double) -> Void)?
	var fullLayer = false
	private var lastPixelSize = CGSize.zero
	private var lastLayout: (CGSize, CGRect, Double)?
	var videoSize: CGSize = .zero {
		didSet { if videoSize != oldValue { setNeedsLayout() } }
	}

	func setContent(_ layer: CALayer) {
		guard layer !== content else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		content?.removeFromSuperlayer()
		layer.removeFromSuperlayer()
		layer.contentsScale = contentsScale
		addSublayer(layer)
		content = layer
		CATransaction.commit()
		setNeedsLayout()
	}

	override func layoutSublayers() {
		super.layoutSublayers()
		// The content layer may have moved to a newer VideoView for the same pipeline.
		guard let content, content.superlayer === self else { return }
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		let fit: CGRect
		if content is AVSampleBufferDisplayLayer || videoSize.width <= 0 || videoSize.height <= 0 {
			// The display layer letterboxes itself (videoGravity = resizeAspect).
			fit = bounds
			content.frame = bounds
		} else {
			fit = AVMakeRect(aspectRatio: videoSize, insideRect: bounds).integral
			// Full layer: the Metal layer covers everything and draws the bars itself.
			content.frame = fullLayer ? bounds : fit
		}
		CATransaction.commit()
		let sc = contentsScale
		let boundsPx = CGSize(width: (bounds.width * sc).rounded(), height: (bounds.height * sc).rounded())
		// Top-left origin (the layer tree here is not flipped: y grows upwards).
		let rectPx = CGRect(x: (fit.minX - bounds.minX) * sc, y: (bounds.maxY - fit.maxY) * sc, width: fit.width * sc, height: fit.height * sc).integral
		if lastLayout.map({ $0.0 != boundsPx || $0.1 != rectPx || $0.2 != Double(sc) }) ?? true {
			lastLayout = (boundsPx, rectPx, Double(sc))
			onLayout?(boundsPx, rectPx, Double(sc))
		}
		let px = CGSize(width: (fit.width * contentsScale).rounded(), height: (fit.height * contentsScale).rounded())
		if px != lastPixelSize {
			lastPixelSize = px
			onContentPixelSize?(px)
		}
	}

	override func action(forKey event: String) -> CAAction? { nil }
}

/// SwiftUI wrapper. `VideoPlayerView(pipeline: pipeline).ignoresSafeArea()`
public struct VideoPlayerView: NSViewRepresentable {
	public let pipeline: VideoPipeline

	public init(pipeline: VideoPipeline) {
		self.pipeline = pipeline
	}

	public func makeNSView(context: Context) -> VideoView {
		VideoView(pipeline: pipeline)
	}

	public func updateNSView(_ nsView: VideoView, context: Context) {}
}
