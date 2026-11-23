import Darwin
import Foundation
import os
import PSContracts

/// Flight recorder for the encoded video stream.
///
/// Sits between the session and the video pipeline (`session.videoSink = tee`,
/// `tee.downstream = pipeline`) and keeps a copy of the most recent Annex-B buffers with their
/// arrival times in memory. On command the buffered stream is written as a PSCAP1 file
/// (`StreamCaptureFile`), which replays offline with the session's real content and timing.
/// An explicit capture (`startCapture` / `stopCapture`) writes to disk as the stream arrives,
/// for recordings longer than the in-memory window.
///
/// Cost on the stream (network) thread, per buffer: one clock read, a look at the first NAL
/// header, one short uncontended lock and one `memcpy` of the buffer into a preallocated slab,
/// all after the buffer has been handed to the pipeline, so decoding is not delayed by it. No file
/// I/O and no allocation in steady state happen on that thread.
public final class StreamCaptureTee: VideoStreamSink, @unchecked Sendable {
	public struct Limits: Equatable, Sendable {
		/// How much of the stream to keep, seconds. 0 turns the in-memory recorder off.
		public var seconds: Double
		/// Upper bound on the memory used for it, bytes. Whichever limit is hit first wins.
		public var bytes: Int

		public init(seconds: Double = 60, bytes: Int = 256 * 1024 * 1024) {
			self.seconds = seconds
			self.bytes = bytes
		}

		public static let off = Limits(seconds: 0, bytes: 0)
	}

	public struct CaptureResult: Sendable {
		public var url: URL
		public var records: Int
		public var bytes: Int64
		public var durationSeconds: Double
		public var startsWithKeyframe: Bool
		public var hasStreamHeader: Bool
		public var keyframes: Int
		/// Problems worth knowing about (also written into the header notes).
		public var warnings: [String]

		public var json: [String: Any] {
			[
				"path": url.path, "records": records, "bytes": bytes, "durationSeconds": (durationSeconds * 1000).rounded() / 1000,
				"startsWithKeyframe": startsWithKeyframe, "hasStreamHeader": hasStreamHeader, "keyframes": keyframes, "warnings": warnings,
			]
		}
	}

	/// Receives everything the tee receives. Set before the session starts.
	public var downstream: VideoStreamSink?
	/// Asked for a keyframe when a capture needs one. Set it to the session.
	public weak var keyframeRequester: KeyframeRequesting?
	/// Extra fields for the header notes (settings in force, build). Called on the capture
	/// queue, never on a stream thread; must be thread-safe.
	public var notesProvider: (() -> [String: Any])?
	/// One-line diagnostics. Called on the capture queue.
	public var logHandler: ((String) -> Void)?

	/// How long an explicit capture waits for the keyframe it asked for before it starts
	/// writing anyway (and says so in its notes).
	public var keyframeWaitSeconds: Double = 2

	// MARK: State (all under `lock`)

	private enum Kind: UInt8 { case header, keyframe, frame }

	private struct Rec {
		var offset: Int
		var length: Int
		var arrivalNs: UInt64
		var flags: UInt32
		var kind: Kind
	}

	/// A block of buffered stream bytes. Records never span slabs, so dropping the oldest slab
	/// drops whole records.
	private final class Slab {
		let base: UnsafeMutableRawPointer
		let capacity: Int
		var used = 0
		var records = ContiguousArray<Rec>()
		var keyframes = 0

		init(capacity: Int) {
			self.capacity = capacity
			base = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
			records.reserveCapacity(1024)
		}

		deinit { base.deallocate() }

		func reset() {
			used = 0
			keyframes = 0
			records.removeAll(keepingCapacity: true)
		}
	}

	private final class DiskCapture {
		enum Phase { case waitingForKeyframe, writing }
		let url: URL
		let startedNs: UInt64
		let deadlineNs: UInt64?
		let maxBytes: Int64
		var phase = Phase.waitingForKeyframe
		var pending: [(Slab, Rec)] = []
		var baseNs: UInt64 = 0
		var lastNs: UInt64 = 0
		var startsWithKeyframe = false
		var hasStreamHeader = false
		var keyframes = 0
		var records = 0
		var bytes: Int64 = 0
		/// Enqueued for writing but not on disk yet.
		var backlogBytes = 0
		var warnings: [String] = []
		// Capture queue only.
		var writer: StreamCaptureWriter?
		var failure: String?

