import AVFoundation
import CoreMedia
import Foundation

struct SegmentAudioConfig: Equatable {
	var channels: Int
	var rate: Int
}

/// One output file: an AVAssetWriter with a passthrough video input and an audio input.
/// Every method must be called on `queue` (the recorder's serial queue); AVFoundation completion
/// handlers hop back onto it.
final class RecordingSegment {
	let url: URL
	let videoFormat: CMFormatDescription
	let startPTS: CMTime
	let audioConfig: SegmentAudioConfig

	private(set) var lastVideoPTS: CMTime
	private(set) var typicalFrameDuration: Double = 1.0 / 60
	private(set) var videoFramesAccepted = 0
	private(set) var audioBuffersAccepted = 0
	private(set) var peakPendingVideo = 0
	private(set) var peakPendingAudio = 0
	private(set) var failure: Error?
	private(set) var isFinished = false

	private let queue: DispatchQueue
	private let writer: AVAssetWriter
	private let videoInput: AVAssetWriterInput
	private let audioInput: AVAssetWriterInput
	private let audioFormat: CMAudioFormatDescription
	private let startAudioFrame: Int64
	private let maxPendingVideo: Int
	private let maxPendingAudio: Int

	private var pendingVideo: [CMSampleBuffer] = []
	private var pendingAudio: [CMSampleBuffer] = []
	private var nextAudioFrame: Int64?
	private var finishing = false
	private var endTime: CMTime = .invalid
	private var completion: ((URL, Error?) -> Void)?
	private var onFailure: ((Error) -> Void)?
	private let openedAt = Date()
	private let debugStall: (after: TimeInterval, duration: TimeInterval)?

