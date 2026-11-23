import AppKit
import AVFoundation
import CoreMedia
import PSContracts

/// Path (a): compressed samples into `AVSampleBufferDisplayLayer.sampleBufferRenderer`, no control
/// timebase, every sample tagged DisplayImmediately, so each frame is shown as soon as it is decoded.
final class SampleBufferLayerRenderer: VideoRenderer, @unchecked Sendable {
	let mode = VideoDisplayMode.sampleBufferLayer
	let displayLayer: AVSampleBufferDisplayLayer
	private let renderer: AVSampleBufferVideoRenderer
	private let stats: StatsCollector

	private struct Flags {
		var needsKeyframe = true
		var decodeFailed = false
		var requiresFlush = false
		var lastError: String?
	}

	private let lock = UnfairLock()
	private var flags = Flags()
	private var observers: [NSObjectProtocol] = []
	private var metricsTimer: Timer?
	private struct Metrics {
		var total = 0, dropped = 0, corrupted = 0
		var time: CFTimeInterval = 0
		var delay: Double = 0
	}
	private var lastDelaySample: (total: Int, delay: Double)?
	// metricsLock: the layer's counters are cumulative for its lifetime, so each stream gets a baseline.
	private let metricsLock = UnfairLock()
	private var baseline = Metrics()
	private var lastSample: Metrics?

	/// Host-clock timebase (time == host time, rate 1): sample PTS are absolute host times.
	private let timebase: CMTimebase
	private var paced = false // lock
	/// Added to paced PTS so the layer has time to decode and composite; learned from the layer's
	/// accumulated frame delay (lock).
	private var lead = 0.004
	private var lastLeadChange = 0.0
	var presentedObserver: ((Double, Double) -> Void)?
	var tunables = Tunables()
	var trace: FrameTrace?
	let capture = PresentedFrameCapture()
	private var captureTimer: Timer?
	private var lastCaptured: ObjectIdentifier?

