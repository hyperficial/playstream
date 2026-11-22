import AVFoundation
import Combine
import CoreMedia
import Foundation
import os
import PSContracts

/// Records the stream without re-encoding: the console's compressed video samples are written
/// straight into a fragmented QuickTime movie next to the (AAC or lossless) audio.
///
/// Wiring (all from the session / pipeline setup code):
///
///     let recorder = StreamRecorder()
///     recorder.keyframeRequester = session          // KeyframeRequesting
///     videoPipeline.encodedVideoTap = recorder      // EncodedVideoTap
///     audioPipeline.pcmTap = recorder               // PCMAudioTap
///     recorder.start()                              // main thread, any time while streaming
///     recorder.stop { urls in ... }                 // main thread; also call when the session ends
///
/// The tap callbacks only copy and enqueue; all writer work happens on a private serial queue.
/// While not recording they cost one uncontended lock acquisition.
public final class StreamRecorder: ObservableObject, EncodedVideoTap, PCMAudioTap {
	// MARK: UI state (main thread)

	@Published public private(set) var state: State = .idle
	/// Recorded media time across all segments of the current recording.
	@Published public private(set) var elapsed: TimeInterval = 0
	@Published public private(set) var bytesWritten: Int64 = 0
	/// The file currently being written, or the last one written.
	@Published public private(set) var outputURL: URL?
	/// Files finished by the current (or last) recording, in order. More than one means the video format changed.
	@Published public private(set) var finishedURLs: [URL] = []
	@Published public private(set) var stats = Stats()

	/// Asked for a keyframe at start and whenever a resync is needed. Weak; set it to the session.
	public weak var keyframeRequester: KeyframeRequesting?
	/// Defaults used by `start()`. Changing it affects the next recording.
	public var options: Options

	public var isRecording: Bool { state.isBusy }

	public init(options: Options = Options(), keyframeRequester: KeyframeRequesting? = nil) {
		self.options = options
		self.keyframeRequester = keyframeRequester
	}

	deinit {
		let seg = segment
		let q = queue
		timer?.cancel()
		guard let seg else { return }
		q.async { seg.finish(at: nil, timeout: 5, droppedOnTimeout: { _, _ in }, completion: { _, _ in }) }
	}

	// MARK: Control

	private enum Phase { case idle, active, finishing }
	private let phase = OSAllocatedUnfairLock(initialState: Phase.idle)
	private let queue = DispatchQueue(label: "playstream.recorder", qos: .userInitiated)

	/// Starts a recording. Returns false if one is already running (or still finishing).
	/// Samples are discarded until the next keyframe, which is requested from `keyframeRequester`.
	@discardableResult
	public func start(directory: URL? = nil, audio: AudioMode? = nil) -> Bool {
		var opts = options
		if let directory { opts.directory = directory }
		if let audio { opts.audio = audio }
		let ok = phase.withLock { p -> Bool in
			guard p == .idle else { return false }
			// Enqueue the begin block before the taps can see `.active`, so it runs before any sample.
			queue.async { [self] in begin(opts) }
			p = .active
			return true
		}
		if ok { onMain { [self] in resetPublished(); state = .waitingForKeyframe } }
		return ok
	}

	/// Finalises the file(s) asynchronously. `completion` runs on the main thread with the finished
	/// file URLs (empty if nothing was written, e.g. stopped before the first keyframe).
	public func stop(completion: (([URL]) -> Void)? = nil) {
		let wasActive = phase.withLock { p -> Bool in
			guard p == .active else { return false }
			p = .finishing
			return true
		}
		guard wasActive else {
			if let completion { DispatchQueue.main.async { completion([]) } }
			return
		}
		onMain { [self] in if state.isBusy { state = .finishing } }
		queue.async { [self] in finishSession(completion) }
	}

	/// Async form of `stop(completion:)`.
	public func stop() async -> [URL] {
		await withCheckedContinuation { c in stop { c.resume(returning: $0) } }
	}

	/// Call when the stream is gone (the session ended or dropped). Same as `stop`.
	public func sessionDidEnd() { stop() }

