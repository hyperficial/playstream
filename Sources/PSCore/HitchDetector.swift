import Foundation

/// What the stats looked like at one moment, in the terms the hitch detector needs. The app
/// fills one in each time it refreshes its stats (four times a second).
public struct HitchSample: Sendable {
	/// Monotonic time of the sample, seconds.
	public var time: Double
	/// The stream is up (samples taken while connecting or after the end are ignored).
	public var streaming = true

	// Cumulative counters since the session started.
	public var framesReceived = 0
	public var framesLostInNetwork = 0
	public var framesDropped = 0
	/// Frames that missed their presentation slot (pacer) plus presents that reached the glass
	/// one or more refreshes late.
	public var framesLate = 0
	public var framesSkipped = 0
	public var decodeErrors = 0
	/// Times the frame-generation slot grid or the pacing grid had to move.
	public var gridShifts = 0
	public var audioUnderruns: Int?

	/// On-screen time of the most recent pictures, ms, newest last (empty when the renderer
	/// cannot measure it).
	public var presentedIntervalsMs: [Float] = []
	/// Time between the most recent frame arrivals, ms, newest last.
	public var arrivalIntervalsMs: [Float] = []
	/// Pictures reaching the screen per second (0 when unknown).
	public var presentedFPS = 0.0
	/// Frame rate the stream is running at.
	public var streamFPS = 60.0

	// Context printed with every note.
	public var bitrateMbps = 0.0
	public var packetLossPercent = 0.0
	public var rttMs = 0.0
	public var audioBufferedMs: Double?
	public var playoutDelayMs: Double?

	public init(time: Double) { self.time = time }
}

/// Turns the stream of stats samples into occasional one-line notes about visible hitches:
/// a picture that stayed on screen far too long, a burst of late frames, an audio underrun, a
/// gap in the network arrivals, lost or dropped frames. Rate-limited, so a bad minute produces
/// a handful of lines, not hundreds; whatever happens while the limiter holds a line back is
/// merged into the next one.
public struct HitchDetector {
	public struct Configuration: Sendable {
		/// A picture on screen for this many normal frame times is a long frame.
		public var longFrameFactor = 2.5
		/// Late frames within one sample that count as a burst.
		public var lateBurst = 3
		/// An arrival gap of this many frame intervals (and at least `networkGapMinMs`) is a network gap.
		public var networkGapFactor = 2.5
		public var networkGapMinMs = 45.0
		/// No frame at all for this long is reported as a stall even before the stream resumes.
		public var stallSeconds = 1.0
		/// Nothing is reported for this long after the stream came up (pacing is still settling).
		public var warmupSeconds = 3.0
		/// Shortest time between two notes, seconds.
		public var minInterval = 1.0
		/// Notes allowed in a burst, and how often one more becomes available.
		public var burst = 10
		public var refillSeconds = 6.0

		public init() {}
	}

	public var configuration: Configuration

	private var previous: HitchSample?
	private var startedAt: Double?
	private var pending = Pending()
	private var lastNoteAt = -Double.infinity
	private var tokens: Double
	private var lastRefillAt: Double?
	private var lastFrameAt: Double?
	private var stallReported = false
	private var lateWindow: [(time: Double, count: Int)] = []
	public private(set) var notesWritten = 0

	private struct Pending {
		var longFrameMs = 0.0
		var nominalFrameMs = 0.0
		var slowFrames = 0
		var networkGapMs = 0.0
		var nominalArrivalMs = 0.0
		var late = 0
		var audioUnderruns = 0
		var lost = 0
		var dropped = 0
		var skipped = 0
		var decodeErrors = 0
		var gridShifts = 0
		var stallSeconds = 0.0
		var samples = 0

		var isEmpty: Bool { samples == 0 }
	}

	public init(configuration: Configuration = Configuration()) {
		self.configuration = configuration
		tokens = Double(configuration.burst)
	}

