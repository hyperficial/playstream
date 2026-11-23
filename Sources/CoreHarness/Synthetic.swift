import Foundation
import PSContracts
import PSCore

// Stand-ins for the console and the video pipeline, so the debugging tools can be exercised
// without a PlayStation, a window or a decoder.

/// Produces a fake HEVC Annex-B stream: one stream header, a keyframe, then P frames, with a
/// new keyframe whenever one is requested, exactly as the console behaves. The bytes are not
/// decodable video; they carry the frame number and a checkable pattern.
final class SyntheticStream: KeyframeRequesting, @unchecked Sendable {
	let profile: StreamProfile
	var sink: VideoStreamSink?
	/// Frames per second while running on its own thread.
	var fps: Double
	var bytesPerFrame: Int

	private let lock = NSLock()
	private var keyframeWanted = true
	private var requests = 0
	private var sent = 0
	private var running = false
	private var thread: Thread?
	/// Every n-th frame arrives this late (a network stall), when set.
	var stall: (every: Int, seconds: Double)?

	init(profile: StreamProfile = StreamProfile(width: 1920, height: 1080, fps: 60, bitrateKbps: 15000, codec: .hevcHDR), fps: Double = 60, bytesPerFrame: Int = 31_250) {
		self.profile = profile
		self.fps = fps
		self.bytesPerFrame = bytesPerFrame
	}

	var keyframeRequests: Int { lock.withLock { requests } }
	var framesSent: Int { lock.withLock { sent } }
	var isRunning: Bool { lock.withLock { running } }

	func requestKeyframe() {
		lock.withLock {
			keyframeWanted = true
			requests += 1
		}
	}

	// MARK: Building buffers

	static let startCode: [UInt8] = [0, 0, 0, 1]

	/// VPS, SPS and PPS NAL units (types 32, 33, 34) with a few payload bytes each.
	static func makeHeader() -> [UInt8] {
		var out: [UInt8] = []
		for type in [UInt8(32), 33, 34] {
			out += startCode + [type << 1, 0x01, 0xA0 | type, 0x55, 0xAA, 0x80]
		}
		return out
	}

	/// One coded frame: an IDR slice (type 19) or a trailing picture (type 1). After the NAL
	/// header come the frame index (8 bytes, little-endian) and a pattern derived from it.
	static func makeFrame(index: Int, keyframe: Bool, size: Int) -> [UInt8] {
		var out = [UInt8](repeating: 0, count: max(size, 16))
		out[3] = 1
		out[4] = (keyframe ? 19 : 1) << 1
		out[5] = 0x01
		var value = UInt64(index).littleEndian
		withUnsafeBytes(of: &value) { for (i, b) in $0.enumerated() { out[6 + i] = b } }
		let seed = UInt8(truncatingIfNeeded: index &* 31)
		out.withUnsafeMutableBufferPointer { buffer in
			for i in 14..<buffer.count { buffer[i] = (seed &+ UInt8(truncatingIfNeeded: i)) | 0x80 }
		}
		return out
	}

	/// The frame index a buffer made by `makeFrame` carries, and whether its pattern is intact.
	static func inspectFrame(_ data: Data) -> (index: Int, keyframe: Bool, intact: Bool)? {
		let bytes = [UInt8](data)
		guard bytes.count >= 16, Array(bytes[0..<4]) == startCode else { return nil }
		let type = (bytes[4] >> 1) & 0x3F
		guard type == 19 || type == 1 else { return nil }
		let index = bytes[6..<14].enumerated().reduce(0) { $0 | (Int($1.element) << (8 * $1.offset)) }
		let seed = UInt8(truncatingIfNeeded: index &* 31)
		var intact = true
		for i in 14..<bytes.count where bytes[i] != (seed &+ UInt8(truncatingIfNeeded: i)) | 0x80 {
			intact = false
			break
		}
		return (index, type == 19, intact)
	}

	// MARK: Sending