	/// Tell the recorder frames were lost on the network (`framesLost > 0` in the video sink). It then
	/// discards samples until the next keyframe and requests one, so the file never contains broken
	/// references. Optional: a long timestamp gap triggers the same thing (`Options.lossGapThreshold`).
	public func noteVideoLoss() {
		guard phase.withLock({ $0 == .active }) else { return }
		queue.async { [self] in
			guard sessionOpen, segment != nil, !awaitingKeyframe else { return }
			beginResync()
		}
	}

	// MARK: Taps (network threads)

	public func encodedVideoDidProduce(sampleBuffer: CMSampleBuffer, isKeyframe: Bool) {
		guard phase.withLock({ $0 == .active }) else { return }
		queue.async { [self] in handleVideo(sampleBuffer, isKeyframe: isKeyframe) }
	}

	public func pcmAudioDidConfigure(channels: Int, sampleRate: Int) {
		queue.async { [self] in handleAudioConfig(SegmentAudioConfig(channels: channels, rate: sampleRate)) }
	}

	public func pcmAudioDidReceive(pcm: UnsafeBufferPointer<Int16>, frameCount: Int, hostTime: UInt64) {
		guard frameCount > 0, pcm.count >= frameCount, phase.withLock({ $0 == .active }) else { return }
		let data = Data(buffer: pcm) // the memory is only valid during this call
		let channels = pcm.count / frameCount
		queue.async { [self] in handleAudio(data, frames: frameCount, channels: channels, hostTime: hostTime) }
	}

	// MARK: Queue-confined state

	private var sessionOpen = false
	private var opts = Options()
	private var segment: RecordingSegment?
	private var segmentIndex = 0
	private var baseName = ""
	private var awaitingKeyframe = false
	private var runActive = false
	private var activeFormat: CMFormatDescription?
	private var lastRawPTS = CMTime.invalid
	private var retimer = VideoRetimer()
	private var lastKeyframeRequest = Date.distantPast
	private var timer: DispatchSourceTimer?
	private var counters = Stats()
	private var finished: [URL] = []
	private var finishedBytes: Int64 = 0
	private var finishedDuration: TimeInterval = 0
	private var outstandingFinishes = 0
	private var stopCompletion: (([URL]) -> Void)??
	private var failedMessage: String?

	private var audioConfig: SegmentAudioConfig?
	private var timeline: AudioTimeline?
	private var ring: [AudioChunk] = []
	private var ringFrames = 0

	private var lastSourceFormat: CMFormatDescription?
	private var lastTaggedFormat: CMFormatDescription?

	private func begin(_ o: Options) {
		opts = o
		sessionOpen = true
		segment = nil
		segmentIndex = 0
		awaitingKeyframe = false
		runActive = false
		activeFormat = nil
		lastRawPTS = .invalid
		retimer = VideoRetimer()
		counters = Stats()
		finished = []
		finishedBytes = 0
		finishedDuration = 0
		outstandingFinishes = 0
		stopCompletion = nil
		failedMessage = nil
		timeline = nil
		ring = []
		ringFrames = 0
		lastSourceFormat = nil
		lastTaggedFormat = nil
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyy-MM-dd HH-mm-ss"
		baseName = "\(o.fileNamePrefix) \(f.string(from: Date()))"
		do {
			try FileManager.default.createDirectory(at: o.directory, withIntermediateDirectories: true)
		} catch {
			fail(RecorderError.directory(error.localizedDescription))
			return
		}
		let t = DispatchSource.makeTimerSource(queue: queue)
		t.schedule(deadline: .now() + 0.25, repeating: 0.25)
		t.setEventHandler { [weak self] in self?.tick() }
		t.resume()
		timer = t
		requestKeyframe(force: true)
	}

	private func requestKeyframe(force: Bool = false) {
		let now = Date()
		guard force || now.timeIntervalSince(lastKeyframeRequest) >= 1 else { return }
		lastKeyframeRequest = now
		keyframeRequester?.requestKeyframe()
	}