	init(url: URL, firstSample: CMSampleBuffer, format: CMFormatDescription, audio: SegmentAudioConfig, mode: StreamRecorder.AudioMode,
	     options: StreamRecorder.Options, queue: DispatchQueue, onFailure: @escaping (Error) -> Void) throws {
		self.url = url
		self.queue = queue
		self.videoFormat = format
		self.startPTS = firstSample.presentationTimeStamp
		self.lastVideoPTS = firstSample.presentationTimeStamp
		self.audioConfig = audio
		self.maxPendingVideo = max(1, options.maxPendingVideoFrames)
		self.maxPendingAudio = max(1, options.maxPendingAudioBuffers)
		self.onFailure = onFailure
		self.debugStall = options.debugStallWriter
		self.startAudioFrame = MediaUtils.frames(fromNanoseconds: MediaUtils.nanoseconds(startPTS), rate: audio.rate, roundUp: true)

		guard let afmt = MediaUtils.audioFormatDescription(channels: audio.channels, rate: audio.rate) else {
			throw RecorderError.audioFormat
		}
		audioFormat = afmt

		let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
		// Movie fragments: the file is playable up to the last completed fragment after a crash.
		writer.movieFragmentInterval = CMTime(seconds: max(0.5, options.fragmentInterval), preferredTimescale: 600)
		writer.shouldOptimizeForNetworkUse = false

		// nil output settings = passthrough: the console's own HEVC/H.264 samples go into the file.
		let v = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
		v.expectsMediaDataInRealTime = true
		guard writer.canAdd(v) else { throw RecorderError.cannotAddInput("video") }
		writer.add(v)

		let a: AVAssetWriterInput
		switch mode {
		case .aac(let bitrate):
			let settings: [String: Any] = [
				AVFormatIDKey: kAudioFormatMPEG4AAC,
				AVSampleRateKey: audio.rate,
				AVNumberOfChannelsKey: audio.channels,
				AVEncoderBitRateKey: bitrate,
				AVChannelLayoutKey: MediaUtils.channelLayoutData(audio.channels),
			]
			a = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: afmt)
		case .lossless:
			a = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: afmt)
		}
		a.expectsMediaDataInRealTime = true
		guard writer.canAdd(a) else { throw RecorderError.cannotAddInput("audio") }
		writer.add(a)

		guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStart }
		writer.startSession(atSourceTime: startPTS)
		self.writer = writer
		self.videoInput = v
		self.audioInput = a

		let q = queue
		let ready: () -> Void = { [weak self] in self?.pump() }
		v.requestMediaDataWhenReady(on: q, using: ready)
		a.requestMediaDataWhenReady(on: q, using: ready)
		_ = enqueueVideo(firstSample)
	}

	// MARK: Input

	/// Returns false if the bounded queue is full (the frame was not taken).
	func enqueueVideo(_ sample: CMSampleBuffer) -> Bool {
		guard !finishing, failure == nil else { return false }
		if pendingVideo.count >= maxPendingVideo { return false }
		let pts = sample.presentationTimeStamp
		if videoFramesAccepted > 0 {
			let d = CMTimeGetSeconds(CMTimeSubtract(pts, lastVideoPTS))
			if d > 0 && d < 0.25 { typicalFrameDuration = typicalFrameDuration * 0.9 + d * 0.1 }
		}
		lastVideoPTS = pts
		videoFramesAccepted += 1
		pendingVideo.append(sample)
		peakPendingVideo = max(peakPendingVideo, pendingVideo.count)
		pump()
		return true
	}

	var pendingVideoCount: Int { pendingVideo.count }

	/// Audio is trimmed to start at the first video frame and kept contiguous (gaps are filled with silence).
	/// Returns false if a buffer had to be dropped because of back-pressure.
	@discardableResult
	func enqueueAudio(_ chunk: AudioChunk) -> Bool {
		guard !finishing, failure == nil else { return true }
		var c = chunk
		let bpf = 2 * audioConfig.channels
		if c.end <= startAudioFrame { return true }
		if c.start < startAudioFrame { c = trimHead(c, to: startAudioFrame, bytesPerFrame: bpf) }
		if let next = nextAudioFrame {
			if c.end <= next { return true }
			if c.start < next { c = trimHead(c, to: next, bytesPerFrame: bpf) }
			else if c.start > next {
				// Earlier buffers were dropped (back-pressure): keep the audio track contiguous with silence.
				let gap = Int(c.start - next)
				guard pendingAudio.count + 2 <= maxPendingAudio else { return false }
				if gap <= audioConfig.rate * 5 {
					_ = appendAudio(AudioChunk(start: next, frames: gap, data: Data(count: gap * bpf)))
				}
			}
		}
		return appendAudio(c)
	}

	private func trimHead(_ c: AudioChunk, to frame: Int64, bytesPerFrame: Int) -> AudioChunk {
		let skip = Int(frame - c.start)
		return AudioChunk(start: frame, frames: c.frames - skip, data: Data(c.data.dropFirst(skip * bytesPerFrame)))
	}

	private func appendAudio(_ c: AudioChunk) -> Bool {
		if pendingAudio.count >= maxPendingAudio { return false }
		guard let sb = makeAudioSample(c) else { return false }
		nextAudioFrame = c.end
		audioBuffersAccepted += 1
		pendingAudio.append(sb)
		peakPendingAudio = max(peakPendingAudio, pendingAudio.count)
		pump()
		return true
	}

	private func makeAudioSample(_ c: AudioChunk) -> CMSampleBuffer? {
		let n = c.data.count
		var block: CMBlockBuffer?
		guard CMBlockBufferCreateWithMemoryBlock(
			allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil,
			offsetToData: 0, dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
			let block else { return nil }
		let ok = c.data.withUnsafeBytes { raw in
			CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: n)
		}
		guard ok == noErr else { return nil }
		var sb: CMSampleBuffer?
		guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
			allocator: nil, dataBuffer: block, formatDescription: audioFormat, sampleCount: c.frames,
			presentationTimeStamp: CMTime(value: c.start, timescale: CMTimeScale(audioConfig.rate)),
			packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
		return sb
	}

	// MARK: Writing

	/// Drains queued samples; also called from the recorder's timer as a safety net.
	func pump() {
		guard failure == nil, !isFinished else { return }
		if let stall = debugStall, !finishing {
			let t = Date().timeIntervalSince(openedAt)
			if t >= stall.after && t < stall.after + stall.duration { return }
		}
		guard writer.status == .writing else {
			if writer.status == .failed { fail(writer.error ?? RecorderError.cannotStart) }
			return
		}
		while !pendingVideo.isEmpty, videoInput.isReadyForMoreMediaData {
			let s = pendingVideo.removeFirst()
			if !videoInput.append(s) { fail(writer.error ?? RecorderError.appendFailed); return }
		}
		while !pendingAudio.isEmpty, audioInput.isReadyForMoreMediaData {
			let s = pendingAudio.removeFirst()
			if !audioInput.append(s) { fail(writer.error ?? RecorderError.appendFailed); return }
		}
		if finishing, pendingVideo.isEmpty, pendingAudio.isEmpty { finalize() }
	}

	private func fail(_ error: Error) {
		guard failure == nil else { return }
		failure = error
		pendingVideo.removeAll()
		pendingAudio.removeAll()
		let cb = onFailure
		onFailure = nil
		cb?(error)
		if finishing, !isFinished, let c = completion {
			isFinished = true
			completion = nil
			c(url, error)
		}
	}

	/// Surfaces a failed writer even when no append happens (called from the recorder's timer).
	func checkHealth() {
		if failure == nil, writer.status == .failed { fail(writer.error ?? RecorderError.cannotStart) }
	}

	/// Flush what is queued, end the session at `endTime` and close the file. `endTime` is clamped
	/// to be after the start. `droppedOnTimeout` reports samples abandoned because the inputs never became ready.
	func finish(at limit: CMTime?, timeout: TimeInterval, droppedOnTimeout: @escaping (_ video: Int, _ audio: Int) -> Void,
	            completion: @escaping (URL, Error?) -> Void) {
		guard !finishing else { return }
		var end = CMTimeAdd(lastVideoPTS, CMTime(seconds: min(max(typicalFrameDuration, 1.0 / 240), 0.1), preferredTimescale: 1_000_000_000))
		if let limit, CMTimeCompare(limit, end) < 0, CMTimeCompare(limit, lastVideoPTS) > 0 { end = limit }
		endTime = end
		finishing = true
		self.completion = completion
		if failure != nil {
			isFinished = true
			self.completion = nil
			completion(url, failure)
			return
		}
		pump()
		if !isFinished, !(pendingVideo.isEmpty && pendingAudio.isEmpty) {
			queue.asyncAfter(deadline: .now() + timeout) { [self] in
				guard !isFinished, failure == nil else { return }
				droppedOnTimeout(pendingVideo.count, pendingAudio.count)
				pendingVideo.removeAll()
				pendingAudio.removeAll()
				finalize()
			}
		}
	}

	private var finalizing = false
	private func finalize() {
		guard !finalizing else { return }
		finalizing = true
		videoInput.markAsFinished()
		audioInput.markAsFinished()
		writer.endSession(atSourceTime: endTime)
		let w = writer, q = queue, u = url
		// Strong capture on purpose: the segment must outlive the recorder's reference until the file is closed.
		w.finishWriting {
			q.async {
				let err: Error? = w.status == .completed ? nil : (w.error ?? RecorderError.cannotStart)
				self.isFinished = true
				let c = self.completion
				self.completion = nil
				c?(u, err)
			}
		}
	}

	var currentFileSize: Int64 {
		let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
		return n ?? 0
	}

	var recordedDuration: TimeInterval { max(0, CMTimeGetSeconds(CMTimeSubtract(lastVideoPTS, startPTS))) }
}

enum RecorderError: LocalizedError {
	case audioFormat, cannotAddInput(String), cannotStart, appendFailed, directory(String)
	var errorDescription: String? {
		switch self {
		case .audioFormat: return "Could not describe the audio format"
		case .cannotAddInput(let s): return "Could not add \(s) input to the movie writer"
		case .cannotStart: return "The movie writer failed to start"
		case .appendFailed: return "The movie writer rejected a sample"
		case .directory(let s): return "Could not create the recording folder: \(s)"
		}
	}
}