	/// Sends the stream header (what the core delivers first in a session).
	func sendHeader() {
		let header = Self.makeHeader()
		header.withUnsafeBytes { _ = sink?.videoStreamDidReceive(accessUnit: $0, framesLost: 0, frameRecovered: false) }
	}

	/// Sends the next frame and returns its index and whether it was a keyframe.
	@discardableResult
	func sendFrame(framesLost: Int = 0, recovered: Bool = false) -> (index: Int, keyframe: Bool) {
		let (index, keyframe): (Int, Bool) = lock.withLock {
			let k = keyframeWanted
			keyframeWanted = false
			sent += 1
			return (sent - 1, k)
		}
		let frame = Self.makeFrame(index: index, keyframe: keyframe, size: keyframe ? bytesPerFrame * 4 : bytesPerFrame)
		frame.withUnsafeBytes { _ = sink?.videoStreamDidReceive(accessUnit: $0, framesLost: framesLost, frameRecovered: recovered) }
		return (index, keyframe)
	}

	/// Sends frames from the calling thread at a steady `rate` for `seconds` (or exactly `frames`).
	func pump(rate: Double, seconds: Double = .infinity, frames: Int = .max) {
		let begin = DispatchTime.now().uptimeNanoseconds
		var n = 0
		while n < frames, Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e9 < seconds {
			sendFrame()
			n += 1
			let target = begin + UInt64(Double(n) / rate * 1e9)
			let now = DispatchTime.now().uptimeNanoseconds
			if target > now { usleep(UInt32((target - now) / 1000)) }
		}
	}

	/// The next frame of a running stream arrives this late.
	func stallOnce(seconds: Double) {
		lock.withLock { pendingStall = seconds }
	}

	private var pendingStall = 0.0

	/// Starts a session: `videoStreamWillStart`, the header, then frames at `fps` on a thread.
	func start() {
		lock.withLock {
			running = true
			keyframeWanted = true
			sent = 0
		}
		sink?.videoStreamWillStart(profile: profile)
		sendHeader()
		let thread = Thread { [self] in
			let begin = DispatchTime.now().uptimeNanoseconds
			var n: UInt64 = 0
			var late: UInt64 = 0
			while isRunning {
				let (index, _) = sendFrame()
				if let stall, index > 0, index % stall.every == 0 { late += UInt64(stall.seconds * 1e9) }
				let once: Double = lock.withLock {
					defer { pendingStall = 0 }
					return pendingStall
				}
				late += UInt64(once * 1e9)
				n += 1
				let target = begin + UInt64(Double(n) / fps * 1e9) + late
				let now = DispatchTime.now().uptimeNanoseconds
				if target > now { usleep(UInt32(min((target - now) / 1000, 1_000_000))) }
			}
		}
		thread.name = "synthetic.stream"
		thread.qualityOfService = .userInteractive
		self.thread = thread
		thread.start()
	}

	func stop() {
		let wasRunning: Bool = lock.withLock {
			let was = running
			running = false
			return was
		}
		guard wasRunning else { return }
		while thread?.isFinished == false { usleep(2000) }
		thread = nil
		sink?.videoStreamDidStop()
	}
}

/// What the tools need from a video pipeline: it takes the stream and answers the debug calls.
final class FakePipeline: VideoStreamSink, VideoDebugControlling, @unchecked Sendable {
	struct Stats {
		var framesReceived = 0
		var headersReceived = 0
		var keyframesReceived = 0
		var bytesReceived = 0
		var lastArrivalGapMs = 0.0
		var streaming = false
		var mode = FakeMode.steady
		var optionalNumber: Double?
		var histogram = [0, 0, 0]
		/// Time between the most recent frame arrivals, ms, newest last (up to 240).
		var recentArrivalIntervalsMs: [Float] = []
	}

	enum FakeMode: String { case steady, catchingUp }

