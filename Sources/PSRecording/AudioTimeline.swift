import Foundation

/// A run of interleaved S16 audio with a position on the host clock, expressed in frames at `rate`
/// (frame 0 = host time 0, so values from different sources are directly comparable).
struct AudioChunk {
	var start: Int64
	var frames: Int
	var data: Data
	var end: Int64 { start + Int64(frames) }
}

/// Turns arrival-stamped PCM buffers into a gap-free, sample-accurate timeline on the host clock.
///
/// Arrival times are jittery (network bursts), so the timeline is driven by a running sample
/// counter anchored at the first buffer, not by each buffer's own stamp. The stamps are used only to
/// notice real drift: a stall of more than `gapFill` is filled with silence at once, and a persistent
/// lead or lag (the minimum offset over a one second block, which ignores jitter) beyond
/// `driftThreshold` is corrected by inserting silence or trimming samples.
struct AudioTimeline {
	let rate: Int
	let channels: Int
	let delayFrames: Int64
	private(set) var silenceInserted = 0
	private(set) var framesSkipped = 0

	private var nextStart: Int64 = 0
	private var anchored = false
	private var blockMin: Int64 = .max
	private var blockFrames = 0
	private var pendingSilence = 0
	private var pendingSkip = 0

	private var bytesPerFrame: Int { 2 * channels }
	private var gapFill: Int64 { Int64(rate / 4) }
	private var driftThreshold: Int64 { Int64(rate / 25) }

	init(rate: Int, channels: Int, delay: TimeInterval) {
		self.rate = rate
		self.channels = channels
		self.delayFrames = Int64(delay * Double(rate))
	}

	private func silence(_ frames: Int, at start: Int64) -> AudioChunk {
		AudioChunk(start: start, frames: frames, data: Data(count: frames * bytesPerFrame))
	}

	/// - Parameter hostNanoseconds: arrival time of the END of this buffer on the host clock.
	mutating func ingest(_ data: Data, frames: Int, hostNanoseconds: Int64) -> [AudioChunk] {
		var out: [AudioChunk] = []
		let duration = Int64(frames)
		let candidate = MediaUtils.frames(fromNanoseconds: hostNanoseconds, rate: rate) - duration + delayFrames
		if !anchored {
			anchored = true
			nextStart = candidate
		}
		var offset = candidate - nextStart // > 0: buffer arrived later than the counter says (gap)
		if offset > gapFill {
			let n = Int(offset)
			out.append(silence(n, at: nextStart))
			nextStart += offset
			silenceInserted += n
			blockMin = .max
			blockFrames = 0
			pendingSilence = 0
			offset = 0
		} else {
			blockMin = min(blockMin, offset)
		}
		blockFrames += frames

		if pendingSilence > 0 {
			out.append(silence(pendingSilence, at: nextStart))
			nextStart += Int64(pendingSilence)
			silenceInserted += pendingSilence
			pendingSilence = 0
		}
		var payload = data
		var count = frames
		if pendingSkip > 0 {
			let skip = min(pendingSkip, count)
			payload = payload.dropFirst(skip * bytesPerFrame)
			count -= skip
			pendingSkip -= skip
			framesSkipped += skip
		}
		if count > 0 {
			out.append(AudioChunk(start: nextStart, frames: count, data: Data(payload)))
			nextStart += Int64(count)
		}

		if blockFrames >= rate {
			// Offsets measured above already include the lead/lag from earlier corrections.
			let m = blockMin == .max ? 0 : blockMin
			if m > driftThreshold { pendingSilence = Int(m) } else if m < -driftThreshold { pendingSkip = Int(-m) }
			blockMin = .max
			blockFrames = 0
		}
		return out
	}
}
