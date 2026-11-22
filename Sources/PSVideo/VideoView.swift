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

	public init(pipeline: VideoPipeline) {
		self.pipeline = pipeline
		super.init(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
		rootLayer.backgroundColor = NSColor.black.cgColor
		// Assign the layer before wantsLayer: layer-hosting, AppKit never draws into it.
		layer = rootLayer
		wantsLayer = true
		layerContentsRedrawPolicy = .never
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
		guard let window else { return }
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
	}

	private func screenDidChange() {
		viewDidChangeBackingProperties()
		pipeline.screenChanged(window?.screen)
	}

	deinit {
		if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
	}
}

/// Root layer: keeps the content layer aspect-fit inside its bounds.
final class VideoRootLayer: CALayer {
	private(set) var content: CALayer?
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
