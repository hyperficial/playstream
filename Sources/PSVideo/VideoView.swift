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

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
		screenObserver = nil
		refreshKeeper?.invalidate()
		refreshKeeper = nil
		guard let window else { return }
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

	@objc private func refreshTick(_ link: CADisplayLink) {}

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
		refreshKeeper?.invalidate()
	}
}

/// Root layer: keeps the content layer aspect-fit inside its bounds.
final class VideoRootLayer: CALayer {
	private(set) var content: CALayer?
	/// Pixel size of the video rect after layout (drives the Metal path's upscaler).
	var onContentPixelSize: ((CGSize) -> Void)?
	private var lastPixelSize = CGSize.zero
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
		if content is AVSampleBufferDisplayLayer || videoSize.width <= 0 || videoSize.height <= 0 {
			// The display layer letterboxes itself (videoGravity = resizeAspect).
			content.frame = bounds
		} else {
			content.frame = AVMakeRect(aspectRatio: videoSize, insideRect: bounds).integral
		}
		CATransaction.commit()
		let px = CGSize(width: (content.frame.width * contentsScale).rounded(), height: (content.frame.height * contentsScale).rounded())
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