	private let lock = NSLock()
	private var stats = Stats()
	private var tunables: [String: Double] = ["pacer.marginMs": 4, "framegen.confidence": 0.6, "scaler.sharpnessBias": 0]
	private var trace: [(time: Double, index: Int, bytes: Int, keyframe: Bool)] = []
	private var lastArrival = 0.0
	private var pictureRequest: (remaining: Int, directory: URL, files: [URL], completion: @Sendable ([URL]) -> Void)?
	private let pictureQueue = DispatchQueue(label: "fake.pictures")

	var snapshot: Stats { lock.withLock { stats } }

	func videoStreamWillStart(profile: StreamProfile) {
		lock.withLock {
			stats = Stats()
			stats.streaming = true
			trace.removeAll()
			lastArrival = 0
		}
	}

	func videoStreamDidReceive(accessUnit: UnsafeRawBufferPointer, framesLost: Int, frameRecovered: Bool) -> Bool {
		let now = ProcessInfo.processInfo.systemUptime
		let bytes = accessUnit.bindMemory(to: UInt8.self)
		let type = bytes.count > 5 ? (bytes[4] >> 1) & 0x3F : 63
		var job: (() -> Void)?
		lock.withLock {
			stats.bytesReceived += bytes.count
			if type >= 32 {
				stats.headersReceived += 1
				return
			}
			stats.framesReceived += 1
			if type == 19 { stats.keyframesReceived += 1 }
			if lastArrival > 0 {
				stats.lastArrivalGapMs = (now - lastArrival) * 1000
				stats.recentArrivalIntervalsMs.append(Float(stats.lastArrivalGapMs))
				if stats.recentArrivalIntervalsMs.count > 240 { stats.recentArrivalIntervalsMs.removeFirst() }
			}
			lastArrival = now
			stats.histogram[min(2, stats.framesReceived % 3)] += 1
			trace.append((now, stats.framesReceived - 1, bytes.count, type == 19))
			if trace.count > 20_000 { trace.removeFirst(trace.count - 20_000) }
			if var request = pictureRequest {
				let index = request.files.count
				let url = request.directory.appendingPathComponent(String(format: "picture-%04d.ppm", index))
				request.files.append(url)
				request.remaining -= 1
				let frame = stats.framesReceived
				let done = request.remaining == 0
				let files = request.files
				let completion = request.completion
				pictureRequest = done ? nil : request
				job = {
					// An 8x8 grey picture whose level follows the frame number.
					var ppm = Data("P6\n8 8\n255\n".utf8)
					ppm.append(contentsOf: [UInt8](repeating: UInt8(truncatingIfNeeded: frame), count: 8 * 8 * 3))
					try? ppm.write(to: url)
					if done { completion(files) }
				}
			}
		}
		if let job { pictureQueue.async(execute: job) }
		return true
	}

	func videoStreamDidStop() {
		lock.withLock { stats.streaming = false }
	}

	// MARK: VideoDebugControlling

	func debugTunables() -> [String: Double] { lock.withLock { tunables } }

	func setDebugTunable(_ name: String, to value: Double) -> Bool {
		lock.withLock {
			guard tunables[name] != nil, (0...100).contains(value) else { return false }
			tunables[name] = value
			return true
		}
	}

	func writeFrameTrace(to url: URL, lastSeconds: Double) throws -> Int {
		let now = ProcessInfo.processInfo.systemUptime
		let records = lock.withLock { trace.filter { now - $0.time <= lastSeconds } }
		var out = Data()
		for r in records {
			out.append(Data(String(format: "{\"event\":\"arrival\",\"t\":%.6f,\"frame\":%d,\"bytes\":%d,\"keyframe\":%@}\n", r.time, r.index, r.bytes, r.keyframe ? "true" : "false").utf8))
		}
		try out.write(to: url)
		return records.count
	}

	func capturePresentedFrames(count: Int, to directory: URL, completion: @escaping @Sendable ([URL]) -> Void) {
		lock.withLock { pictureRequest = (count, directory, [], completion) }
	}
}