	private func tick() {
		guard sessionOpen else { return }
		segment?.checkHealth()
		segment?.pump()
		if segment == nil || awaitingKeyframe { requestKeyframe() }
		publishProgress()
	}

	private func fileURL(forPart part: Int) -> URL {
		var name = baseName
		if part > 1 { name += " part \(part)" }
		var url = opts.directory.appendingPathComponent(name).appendingPathExtension("mov")
		var n = 2
		while FileManager.default.fileExists(atPath: url.path) {
			url = opts.directory.appendingPathComponent("\(name) (\(n))").appendingPathExtension("mov")
			n += 1
		}
		return url
	}

	// MARK: Video

	private func handleVideo(_ input: CMSampleBuffer, isKeyframe: Bool) {
		guard sessionOpen, failedMessage == nil, stopCompletion == nil else { return }
		guard let srcFormat = CMSampleBufferGetFormatDescription(input), input.presentationTimeStamp.isValid else { return }
		let sample = retagged(input, srcFormat)
		let format = CMSampleBufferGetFormatDescription(sample) ?? srcFormat
		let pts = sample.presentationTimeStamp

		guard runActive, let active = activeFormat else {
			// Waiting for the first keyframe of this recording.
			if isKeyframe { beginRun(format); accept(sample) } else { counters.videoFramesDiscardedBeforeKeyframe += 1 }
			return
		}

		if !MediaUtils.isSameFormat(active, format) {
			// One passthrough track cannot change format: close this file, continue in a new one.
			if isKeyframe {
				flushRetimer()
				if let old = segment { segment = nil; closeSegment(old, limit: pts) }
				retimer.reset(keepPeriod: false)
				awaitingKeyframe = false
				beginRun(format)
				accept(sample)
			} else {
				counters.videoFramesDiscardedForResync += 1
				if !awaitingKeyframe { beginResync() }
			}
			return
		}
		if awaitingKeyframe {
			if isKeyframe { awaitingKeyframe = false; retimer.reset(keepPeriod: true) } else {
				counters.videoFramesDiscardedForResync += 1
				requestKeyframe()
				return
			}
		}
		if !isKeyframe, let gap = opts.lossGapThreshold, CMTimeGetSeconds(CMTimeSubtract(pts, lastRawPTS)) > gap {
			counters.videoFramesDiscardedForResync += 1
			beginResync()
			return
		}
		if CMTimeCompare(pts, lastRawPTS) <= 0 {
			counters.videoFramesDroppedBadTimestamp += 1
			return
		}
		accept(sample)
	}

	private func beginRun(_ format: CMFormatDescription) {
		runActive = true
		activeFormat = format
	}

	/// A frame that passed all gates: retime it (if enabled) and hand it to the writer.
	private func accept(_ sample: CMSampleBuffer) {
		lastRawPTS = sample.presentationTimeStamp
		if opts.smoothVideoTimestamps, VideoRetimer.isRetimable(sample) {
			for s in retimer.push(sample) { emit(s) }
		} else {
			for s in retimer.flush() { emit(s) }
			emit(sample)
		}
	}

	private func flushRetimer() {
		for s in retimer.flush() { emit(s) }
	}

	private func emit(_ sample: CMSampleBuffer) {
		guard failedMessage == nil, let format = activeFormat else { return }
		guard let seg = segment else {
			startSegment(first: sample, format: format)
			return
		}
		if CMTimeCompare(sample.presentationTimeStamp, seg.lastVideoPTS) <= 0 {
			counters.videoFramesDroppedBadTimestamp += 1
			return
		}
		if !seg.enqueueVideo(sample) {
			// Writer cannot keep up and the bounded queue is full. A dropped frame breaks the references
			// of the ones after it, so go back to waiting for a keyframe.
			counters.videoFramesDroppedBackpressure += 1
			if !awaitingKeyframe { beginResync() }
		}
		counters.peakPendingVideoFrames = max(counters.peakPendingVideoFrames, seg.peakPendingVideo)
	}

	private func beginResync() {
		flushRetimer() // the frames before the loss are good
		awaitingKeyframe = true
		counters.lossEvents += 1
		requestKeyframe(force: true)
	}

