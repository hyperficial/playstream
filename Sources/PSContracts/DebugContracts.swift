import Foundation

// Contracts for the built-in debugging tools: live tuning, per-frame traces, output captures
// and stream captures that can be replayed offline. They exist so problems can be diagnosed
// and parameters tried from outside the app while a session keeps running.

// MARK: - Video debugging

/// Implemented by the video pipeline. Every method may be called from any thread and must not
/// stall the stream.
public protocol VideoDebugControlling: AnyObject {
	/// Every runtime-adjustable internal parameter with its current value (pacing, frame
	/// generation and scaler constants that would otherwise need a rebuild to change).
	func debugTunables() -> [String: Double]

	/// Changes one parameter while streaming. Returns false for an unknown name or a value
	/// outside the accepted range.
	func setDebugTunable(_ name: String, to value: Double) -> Bool

	/// Writes the per-frame trace of the last `lastSeconds` seconds as JSON Lines (one object per
	/// frame or event: arrival, decode, scheduling, presentation, and for generated pictures the
	/// outcome and reason). Returns the number of records written.
	func writeFrameTrace(to url: URL, lastSeconds: Double) throws -> Int

	/// Saves the next `count` pictures exactly as they are sent to the display (after upscaling,
	/// including generated ones) as image files in `directory`, and calls `completion` with the
	/// files written. Must not disturb presentation timing more than unavoidable.
	func capturePresentedFrames(count: Int, to directory: URL, completion: @escaping @Sendable ([URL]) -> Void)
}

// MARK: - Stream capture file

/// A recording of the encoded video stream exactly as the protocol core delivered it, with the
/// arrival time of every buffer, so a real session can be replayed offline with its true timing.
///
/// Layout: the ASCII line `PSCAP1\n`, one line of JSON (`StreamCaptureHeader`) ending in `\n`,
/// then records until the end of the file. Each record is little-endian:
/// `UInt64 arrivalNanoseconds` (since the first record), `UInt32 flags`, `UInt32 byteCount`,
/// then `byteCount` bytes (one Annex-B buffer as passed to `VideoStreamSink`).
/// Flags: bits 0-15 `framesLost`, bit 16 `frameRecovered`.
public struct StreamCaptureHeader: Codable, Sendable, Equatable {
	public var profile: StreamProfile
	/// Wall-clock time of the first record.
	public var startedAt: Date
	/// Free-form notes (settings in effect, what the capture is for).
	public var notes: String

	public init(profile: StreamProfile, startedAt: Date, notes: String = "") {
		self.profile = profile
		self.startedAt = startedAt
		self.notes = notes
	}
}

public struct StreamCaptureRecord: Sendable, Equatable {
	/// Arrival time relative to the first record.
	public var arrivalNanoseconds: UInt64
	public var framesLost: Int
	public var frameRecovered: Bool
	/// One Annex-B buffer. The first record of a capture is the stream header (parameter sets).
	public var data: Data

	public init(arrivalNanoseconds: UInt64, framesLost: Int, frameRecovered: Bool, data: Data) {
		self.arrivalNanoseconds = arrivalNanoseconds
		self.framesLost = framesLost
		self.frameRecovered = frameRecovered
		self.data = data
	}
}

public enum StreamCaptureError: Error, LocalizedError {
	case notACaptureFile
	case truncated

	public var errorDescription: String? {
		switch self {
		case .notACaptureFile: return "Not a PlayStream stream capture file."
		case .truncated: return "The stream capture file is cut off."
		}
	}
}

public enum StreamCaptureFile {
	static let magic = Data("PSCAP1\n".utf8)

	/// Writes a complete capture. Records must be in arrival order.
	public static func write(header: StreamCaptureHeader, records: [StreamCaptureRecord], to url: URL) throws {
		var out = magic
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		out.append(try encoder.encode(header))
		out.append(0x0A)
		for record in records {
			var arrival = record.arrivalNanoseconds.littleEndian
			var flags = (UInt32(min(max(record.framesLost, 0), 0xFFFF)) | (record.frameRecovered ? 1 << 16 : 0)).littleEndian
			var count = UInt32(record.data.count).littleEndian
			withUnsafeBytes(of: &arrival) { out.append(contentsOf: $0) }
			withUnsafeBytes(of: &flags) { out.append(contentsOf: $0) }
			withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
			out.append(record.data)
		}
		try out.write(to: url, options: .atomic)
	}

	/// Reads a complete capture into memory.
	public static func read(from url: URL) throws -> (header: StreamCaptureHeader, records: [StreamCaptureRecord]) {
		let data = try Data(contentsOf: url, options: .mappedIfSafe)
		guard data.starts(with: magic) else { throw StreamCaptureError.notACaptureFile }
		var offset = data.startIndex + magic.count
		guard let newline = data[offset...].firstIndex(of: 0x0A) else { throw StreamCaptureError.truncated }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let header = try decoder.decode(StreamCaptureHeader.self, from: data[offset..<newline])
		offset = newline + 1

		var records: [StreamCaptureRecord] = []
		while offset < data.endIndex {
			guard offset + 16 <= data.endIndex else { throw StreamCaptureError.truncated }
			let arrival = data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
			let flags = data[offset + 8..<offset + 12].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
			let count = Int(data[offset + 12..<offset + 16].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
			offset += 16
			guard offset + count <= data.endIndex else { throw StreamCaptureError.truncated }
			records.append(StreamCaptureRecord(
				arrivalNanoseconds: arrival,
				framesLost: Int(flags & 0xFFFF),
				frameRecovered: flags & (1 << 16) != 0,
				data: Data(data[offset..<offset + count])
			))
			offset += count
		}
		return (header, records)
	}
}
