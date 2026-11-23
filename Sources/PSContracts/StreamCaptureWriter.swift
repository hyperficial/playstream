import Foundation

/// Writes a `StreamCaptureFile` (PSCAP1) record by record, so a long capture never has to sit in
/// memory as one buffer. The result is byte-for-byte what `StreamCaptureFile.write` produces
/// for the same header and records, and `StreamCaptureFile.read` reads it back.
///
/// Not thread-safe: use it from one queue. Nothing here may run on a stream (network) thread,
/// every call does file I/O.
public final class StreamCaptureWriter {
	public let url: URL
	public private(set) var recordCount = 0
	/// Bytes written so far, header included.
	public private(set) var bytesWritten: Int64 = 0

	private var handle: FileHandle?

	/// Creates (or truncates) the file and writes the magic line and the header line.
	public init(url: URL, header: StreamCaptureHeader) throws {
		self.url = url
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
			throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
		}
		let handle = try FileHandle(forWritingTo: url)
		self.handle = handle
		var out = StreamCaptureFile.magic
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		out.append(try encoder.encode(header))
		out.append(0x0A)
		try handle.write(contentsOf: out)
		bytesWritten = Int64(out.count)
	}

	deinit { try? handle?.close() }

	/// Appends one record. `bytes` is one Annex-B buffer as passed to `VideoStreamSink`.
	public func append(arrivalNanoseconds: UInt64, framesLost: Int, frameRecovered: Bool, bytes: UnsafeRawBufferPointer) throws {
		guard let handle else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
		var out = Data(capacity: 16 + bytes.count)
		var arrival = arrivalNanoseconds.littleEndian
		var flags = (UInt32(min(max(framesLost, 0), 0xFFFF)) | (frameRecovered ? 1 << 16 : 0)).littleEndian
		var count = UInt32(bytes.count).littleEndian
		withUnsafeBytes(of: &arrival) { out.append(contentsOf: $0) }
		withUnsafeBytes(of: &flags) { out.append(contentsOf: $0) }
		withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }
		if let base = bytes.baseAddress, bytes.count > 0 {
			out.append(base.assumingMemoryBound(to: UInt8.self), count: bytes.count)
		}
		try handle.write(contentsOf: out)
		recordCount += 1
		bytesWritten += Int64(out.count)
	}

	public func append(_ record: StreamCaptureRecord) throws {
		try record.data.withUnsafeBytes {
			try append(arrivalNanoseconds: record.arrivalNanoseconds, framesLost: record.framesLost, frameRecovered: record.frameRecovered, bytes: $0)
		}
	}

	/// Flushes and closes the file. Safe to call more than once.
	public func close() throws {
		guard let handle else { return }
		self.handle = nil
		try handle.close()
	}
}