	private func retagged(_ sample: CMSampleBuffer, _ fmt: CMFormatDescription) -> CMSampleBuffer {
		guard opts.fallbackColorTags != nil || opts.fallbackHDRMetadata != nil else { return sample }
		if let src = lastSourceFormat, src === fmt, let tagged = lastTaggedFormat {
			return MediaUtils.sample(sample, withFormat: tagged) ?? sample
		}
		lastSourceFormat = fmt
		lastTaggedFormat = MediaUtils.retaggedFormat(fmt, tags: opts.fallbackColorTags, hdr: opts.fallbackHDRMetadata) ?? fmt
		if let tagged = lastTaggedFormat, tagged !== fmt { return MediaUtils.sample(sample, withFormat: tagged) ?? sample }
		return sample
	}

	private func openSegment(first: CMSampleBuffer, format: CMFormatDescription) -> RecordingSegment? {
		segmentIndex += 1
		let cfg = audioConfig ?? SegmentAudioConfig(channels: 2, rate: 48000)
		let url = fileURL(forPart: segmentIndex)
		do {
			let seg = try RecordingSegment(
				url: url, firstSample: first, format: format, audio: cfg, mode: opts.audio, options: opts, queue: queue,
				onFailure: { [weak self] error in self?.fail(error) })
			counters.segmentsStarted += 1
			// Audio that arrived just before the keyframe belongs to the file too (trimmed to the keyframe time).
			for chunk in ring { seg.enqueueAudio(chunk) }
			let u = url
			onMain { [self] in outputURL = u }
			return seg
		} catch {
			segmentIndex -= 1
			fail(error)
			return nil
		}
	}

	private func startSegment(first: CMSampleBuffer, format: CMFormatDescription) {
		guard let seg = openSegment(first: first, format: format) else { return }
		segment = seg
		awaitingKeyframe = false
		onMain { [self] in state = .recording }
		publishProgress()
	}

	private func closeSegment(_ seg: RecordingSegment, limit: CMTime?) {
		outstandingFinishes += 1
		counters.videoFramesWritten += seg.videoFramesAccepted
		counters.audioBuffersWritten += seg.audioBuffersAccepted
		counters.peakPendingVideoFrames = max(counters.peakPendingVideoFrames, seg.peakPendingVideo)
		counters.peakPendingAudioBuffers = max(counters.peakPendingAudioBuffers, seg.peakPendingAudio)
		finishedDuration += seg.recordedDuration
		seg.finish(
			at: limit, timeout: opts.finishTimeout,
			droppedOnTimeout: { [self] v, a in
				counters.videoFramesWritten -= v
				counters.videoFramesDroppedBackpressure += v
				counters.audioBuffersWritten -= a
				counters.audioBuffersDroppedBackpressure += a
			},
			completion: { [self] url, error in
				outstandingFinishes -= 1
				finishedBytes += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
				if let error { fail(error) } else { finished.append(url) }
				completeStopIfReady()
			})
	}

	// MARK: Audio

	private func handleAudioConfig(_ cfg: SegmentAudioConfig) {
		guard cfg != audioConfig else { return }
		audioConfig = cfg
		timeline = nil
		ring = []
		ringFrames = 0
		if sessionOpen, let seg = segment, seg.audioConfig != cfg, stopCompletion == nil {
			_ = seg
			// Audio format changed mid-recording: cannot continue in the same file.
			flushRetimer()
			if let cur = segment { segment = nil; closeSegment(cur, limit: nil) }
			runActive = false
			activeFormat = nil
			awaitingKeyframe = false
			retimer.reset(keepPeriod: true)
			onMain { [self] in if state == .recording { state = .waitingForKeyframe } }
			requestKeyframe(force: true)
		}
	}

