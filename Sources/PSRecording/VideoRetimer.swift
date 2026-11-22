import CoreMedia
import Foundation

/// Smooths arrival-time video timestamps onto a steady frame grid.
///
/// The contract stamps each frame with its network arrival time, which jitters by several
/// milliseconds around the console's fixed frame interval. Written as is, that gives a variable
/// frame rate file that editors conform badly. This is a small second-order phase locked loop:
/// the frame interval is learned from the first frames, then each frame is placed at the predicted
/// time nudged a little towards where it actually arrived, so the output follows the host clock on
/// average but without the jitter. A large deviation (a gap) re-anchors on the raw stamp.
///
/// Only used for streams without frame reordering (decode time equals presentation time).
struct VideoRetimer {
	private var held: [CMSampleBuffer] = []
	private var period: Double = 0      // ns
	private var locked = false
	private var anchorNext = true
	private var lastOut: Int64 = 0
	private let warmup = 15
	private let alpha = 0.05
	private let beta = 0.000625

	/// Forget the phase (after a gap or resync); optionally also relearn the interval (after a format change).
	mutating func reset(keepPeriod: Bool) {
		anchorNext = true
		if !keepPeriod { locked = false; period = 0 }
	}

	var heldCount: Int { held.count }

	mutating func push(_ sample: CMSampleBuffer) -> [CMSampleBuffer] {
		if locked { return [step(sample)] }
		held.append(sample)
		guard held.count >= warmup else { return [] }
		return flush()
	}

	/// Emits whatever is still held (end of a run).
	mutating func flush() -> [CMSampleBuffer] {
		guard !held.isEmpty else { return [] }
		let frames = held
		held = []
		if !locked {
			if frames.count >= 2 {
				let span = Double(MediaUtils.nanoseconds(frames.last!.presentationTimeStamp) - MediaUtils.nanoseconds(frames.first!.presentationTimeStamp))
				period = VideoRetimer.snap(span / Double(frames.count - 1))
				locked = period > 1_000_000
			}
			if !locked { return frames } // a single frame: nothing to learn from
		}
		return frames.map { step($0) }
	}

	private mutating func step(_ sample: CMSampleBuffer) -> CMSampleBuffer {
		let raw = MediaUtils.nanoseconds(sample.presentationTimeStamp)
		var out = raw
		if anchorNext {
			anchorNext = false
		} else {
			let predicted = Double(lastOut) + period
			let e = Double(raw) - predicted
			if abs(e) > 3 * period {
				out = raw
			} else {
				out = Int64(predicted + alpha * e)
				period += beta * e
			}
			out = max(out, lastOut + Int64(period / 4))
		}
		lastOut = out
		return VideoRetimer.withTime(sample, out) ?? sample
	}

	private static func snap(_ p: Double) -> Double {
		for fps in [24.0, 25, 30, 50, 60, 120] {
			let ideal = 1e9 / fps
			if abs(p - ideal) / ideal < 0.06 { return ideal }
		}
		return p
	}

	private static func withTime(_ sample: CMSampleBuffer, _ ns: Int64) -> CMSampleBuffer? {
		var timing = CMSampleTimingInfo()
		guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr else { return nil }
		let t = CMTime(value: ns, timescale: 1_000_000_000)
		timing.presentationTimeStamp = t
		if timing.decodeTimeStamp.isValid { timing.decodeTimeStamp = t }
		var out: CMSampleBuffer?
		guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
			sampleTimingArray: &timing, sampleBufferOut: &out) == noErr else { return nil }
		return out
	}

	/// True if the sample can be retimed: one sample, decode time absent or equal to presentation time.
	static func isRetimable(_ s: CMSampleBuffer) -> Bool {
		guard CMSampleBufferGetNumSamples(s) == 1 else { return false }
		let dts = s.decodeTimeStamp
		return !dts.isValid || CMTimeCompare(dts, s.presentationTimeStamp) == 0
	}
}