	/// Forget everything (new session).
	public mutating func reset() {
		self = HitchDetector(configuration: configuration)
	}

	/// Feeds one sample. Returns a line to write to the log when a hitch should be reported now.
	public mutating func ingest(_ sample: HitchSample) -> String? {
		guard sample.streaming else {
			previous = nil
			startedAt = nil
			return nil
		}
		defer { previous = sample }
		guard let last = previous, sample.framesReceived >= last.framesReceived, sample.time > last.time else {
			// First sample of a session, or the counters started over.
			startedAt = sample.time
			lastFrameAt = sample.time
			stallReported = false
			pending = Pending()
			return nil
		}
		let c = configuration
		let dt = sample.time - last.time
		let warm = sample.time - (startedAt ?? sample.time) >= c.warmupSeconds
		var hit = false

		// Network: the arrival intervals that are new since the last sample.
		let received = sample.framesReceived - last.framesReceived
		let nominalArrival = sample.streamFPS > 1 ? 1000 / sample.streamFPS : Self.median(sample.arrivalIntervalsMs)
		if received > 0 {
			lastFrameAt = sample.time
			stallReported = false
			let fresh = sample.arrivalIntervalsMs.suffix(received)
			if let gap = fresh.max().map(Double.init), gap >= max(c.networkGapFactor * nominalArrival, c.networkGapMinMs) {
				pending.networkGapMs = max(pending.networkGapMs, gap)
				pending.nominalArrivalMs = nominalArrival
				hit = true
			}
		} else if warm, let lastFrameAt, sample.time - lastFrameAt >= c.stallSeconds, !stallReported {
			stallReported = true
			pending.stallSeconds = sample.time - lastFrameAt
			hit = true
		}

		// Display: the presented intervals that are new since the last sample.
		if !sample.presentedIntervalsMs.isEmpty {
			let expected = Int((max(sample.presentedFPS, 1) * dt).rounded())
			let fresh = Self.newEntries(previous: last.presentedIntervalsMs, current: sample.presentedIntervalsMs, expected: expected)
			let nominal = Self.median(sample.presentedIntervalsMs)
			if nominal > 0, !fresh.isEmpty {
				let longest = Double(fresh.max() ?? 0)
				if longest >= max(c.longFrameFactor * nominal, nominal + 15) {
					pending.longFrameMs = max(pending.longFrameMs, longest)
					pending.nominalFrameMs = nominal
					hit = true
				}
				pending.slowFrames += fresh.reduce(0) { $0 + (Double($1) >= 1.5 * nominal + 2 ? 1 : 0) }
			}
		}

		// Counters.
		func delta(_ now: Int, _ before: Int) -> Int { max(0, now - before) }
		let late = delta(sample.framesLate, last.framesLate)
		lateWindow.removeAll { sample.time - $0.time > 1 }
		if late > 0 {
			lateWindow.append((sample.time, late))
			// A burst: several late frames within a second. One or two on their own are not worth a line.
			let recent = lateWindow.reduce(0) { $0 + $1.count }
			if recent >= c.lateBurst {
				pending.late += recent
				lateWindow.removeAll()
				hit = true
			}
		}
		if let now = sample.audioUnderruns, let before = last.audioUnderruns, now > before {
			pending.audioUnderruns += now - before
			hit = true
		}
		let lost = delta(sample.framesLostInNetwork, last.framesLostInNetwork)
		let dropped = delta(sample.framesDropped, last.framesDropped)
		let skipped = delta(sample.framesSkipped, last.framesSkipped)
		let errors = delta(sample.decodeErrors, last.decodeErrors)
		let shifts = delta(sample.gridShifts, last.gridShifts)
		pending.lost += lost
		pending.dropped += dropped
		pending.skipped += skipped
		pending.decodeErrors += errors
		pending.gridShifts += shifts
		if lost + dropped + skipped + errors + shifts > 0 { hit = true }

		guard warm else {
			pending = Pending()
			return nil
		}
		if hit { pending.samples += 1 }
		guard !pending.isEmpty else {
			pending = Pending()
			return nil
		}

		// Rate limit: a minimum spacing plus a token bucket.
		if let lastRefillAt {
			tokens = min(Double(c.burst), tokens + (sample.time - lastRefillAt) / c.refillSeconds)
		}
		lastRefillAt = sample.time
		guard sample.time - lastNoteAt >= c.minInterval, tokens >= 1 else { return nil }
		tokens -= 1
		lastNoteAt = sample.time
		notesWritten += 1
		let line = Self.format(pending, sample: sample)
		pending = Pending()
		return line
	}