	/// Layer path: the layer composites internally; the closest available picture is the displayed pixel
	/// buffer (decoded, before the layer's own scaling). Polled at 120 Hz on the main thread.
	func startCapture(count: Int, directory: URL, hdr: Bool, completion: @escaping @Sendable ([URL]) -> Void) {
		capture.start(count: count, directory: directory) { [weak self] urls in
			onMain { self?.captureTimer?.invalidate(); self?.captureTimer = nil }
			completion(urls)
		}
		onMain { [weak self] in
			guard let self else { return }
			let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
				guard let self, let pb = self.renderer.displayedPixelBuffer() else { return }
				let id = ObjectIdentifier(pb)
				if id != self.lastCaptured {
					self.lastCaptured = id
					self.capture.captureBuffer(pb, kind: "real", hdr: hdr)
				}
			}
			RunLoop.main.add(t, forMode: .common)
			self.captureTimer = t
		}
	}

	var layer: CALayer { displayLayer }
	var needsKeyframe: Bool { lock.withLock { flags.needsKeyframe } }

	init(stats: StatsCollector) {
		self.stats = stats
		displayLayer = AVSampleBufferDisplayLayer()
		displayLayer.videoGravity = .resizeAspect
		displayLayer.backgroundColor = NSColor.black.cgColor
		displayLayer.preventsDisplaySleepDuringVideoPlayback = true
		renderer = displayLayer.sampleBufferRenderer
		var tb: CMTimebase?
		CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
		timebase = tb!
		CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
		CMTimebaseSetRate(timebase, rate: 1)

		let nc = NotificationCenter.default
		observers.append(nc.addObserver(forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: renderer, queue: nil) { [weak self] note in
			guard let self else { return }
			let err = note.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey] as? NSError
			self.lock.withLock {
				self.flags.decodeFailed = true
				self.flags.lastError = err.map { "\($0.domain) \($0.code)" }
			}
			self.stats.update { $0.decodeErrors += 1 }
		})
		observers.append(nc.addObserver(forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification, object: renderer, queue: nil) { [weak self] _ in
			guard let self else { return }
			if self.renderer.requiresFlushToResumeDecoding {
				self.lock.withLock { self.flags.requiresFlush = true }
			}
		})
		startMetricsTimer()
	}

	deinit {
		shutdown()
	}

	func shutdown() {
		for o in observers { NotificationCenter.default.removeObserver(o) }
		observers.removeAll()
		let timer = metricsTimer
		metricsTimer = nil
		onMain { timer?.invalidate() }
	}

	func configure(codec: VideoCodec, color: VideoColorInfo, formatDescription: CMVideoFormatDescription) {
		let hdr = color.isHDR
		onMain { [displayLayer] in
			// Let HDR samples use the display's full EDR headroom; SDR stays SDR.
			displayLayer.preferredDynamicRange = hdr ? .high : .standard
		}
	}

	/// The layer decodes and scales internally; there is no place for a scaling stage on this path.
	func setUpscaler(_ upscaler: VideoUpscaler) {
		stats.update { s in
			s.upscaler = upscaler
			s.activeUpscaler = .off
		}
	}

	func setOutputPixelSize(_ size: CGSize) {}

	func setFrameGeneration(_ mode: VideoFrameGeneration) {
		stats.update { s in
			s.frameGeneration = mode
			s.frameGenerationState = mode == .off ? "native" : "inactive (layer path)"
		}
	}

	func setPacing(_ mode: VideoPacingMode) {
		let on = mode == .adaptive
		onMain { [weak self] in
			guard let self else { return }
			// A control timebase and DisplayImmediately must not be combined (AVFoundation docs), so
			// the timebase is installed before paced samples flow and removed after they stop.
			if on {
				CMTimebaseSetTime(self.timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
				self.displayLayer.controlTimebase = self.timebase
				self.lock.withLock { self.paced = true }
			} else {
				self.lock.withLock { self.paced = false }
				self.displayLayer.controlTimebase = nil
			}
		}
	}

	/// Shallow copy (shares the data) with the display timing and attachments; the original sample
	/// (arrival PTS) belongs to the tap and is never mutated.
	private func displaySample(_ sample: CMSampleBuffer, schedule: FrameSchedule, paced: Bool) -> CMSampleBuffer {
		var timing = CMSampleTimingInfo(
			duration: CMSampleBufferGetDuration(sample),
			presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample),
			decodeTimeStamp: .invalid)
		let usePTS = paced && schedule.target != nil
		if usePTS, let t = schedule.target {
			timing.presentationTimeStamp = CMTime(seconds: t, preferredTimescale: 1_000_000_000)
		}
		var copy: CMSampleBuffer?
		guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
		      let copy else { return sample }
		if let attachments = CMSampleBufferGetSampleAttachmentsArray(copy, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
			let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
			let yes = Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
			if !usePTS {
				CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), yes)
			}
			if schedule.skip {
				CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DoNotDisplay).toOpaque(), yes)
			}
		}
		return copy
	}

	func submit(_ sample: CMSampleBuffer, isKeyframe: Bool, arrival: UInt64, schedule: FrameSchedule) -> SubmitResult {
		let (mustFlush, decodeFailed): (Bool, Bool) = lock.withLock {
			let f = flags.requiresFlush
			let d = flags.decodeFailed
			flags.requiresFlush = false
			flags.decodeFailed = false
			return (f, d)
		}
		if mustFlush || renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
			if let e = renderer.error { NSLog("[PSVideo] display layer failed: %@", e.localizedDescription) }
			renderer.flush()
			lock.withLock { flags.needsKeyframe = true }
			if !isKeyframe { return .rejected(needsKeyframe: true) }
		}

		let (paced, lead) = lock.withLock { (self.paced, self.lead) }
		var s = schedule
		if let t = s.target { s.target = t + lead }
		renderer.enqueue(displaySample(sample, schedule: s, paced: paced))
		if let tr = trace, schedule.traceID > 0 {
			let at = paced ? s.target : nil
			tr.update(schedule.traceID) { r in
				r.committed = CACurrentMediaTime()
				if let at { r.presentAt = at }
				r.shown = schedule.skip ? .skipped : .real
			}
		}
		stats.handedOff(ms: StatsCollector.ms(from: arrival, to: mach_absolute_time()))
		if isKeyframe { lock.withLock { flags.needsKeyframe = false } }

		// A decode failure reported since the previous frame: tell the core so the console repairs
		// the reference chain. The layer keeps its state, so no forced keyframe. Failures reported
		// before an IDR belong to frames the IDR has just made irrelevant, so they don't count against it.
		return decodeFailed && !isKeyframe ? .rejected(needsKeyframe: false) : .accepted
	}

	func reset() {
		renderer.flush(removingDisplayedImage: true, completionHandler: nil)
		lock.withLock { flags = Flags() }
		metricsLock.withLock { lastSample = nil }
		// Capture the layer's lifetime counters now (before the new stream's frames) as the baseline.
		renderer.loadVideoPerformanceMetrics { [weak self] m in
			guard let self, let m else { return }
			self.metricsLock.withLock {
				self.baseline = Metrics(total: m.totalNumberOfFrames, dropped: m.numberOfDroppedFrames, corrupted: m.numberOfCorruptedFrames)
			}
		}
	}

	func displayDidChange(screen: NSScreen?) {}

	func copyLastPixelBuffer() -> CVPixelBuffer? {
		renderer.displayedPixelBuffer()
	}

	private func adjustLead(frameDelay: Double, now: Double) {
		lock.withLock {
			guard paced else { return }
			if frameDelay > 0.001 {
				lead = min(tunables.values.layerLeadCapMs / 1000, lead + frameDelay) // bounded
				lastLeadChange = now
			} else if now - lastLeadChange > 3 {
				lead = max(0.002, lead - 0.0005)
				lastLeadChange = now
			}
		}
	}

	/// The layer decodes internally, so decoded / dropped counts come from its performance metrics.
	private func startMetricsTimer() {
		onMain { [weak self] in
			guard let self else { return }
			let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollMetrics() }
			RunLoop.main.add(t, forMode: .common)
			self.metricsTimer = t
		}
	}

	private func pollMetrics() {
		renderer.loadVideoPerformanceMetrics { [weak self] m in
			guard let self, let m else { return }
			let now = CACurrentMediaTime()
			var cur = Metrics(total: m.totalNumberOfFrames, dropped: m.numberOfDroppedFrames, corrupted: m.numberOfCorruptedFrames, time: now, delay: m.totalAccumulatedFrameDelay)
			// Average lateness against PTS since the last poll -> presentation lead feedback.
			var frameDelay: Double?
			self.metricsLock.withLock {
				if let l = self.lastDelaySample, cur.total > l.total {
					frameDelay = max(0, (cur.delay - l.delay) / Double(cur.total - l.total))
				}
				self.lastDelaySample = (cur.total, cur.delay)
			}
			if let d = frameDelay { self.adjustLead(frameDelay: d, now: now) }
			let result: (decoded: Int, dropped: Int, corrupted: Int, fps: Double?) = self.metricsLock.withLock {
				if cur.total < self.baseline.total { self.baseline = Metrics() } // counters were reset
				let base = self.baseline
				cur.total -= base.total
				cur.dropped -= base.dropped
				cur.corrupted -= base.corrupted
				let decoded = max(0, cur.total - cur.dropped - cur.corrupted)
				var fps: Double?
				if let last = self.lastSample, now - last.time >= 0.9 {
					let lastDecoded = max(0, last.total - last.dropped - last.corrupted)
					fps = max(0, Double(decoded - lastDecoded) / (now - last.time))
					self.lastSample = cur
				} else if self.lastSample == nil {
					self.lastSample = cur
				}
				return (decoded, cur.dropped, cur.corrupted, fps)
			}
			let leadMs = self.lock.withLock { self.lead } * 1000
			self.stats.update { s in
				s.presentationLeadMs = leadMs
				if let d = frameDelay { s.layerFrameDelayMs = d * 1000 }
				s.framesDecoded = result.decoded
				s.layerDroppedFrames = result.dropped
				s.layerCorruptedFrames = result.corrupted
				if let fps = result.fps {
					s.decodedFPS = fps
					s.presentedFPS = fps // the layer's displayed-frame rate (best available on this path)
				}
			}
		}
	}
}