		init(url: URL, startedNs: UInt64, deadlineNs: UInt64?, maxBytes: Int64) {
			self.url = url
			self.startedNs = startedNs
			self.deadlineNs = deadlineNs
			self.maxBytes = maxBytes
		}
	}

	private let lock: os_unfair_lock_t = {
		let l = os_unfair_lock_t.allocate(capacity: 1)
		l.initialize(to: os_unfair_lock())
		return l
	}()

	private var limitsValue: Limits
	private var keyframeIntervalNs: UInt64 = 0
	private var slabs: [Slab] = []
	private var spareSlab: Slab?
	private var totalCapacity = 0
	private var profile: StreamProfile?
	/// The most recent stream headers (parameter-set buffers) with their arrival times, oldest first.
	private var headers: [(arrivalNs: UInt64, data: Data)] = []
	private var lastKeyframeNs: UInt64 = 0
	private var lastKeyframeRequestNs: UInt64 = 0
	private var lastArrivalNs: UInt64 = 0
	private var buffersSeen = 0
	private var keyframesSeen = 0
	private var bytesSeen: Int64 = 0
	private var streaming = false
	private var capture: DiskCapture?
	private var captureCompletions: [(Result<CaptureResult, Error>) -> Void] = []

	private let ioQueue = DispatchQueue(label: "playstream.capture.io", qos: .utility)
	private static let maxBacklogBytes = 192 * 1024 * 1024

	public init(limits: Limits = Limits()) {
		limitsValue = limits
	}

	deinit {
		lock.deinitialize(count: 1)
		lock.deallocate()
	}

	@inline(__always)
	private func locked<T>(_ body: () throws -> T) rethrows -> T {
		os_unfair_lock_lock(lock)
		defer { os_unfair_lock_unlock(lock) }
		return try body()
	}

	@inline(__always)
	private static func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

	// MARK: Configuration (any thread)

	/// Retention of the in-memory recorder. Shrinking it or turning it off releases memory at once.
	public var limits: Limits {
		get { locked { limitsValue } }
		set {
			locked {
				limitsValue = Limits(seconds: max(0, newValue.seconds), bytes: max(0, newValue.bytes))
				if !ringEnabledLocked, capture == nil {
					slabs.removeAll()
					spareSlab = nil
					totalCapacity = 0
				} else {
					evictLocked(now: Self.nowNs())
				}
			}
		}
	}

	/// When greater than 0, a keyframe is requested whenever none has arrived for this many
	/// seconds, so the in-memory window always contains one and every dump is decodable from its
	/// start. Off (0) by default: each keyframe is a burst of data the stream otherwise never has.
	public var keyframeIntervalSeconds: Double {
		get { locked { Double(keyframeIntervalNs) / 1e9 } }
		set { locked { keyframeIntervalNs = newValue > 0 ? UInt64(max(0.5, newValue) * 1e9) : 0 } }
	}

	private var ringEnabledLocked: Bool { limitsValue.seconds > 0 && limitsValue.bytes > 0 }

	private var slabSizeLocked: Int {
		let wanted = ringEnabledLocked ? limitsValue.bytes / 8 : 4 << 20
		return min(4 << 20, max(1 << 20, wanted))
	}

	// MARK: VideoStreamSink (stream thread)

	public func videoStreamWillStart(profile: StreamProfile) {
		locked {
			self.profile = profile
			slabs.removeAll()
			totalCapacity = 0
			headers.removeAll()
			lastKeyframeNs = 0
			lastKeyframeRequestNs = 0
			lastArrivalNs = 0
			buffersSeen = 0
			keyframesSeen = 0
			bytesSeen = 0
			streaming = true
		}
		downstream?.videoStreamWillStart(profile: profile)
	}

	public func videoStreamDidReceive(accessUnit: UnsafeRawBufferPointer, framesLost: Int, frameRecovered: Bool) -> Bool {
		let arrival = Self.nowNs()
		// The pipeline goes first: nothing below may delay a frame on its way to the decoder.
		let accepted = downstream?.videoStreamDidReceive(accessUnit: accessUnit, framesLost: framesLost, frameRecovered: frameRecovered) ?? true
		record(accessUnit, arrival: arrival, framesLost: framesLost, frameRecovered: frameRecovered)
		return accepted
	}