	private func handleAudio(_ data: Data, frames: Int, channels: Int, hostTime: UInt64) {
		guard sessionOpen, failedMessage == nil, stopCompletion == nil else { return }
		if audioConfig == nil { audioConfig = SegmentAudioConfig(channels: channels, rate: 48000) }
		guard let cfg = audioConfig, cfg.channels == channels else { return }
		if timeline == nil { timeline = AudioTimeline(rate: cfg.rate, channels: cfg.channels, delay: opts.audioDelay) }
		let ns = MediaUtils.nanoseconds(fromMachTime: hostTime)
		let beforeSilence = timeline!.silenceInserted, beforeSkip = timeline!.framesSkipped
		let chunks = timeline!.ingest(data, frames: frames, hostNanoseconds: ns)
		counters.audioFramesSilenceInserted += timeline!.silenceInserted - beforeSilence
		counters.audioFramesSkipped += timeline!.framesSkipped - beforeSkip
		for chunk in chunks {
			ring.append(chunk)
			ringFrames += chunk.frames
			if let seg = segment, !seg.enqueueAudio(chunk) { counters.audioBuffersDroppedBackpressure += 1 }
		}
		// Keep about 1.5 s: enough to cover audio that is processed before its video keyframe.
		while ringFrames > cfg.rate * 3 / 2, ring.count > 1 {
			ringFrames -= ring.removeFirst().frames
		}
	}

	// MARK: Finishing

	private func finishSession(_ completion: (([URL]) -> Void)?) {
		guard sessionOpen else {
			phase.withLock { $0 = .idle }
			if let completion { DispatchQueue.main.async { completion([]) } }
			return
		}
		stopCompletion = .some(completion)
		timer?.cancel()
		timer = nil
		flushRetimer()
		if let seg = segment {
			segment = nil
			closeSegment(seg, limit: nil)
		}
		completeStopIfReady()
	}

	private func completeStopIfReady() {
		guard let completion = stopCompletion, outstandingFinishes == 0 else { return }
		stopCompletion = nil
		sessionOpen = false
		var s = counters
		s.peakPendingVideoFrames = counters.peakPendingVideoFrames
		let urls = finished, bytes = finishedBytes, dur = finishedDuration, failed = failedMessage
		phase.withLock { $0 = .idle }
		onMain { [self] in
			stats = s
			finishedURLs = urls
			bytesWritten = bytes
			elapsed = dur
			state = failed.map { .failed($0) } ?? .idle
			completion?(urls)
		}
	}

	/// A writer or setup error. Whatever was written stays on disk (movie fragments keep it playable).
	private func fail(_ error: Error) {
		guard failedMessage == nil else { return }
		let msg = error.localizedDescription
		failedMessage = msg
		if let seg = segment {
			segment = nil
			counters.videoFramesWritten += seg.videoFramesAccepted
			finishedDuration += seg.recordedDuration
		}
		if stopCompletion == nil {
			// Failure while recording: stop accepting samples, keep the partial files.
			timer?.cancel()
			timer = nil
			sessionOpen = false
			let urls = finished, s = counters
			phase.withLock { $0 = .idle }
			onMain { [self] in state = .failed(msg); finishedURLs = urls; stats = s }
		}
	}

	// MARK: Publishing

	private func publishProgress() {
		var s = counters
		var dur = finishedDuration
		var bytes = finishedBytes
		if let seg = segment {
			s.videoFramesWritten += seg.videoFramesAccepted
			s.audioBuffersWritten += seg.audioBuffersAccepted
			s.peakPendingVideoFrames = max(s.peakPendingVideoFrames, seg.peakPendingVideo)
			s.peakPendingAudioBuffers = max(s.peakPendingAudioBuffers, seg.peakPendingAudio)
			dur += seg.recordedDuration
			bytes += seg.currentFileSize
		}
		let urls = finished
		onMain { [self] in
			if elapsed != dur { elapsed = dur }
			if bytesWritten != bytes { bytesWritten = bytes }
			if stats != s { stats = s }
			if finishedURLs != urls { finishedURLs = urls }
		}
	}

	private func resetPublished() {
		elapsed = 0
		bytesWritten = 0
		outputURL = nil
		finishedURLs = []
		stats = Stats()
	}

	private func onMain(_ block: @escaping () -> Void) {
		if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
	}
}
