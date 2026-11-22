import AppKit
import CoreMedia
import CoreVideo
import os
import PSContracts
import QuartzCore

/// How decoded video reaches the screen.
public enum VideoDisplayMode: String, Sendable, CaseIterable, Codable {
	/// Compressed samples go straight into an `AVSampleBufferDisplayLayer` (system decode + composite),
	/// shown immediately with no timebase. Most robust path.
	case sampleBufferLayer
	/// `VTDecompressionSession` (hardware, real-time) into a Metal renderer on an EDR `CAMetalLayer`
	/// that always presents the newest decoded frame. Lowest latency, exposes decode timing.
	case metal
}

enum SubmitResult {
	case accepted
	/// The frame was not (or not correctly) consumed. `needsKeyframe`: decoder state is gone, only an
	/// IRAP/IDR frame can restart it.
	case rejected(needsKeyframe: Bool)
}

/// One display path. `submit` and `configure` are called on the stream thread (serialised by the
/// pipeline); `layer` is created on the main thread and only touched there by the view.
protocol VideoRenderer: AnyObject {
	var mode: VideoDisplayMode { get }
	var layer: CALayer { get }
	/// True until a keyframe has been accepted since creation / the last flush or decoder reset.
	var needsKeyframe: Bool { get }
	func configure(codec: VideoCodec, color: VideoColorInfo, formatDescription: CMVideoFormatDescription)
	func submit(_ sample: CMSampleBuffer, isKeyframe: Bool, arrival: UInt64) -> SubmitResult
	/// Stream ended or restarting: drop decoder state and the shown image.
	func reset()
	/// The hosting window moved to another screen or the screen's EDR capability changed (main thread).
	func displayDidChange(screen: NSScreen?)
	/// Last decoded picture, for diagnostics.
	func copyLastPixelBuffer() -> CVPixelBuffer?
	/// Called when the renderer is replaced or the pipeline goes away.
	func shutdown()
}

/// Small unfair lock usable for any state type.
final class UnfairLock: @unchecked Sendable {
	private let p: UnsafeMutablePointer<os_unfair_lock>
	init() {
		p = .allocate(capacity: 1)
		p.initialize(to: os_unfair_lock())
	}

	deinit {
		p.deinitialize(count: 1)
		p.deallocate()
	}

	@inline(__always)
	func withLock<T>(_ body: () throws -> T) rethrows -> T {
		os_unfair_lock_lock(p)
		defer { os_unfair_lock_unlock(p) }
		return try body()
	}
}

@inline(__always)
func onMain(_ body: @escaping () -> Void) {
	if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
}