	public func videoStreamDidStop() {
		downstream?.videoStreamDidStop()
		locked { streaming = false }
		// The file of a running capture is complete as far as the stream goes: close it.
		finishCapture(reason: "the session ended", completion: nil)
	}

	private func record(_ buffer: UnsafeRawBufferPointer, arrival: UInt64, framesLost: Int, frameRecovered: Bool) {
		guard let base = buffer.baseAddress, buffer.count > 0 else { return }
		let count = buffer.count
		var wantKeyframe = false
		var job: (() -> Void)?
		var finishReason: String?

		os_unfair_lock_lock(lock)
		let hevc = profile?.codec.isHEVC ?? true
		let kind = Self.classify(base.assumingMemoryBound(to: UInt8.self), count: count, hevc: hevc)
		buffersSeen += 1
		bytesSeen += Int64(count)
		lastArrivalNs = arrival
		switch kind {
		case .header:
			headers.append((arrival, Data(bytes: base, count: count)))
			if headers.count > 4 { headers.removeFirst(headers.count - 4) }
		case .keyframe:
			lastKeyframeNs = arrival
			keyframesSeen += 1
		case .frame:
			break
		}

		if ringEnabledLocked || capture != nil {
			let slab: Slab
			if let last = slabs.last, last.capacity - last.used >= count {
				slab = last
			} else {
				slab = takeSlabLocked(atLeast: count)
				slabs.append(slab)
				totalCapacity += slab.capacity
			}
			memcpy(slab.base + slab.used, base, count)
			let flags = UInt32(min(max(framesLost, 0), 0xFFFF)) | (frameRecovered ? 1 << 16 : 0)
			let rec = Rec(offset: slab.used, length: count, arrivalNs: arrival, flags: flags, kind: kind)
			slab.records.append(rec)
			slab.used += count
			if kind == .keyframe { slab.keyframes += 1 }
			evictLocked(now: arrival)
			if let capture {
				(job, finishReason) = captureStepLocked(capture, slab: slab, rec: rec, now: arrival)
			}
		}

		if keyframeIntervalNs > 0, ringEnabledLocked,
		   arrival > max(lastKeyframeNs, lastKeyframeRequestNs) + keyframeIntervalNs {
			lastKeyframeRequestNs = arrival
			wantKeyframe = true
		}
		os_unfair_lock_unlock(lock)

		if wantKeyframe { keyframeRequester?.requestKeyframe() }
		if let job { ioQueue.async(execute: job) }
		if let finishReason { finishCapture(reason: finishReason, completion: nil) }
	}

	private func takeSlabLocked(atLeast count: Int) -> Slab {
		let size = slabSizeLocked
		if let spare = spareSlab {
			spareSlab = nil
			if count <= size, spare.capacity == size { return spare }
		}
		return Slab(capacity: max(size, count))
	}

	/// Drops the oldest slabs that are entirely outside the time window or over the byte limit.
	/// The newest slab always stays.
	private func evictLocked(now: UInt64) {
		let ringOn = ringEnabledLocked
		let windowNs = ringOn ? UInt64(limitsValue.seconds * 1e9) : 0
		let maxBytes = ringOn ? limitsValue.bytes : 0
		while slabs.count > 1 {
			let newestInOldest = slabs[0].records.last?.arrivalNs ?? 0
			guard newestInOldest + windowNs < now || totalCapacity > maxBytes else { break }
			var oldest = slabs.removeFirst()
			totalCapacity -= oldest.capacity
			// Reuse the memory unless a dump or a pending disk write still reads from it.
			if spareSlab == nil, oldest.capacity == slabSizeLocked, isKnownUniquelyReferenced(&oldest) {
				oldest.reset()
				spareSlab = oldest
			}
		}
	}

	/// First NAL units of the buffer decide what it is: parameter sets only (a stream header), a
	/// keyframe (IRAP picture for HEVC, IDR for H.264) or any other frame. Stops at the first
	/// slice, so the slice data itself is never scanned.
	private static func classify(_ base: UnsafePointer<UInt8>, count: Int, hevc: Bool) -> Kind {
		var sawParameterSet = false
		var i = 0
		while i + 3 < count {
			let b2 = base[i + 2]
			if b2 > 1 {
				i += 3
				continue
			}
			if b2 == 1 && base[i + 1] == 0 && base[i] == 0 {
				let header = base[i + 3]
				if header & 0x80 == 0 {
					if hevc {
						let type = (header >> 1) & 0x3F
						if type <= 31 { return (16...23).contains(type) ? .keyframe : .frame }
						if (32...34).contains(type) { sawParameterSet = true }
					} else {
						let type = header & 0x1F
						if (1...5).contains(type) { return type == 5 ? .keyframe : .frame }
						if type == 7 || type == 8 { sawParameterSet = true }
					}
				}
				i += 4
				continue
			}
			i += 1
		}
		return sawParameterSet ? .header : .frame
	}