	private static func format(_ p: Pending, sample s: HitchSample) -> String {
		var parts: [String] = []
		if p.stallSeconds > 0 { parts.append(String(format: "no video for %.1f s", p.stallSeconds)) }
		if p.longFrameMs > 0 {
			parts.append(String(format: "frame %.1f ms (x%.1f of %.1f)", p.longFrameMs, p.longFrameMs / max(p.nominalFrameMs, 0.1), p.nominalFrameMs))
		}
		if p.slowFrames > 1 { parts.append("slow frames \(p.slowFrames)") }
		if p.networkGapMs > 0 { parts.append(String(format: "net gap %.0f ms (frame every %.1f)", p.networkGapMs, p.nominalArrivalMs)) }
		if p.late > 0 { parts.append("late +\(p.late)") }
		if p.audioUnderruns > 0 { parts.append("audio underrun +\(p.audioUnderruns)") }
		if p.lost > 0 { parts.append("net lost +\(p.lost)") }
		if p.dropped > 0 { parts.append("dropped +\(p.dropped)") }
		if p.skipped > 0 { parts.append("skipped +\(p.skipped)") }
		if p.decodeErrors > 0 { parts.append("decode errors +\(p.decodeErrors)") }
		if p.gridShifts > 0 { parts.append("grid shifts +\(p.gridShifts)") }
		if p.samples > 1 { parts.append("over \(p.samples) samples") }
		var context = String(format: "%.1f Mbit/s rtt %.1f ms loss %.2f%% out %.0f fps", s.bitrateMbps, s.rttMs, s.packetLossPercent, s.presentedFPS)
		if let audio = s.audioBufferedMs { context += String(format: " audio buf %.0f ms", audio) }
		if let delay = s.playoutDelayMs { context += String(format: " playout %.1f ms", delay) }
		return "Hitch: " + parts.joined(separator: " | ") + " || " + context
	}

	// MARK: Helpers

	static func median(_ values: [Float]) -> Double {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		return Double(sorted[sorted.count / 2])
	}

	/// The entries of `current` that were appended since `previous` was taken, when both are
	/// snapshots of the same bounded history (oldest entries fall off the front). The histories
	/// carry no sequence numbers, so the overlap is found by matching; of all shifts that match,
	/// the one closest to `expected` new entries is taken, which keeps a repeating pattern from
	/// being mistaken for "nothing new".
	public static func newEntries(previous: [Float], current: [Float], expected: Int) -> ArraySlice<Float> {
		guard !current.isEmpty else { return [] }
		guard !previous.isEmpty else { return current[...] }
		let count = current.count
		func matches(_ n: Int) -> Bool {
			let overlap = count - n
			guard overlap >= 0, overlap <= previous.count else { return false }
			// Entries only fall off the front of a full history, and a full history never shrinks.
			if overlap < previous.count, count < previous.count { return false }
			let offset = previous.count - overlap
			for i in 0..<overlap where current[i] != previous[offset + i] { return false }
			return true
		}
		let target = min(max(expected, 0), count)
		for distance in 0...count {
			let below = target - distance
			let above = target + distance
			if below >= 0, matches(below) { return current.suffix(below) }
			if distance > 0, above <= count, matches(above) { return current.suffix(above) }
		}
		return current[...]
	}
}