	// MARK: Status (any thread)

	public var status: [String: Any] {
		let now = Self.nowNs()
		return locked {
			var out: [String: Any] = [
				"enabled": ringEnabledLocked,
				"limitSeconds": limitsValue.seconds,
				"limitBytes": limitsValue.bytes,
				"keyframeIntervalSeconds": Double(keyframeIntervalNs) / 1e9,
				"streaming": streaming,
				"buffersSeen": buffersSeen,
				"keyframesSeen": keyframesSeen,
				"bytesSeen": bytesSeen,
				"hasStreamHeader": !headers.isEmpty,
			]
			let records = slabs.reduce(0) { $0 + $1.records.count }
			let first = slabs.first?.records.first?.arrivalNs
			let reference = streaming ? now : lastArrivalNs
			out["bufferedRecords"] = records
			out["bufferedBytes"] = slabs.reduce(0) { $0 + $1.used }
			out["memoryBytes"] = totalCapacity + (spareSlab?.capacity ?? 0)
			out["bufferedSeconds"] = first.map { Self.seconds(from: $0, to: reference) } ?? 0
			out["bufferedKeyframes"] = slabs.reduce(0) { $0 + $1.keyframes }
			out["secondsSinceKeyframe"] = lastKeyframeNs > 0 ? Self.seconds(from: lastKeyframeNs, to: reference) : NSNull()
			if let capture {
				out["capture"] = [
					"path": capture.url.path,
					"phase": capture.phase == .writing ? "writing" : "waitingForKeyframe",
					"records": capture.records,
					"bytes": capture.bytes,
					"seconds": Self.seconds(from: capture.startedNs, to: now),
					"backlogBytes": capture.backlogBytes,
				] as [String: Any]
			} else {
				out["capture"] = NSNull()
			}
			return out
		}
	}

	public var isCapturing: Bool { locked { capture != nil } }

	private static func seconds(from start: UInt64, to end: UInt64) -> Double {
		end > start ? (Double(end - start) / 1e6).rounded() / 1000 : 0
	}

	// MARK: Dump of the in-memory window

	/// Writes the last `lastSeconds` of the stream (everything buffered when nil) to `url`.
	/// The file starts with the stream header and then the keyframe the requested span depends
	/// on, when the buffer still holds it. `completion` runs on the capture queue.
	public func dump(lastSeconds: Double?, to url: URL, completion: @escaping (Result<CaptureResult, Error>) -> Void) {
		let now = Self.nowNs()
		let wallNow = Date()
		let snapshot: (slabs: [(Slab, ContiguousArray<Rec>)], headers: [(arrivalNs: UInt64, data: Data)], profile: StreamProfile?, enabled: Bool, reference: UInt64) = locked {
			(slabs: slabs.map { ($0, $0.records) }, headers: headers, profile: profile, enabled: ringEnabledLocked, reference: streaming ? now : lastArrivalNs)
		}
		ioQueue.async { [self] in
			do {
				guard snapshot.enabled else { throw ControlError("the flight recorder is off (debug.flightRecorderSeconds is 0)") }
				var all: [(Slab, Rec)] = []
				for (slab, records) in snapshot.slabs { for rec in records { all.append((slab, rec)) } }
				guard !all.isEmpty else { throw ControlError("the flight recorder is empty: no stream data has arrived yet") }

				var warnings: [String] = []
				var first = 0
				if let lastSeconds, lastSeconds > 0 {
					let span = UInt64(lastSeconds * 1e9)
					let cut = snapshot.reference > span ? snapshot.reference - span : 0
					first = all.firstIndex { $0.1.arrivalNs >= cut } ?? all.count - 1
				}
				// A capture is only decodable from a keyframe: start at the one the requested span
				// depends on, or failing that at the first one inside the span.
				var startsWithKeyframe = true
				if let before = all[...first].lastIndex(where: { $0.1.kind == .keyframe }) {
					first = before
				} else if let after = all[first...].firstIndex(where: { $0.1.kind == .keyframe }) {
					first = after
				} else {
					startsWithKeyframe = false
					warnings.append("No keyframe in the buffered window: this capture does not start with a keyframe and cannot be decoded from its start. A keyframe was requested now, so a capture taken in a few seconds will start with one.")
				}
				let selected = all[first...]
				let startNs = selected.first!.1.arrivalNs
				let header = snapshot.headers.last { $0.arrivalNs <= startNs } ?? snapshot.headers.first
				if header == nil { warnings.append("No stream header (parameter sets) was seen in this session: the capture has none.") }
				let keyframes = selected.reduce(0) { $0 + ($1.1.kind == .keyframe ? 1 : 0) }
				let duration = Self.seconds(from: startNs, to: selected.last!.1.arrivalNs)

				var notes = notesProvider?() ?? [:]
				notes["kind"] = "flight-recorder dump"
				notes["requestedSeconds"] = lastSeconds ?? NSNull()
				notes["startsWithKeyframe"] = startsWithKeyframe
				notes["hasStreamHeader"] = header != nil
				notes["headerRecordRetimed"] = "the stream header record carries the arrival time of the first frame (0)"
				if !warnings.isEmpty { notes["warnings"] = warnings }
				let startedAt = wallNow.addingTimeInterval(-Double(now &- startNs) / 1e9)
				let writer = try StreamCaptureWriter(url: url, header: StreamCaptureHeader(
					profile: snapshot.profile ?? .ps5Max, startedAt: startedAt, notes: Self.notesText(notes)))
				do {
					if let header {
						try header.data.withUnsafeBytes { try writer.append(arrivalNanoseconds: 0, framesLost: 0, frameRecovered: false, bytes: $0) }
					}
					for (slab, rec) in selected {
						// A header buffer that is already the first record is not written twice.
						if rec.kind == .header, let header, rec.arrivalNs == header.arrivalNs { continue }
						try writer.append(
							arrivalNanoseconds: rec.arrivalNs - startNs, framesLost: Int(rec.flags & 0xFFFF), frameRecovered: rec.flags & (1 << 16) != 0,
							bytes: UnsafeRawBufferPointer(start: slab.base + rec.offset, count: rec.length))
					}
					try writer.close()
				} catch {
					try? writer.close()
					try? FileManager.default.removeItem(at: url)
					throw error
				}
				if !startsWithKeyframe { keyframeRequester?.requestKeyframe() }
				let result = CaptureResult(
					url: url, records: writer.recordCount, bytes: writer.bytesWritten, durationSeconds: duration,
					startsWithKeyframe: startsWithKeyframe, hasStreamHeader: header != nil, keyframes: keyframes, warnings: warnings)
				logHandler?("Stream capture written: \(url.lastPathComponent), \(result.records) records, \(String(format: "%.1f", duration)) s, \(result.bytes / 1024) KiB, starts with keyframe: \(startsWithKeyframe)")
				completion(.success(result))
			} catch {
				completion(.failure(error))
			}
		}
	}

	private static func notesText(_ notes: [String: Any]) -> String {
		let safe = JSONValue.sanitized(notes)
		guard let data = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(notes)" }
		return String(decoding: data, as: UTF8.self)
	}

	// MARK: Explicit capture to disk

	/// Starts writing the stream to `url` as it arrives. A keyframe is requested and the file
	/// begins with the stream header and that keyframe; if none arrives within
	/// `keyframeWaitSeconds` the capture starts with whatever arrived and says so in its notes.
	/// Ends at `stopCapture`, after `maxSeconds`, at `maxBytes`, or when the session ends.
	public func startCapture(to url: URL, maxSeconds: Double? = nil, maxBytes: Int64 = 4 << 30) throws {
		let now = Self.nowNs()
		try locked {
			guard capture == nil else { throw ControlError("a capture is already running: \(capture!.url.path)") }
			guard streaming else { throw ControlError("no stream is running") }
			let deadline = maxSeconds.flatMap { $0 > 0 ? now + UInt64($0 * 1e9) : nil }
			capture = DiskCapture(url: url, startedNs: now, deadlineNs: deadline, maxBytes: max(1 << 20, maxBytes))
			lastKeyframeRequestNs = now
		}
		keyframeRequester?.requestKeyframe()
	}

	/// Ends the explicit capture and reports the file. `completion` runs on the capture queue.
	public func stopCapture(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
		guard isCapturing else {
			completion(.failure(ControlError("no capture is running")))
			return
		}
		finishCapture(reason: nil, completion: completion)
	}

	/// Called with the lock held for every buffer while a capture is active. Returns the disk
	/// work for this buffer and, when a limit was reached, why the capture should end.
	private func captureStepLocked(_ capture: DiskCapture, slab: Slab, rec: Rec, now: UInt64) -> ((() -> Void)?, String?) {
		var items: [(Slab, Rec)] = []
		var opening = false
		switch capture.phase {
		case .waitingForKeyframe:
			if rec.kind == .keyframe {
				capture.startsWithKeyframe = true
				capture.pending.removeAll()
				items = [(slab, rec)]
				opening = true
			} else if rec.kind == .header {
				return (nil, nil) // goes in as the first record once the capture opens
			} else if now > capture.startedNs + UInt64(keyframeWaitSeconds * 1e9) {
				capture.warnings.append("No keyframe arrived within \(keyframeWaitSeconds) s of the request: this capture does not start with a keyframe and cannot be decoded from its start.")
				items = capture.pending + [(slab, rec)]
				capture.pending.removeAll()
				opening = true
			} else {
				capture.pending.append((slab, rec))
				return (nil, nil)
			}
		case .writing:
			items = [(slab, rec)]
		}

		var openJob: (() -> Void)?
		if opening { openJob = openCaptureLocked(capture, firstNs: items[0].1.arrivalNs, now: now) }
		let base = capture.baseNs
		var bytes = 0
		for (_, r) in items {
			bytes += r.length
			if r.kind == .keyframe { capture.keyframes += 1 }
		}
		capture.records += items.count
		capture.bytes += Int64(bytes)
		capture.backlogBytes += bytes
		capture.lastNs = rec.arrivalNs

		var reason: String?
		if let deadline = capture.deadlineNs, now >= deadline { reason = "the requested duration was reached" }
		if capture.bytes >= capture.maxBytes { reason = "the size limit was reached" }
		if capture.backlogBytes > Self.maxBacklogBytes {
			capture.warnings.append("The disk could not keep up; the capture was cut short.")
			reason = "the disk could not keep up"
		}

		let job: () -> Void = { [self] in
			openJob?()
			if let writer = capture.writer, capture.failure == nil {
				do {
					for (slab, r) in items {
						try writer.append(
							arrivalNanoseconds: r.arrivalNs &- base, framesLost: Int(r.flags & 0xFFFF), frameRecovered: r.flags & (1 << 16) != 0,
							bytes: UnsafeRawBufferPointer(start: slab.base + r.offset, count: r.length))
					}
				} catch {
					capture.failure = error.localizedDescription
				}
			}
			locked { capture.backlogBytes -= bytes }
		}
		return (job, reason)
	}

	/// Lock held. Fixes the capture's time base and returns the work that creates the file.
	private func openCaptureLocked(_ capture: DiskCapture, firstNs: UInt64, now: UInt64) -> () -> Void {
		capture.phase = .writing
		capture.baseNs = firstNs
		let header = headers.last { $0.arrivalNs <= firstNs } ?? headers.first
		capture.hasStreamHeader = header != nil
		if header == nil { capture.warnings.append("No stream header (parameter sets) was seen in this session: the capture has none.") }
		if header != nil { capture.records += 1 }
		let profile = self.profile ?? .ps5Max
		let startedAt = Date().addingTimeInterval(-Double(now &- firstNs) / 1e9)
		let startsWithKeyframe = capture.startsWithKeyframe
		let warnings = capture.warnings
		let limitSeconds = capture.deadlineNs.map { Double($0 - capture.startedNs) / 1e9 }
		return { [self] in
			var notes = notesProvider?() ?? [:]
			notes["kind"] = "explicit capture"
			notes["requestedSeconds"] = limitSeconds ?? NSNull()
			notes["startsWithKeyframe"] = startsWithKeyframe
			notes["hasStreamHeader"] = header != nil
			notes["headerRecordRetimed"] = "the stream header record carries the arrival time of the first frame (0)"
			if !warnings.isEmpty { notes["warnings"] = warnings }
			do {
				let writer = try StreamCaptureWriter(url: capture.url, header: StreamCaptureHeader(profile: profile, startedAt: startedAt, notes: Self.notesText(notes)))
				capture.writer = writer
				if let header {
					try header.data.withUnsafeBytes { try writer.append(arrivalNanoseconds: 0, framesLost: 0, frameRecovered: false, bytes: $0) }
				}
			} catch {
				capture.failure = error.localizedDescription
			}
		}
	}

	private func finishCapture(reason: String?, completion: ((Result<CaptureResult, Error>) -> Void)?) {
		let now = Self.nowNs()
		let taken: (DiskCapture, (() -> Void)?)? = locked {
			guard let capture else { return nil }
			self.capture = nil
			var flush: (() -> Void)?
			// Stopped before the keyframe (or the timeout) came: keep what did arrive.
			if capture.phase == .waitingForKeyframe, !capture.pending.isEmpty {
				capture.warnings.append("Stopped before a keyframe arrived: this capture does not start with a keyframe and cannot be decoded from its start.")
				let items = capture.pending
				capture.pending.removeAll()
				let open = openCaptureLocked(capture, firstNs: items[0].1.arrivalNs, now: now)
				let base = capture.baseNs
				capture.records += items.count
				capture.lastNs = items.last!.1.arrivalNs
				for (_, r) in items { capture.bytes += Int64(r.length) }
				flush = {
					open()
					guard let writer = capture.writer, capture.failure == nil else { return }
					do {
						for (slab, r) in items {
							try writer.append(
								arrivalNanoseconds: r.arrivalNs &- base, framesLost: Int(r.flags & 0xFFFF), frameRecovered: r.flags & (1 << 16) != 0,
								bytes: UnsafeRawBufferPointer(start: slab.base + r.offset, count: r.length))
						}
					} catch {
						capture.failure = error.localizedDescription
					}
				}
			}
			if !ringEnabledLocked { evictLocked(now: now) }
			return (capture, flush)
		}
		guard let (capture, flush) = taken else { return }
		let summary: (records: Int, duration: Double, startsWithKeyframe: Bool, hasHeader: Bool, keyframes: Int, warnings: [String]) = locked {
			(records: capture.records, duration: Self.seconds(from: capture.baseNs, to: capture.lastNs), startsWithKeyframe: capture.startsWithKeyframe,
			 hasHeader: capture.hasStreamHeader, keyframes: capture.keyframes, warnings: capture.warnings)
		}
		ioQueue.async { [self] in
			flush?()
			let outcome: Result<CaptureResult, Error>
			if let failure = capture.failure {
				try? capture.writer?.close()
				outcome = .failure(ControlError("capture failed: \(failure)"))
			} else if let writer = capture.writer {
				do {
					try writer.close()
					outcome = .success(CaptureResult(
						url: capture.url, records: writer.recordCount, bytes: writer.bytesWritten, durationSeconds: summary.duration,
						startsWithKeyframe: summary.startsWithKeyframe, hasStreamHeader: summary.hasHeader, keyframes: summary.keyframes, warnings: summary.warnings))
				} catch {
					outcome = .failure(ControlError("capture failed: \(error.localizedDescription)"))
				}
			} else {
				outcome = .failure(ControlError("the capture ended before any stream data arrived; no file was written"))
			}
			switch outcome {
			case .success(let result):
				logHandler?("Stream capture finished\(reason.map { " (\($0))" } ?? ""): \(result.url.lastPathComponent), \(result.records) records, \(String(format: "%.1f", result.durationSeconds)) s, \(result.bytes / 1024) KiB, starts with keyframe: \(result.startsWithKeyframe)")
			case .failure(let error):
				logHandler?("Stream capture ended without a file\(reason.map { " (\($0))" } ?? ""): \(error.localizedDescription)")
			}
			lastFinished = outcome
			completion?(outcome)
		}
	}

	/// Outcome of the most recent explicit capture that ended by itself (duration or size limit,
	/// session end). Capture queue.
	private var lastFinished: Result<CaptureResult, Error>?

	/// The result of the last explicit capture, for a capture that ended on its own.
	public func lastCaptureResult(completion: @escaping (Result<CaptureResult, Error>?) -> Void) {
		ioQueue.async { [self] in completion(lastFinished) }
	}
}
