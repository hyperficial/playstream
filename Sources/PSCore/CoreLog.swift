import CPSBridge
import Foundation
import os

/// Routes the protocol core's log lines to the unified log and to a rotating file at
/// ~/Library/Logs/PlayStream/core.log, so a failed connection can be diagnosed afterwards.
public enum CoreLog {
	public struct Level: OptionSet, Sendable {
		public let rawValue: UInt32
		public init(rawValue: UInt32) { self.rawValue = rawValue }
		public static let error = Level(rawValue: 1)
		public static let warning = Level(rawValue: 2)
		public static let info = Level(rawValue: 4)
		public static let verbose = Level(rawValue: 8)
		public static let debug = Level(rawValue: 16)
		public static let standard: Level = [.error, .warning, .info]
	}

	/// Where the log is written. `~/Library/Logs/PlayStream/core.log` unless `install` was given
	/// another directory (the headless test host does that, so it never writes into the log of a
	/// running app).
	public static var fileURL: URL {
		directoryLock.lock()
		defer { directoryLock.unlock() }
		return (directoryOverride ?? defaultDirectory).appendingPathComponent("core.log")
	}

	public static var defaultDirectory: URL {
		FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Logs/PlayStream", isDirectory: true)
	}

	private static let directoryLock = NSLock()
	private static var directoryOverride: URL?

	private static let logger = Logger(subsystem: "playstream", category: "core")
	private static let queue = DispatchQueue(label: "playstream.corelog")
	private static var file: FileHandle?
	private static var echoToStderr = false
	private static let maxFileSize: UInt64 = 8 * 1024 * 1024
	private static let formatter: DateFormatter = {
		let f = DateFormatter()
		f.dateFormat = "HH:mm:ss.SSS"
		return f
	}()

	/// Opens the log file. Call once at launch.
	///
	/// The core's log callback is process-wide and has exactly one owner. By default this
	/// function takes it. An app that also uses PSPairing must pass `ownCoreCallback: false`,
	/// let `BridgeLog` own the callback (pairing needs the lines to explain failures) and
	/// forward its lines here with `record(level:message:)`.
	public static func install(levels: Level = .standard, echoToStderr: Bool = false, ownCoreCallback: Bool = true, directory: URL? = nil) {
		if let directory {
			directoryLock.lock()
			directoryOverride = directory
			directoryLock.unlock()
		}
		queue.sync {
			self.echoToStderr = echoToStderr
			let url = fileURL
			try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
			if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64, size > maxFileSize {
				let old = url.deletingPathExtension().appendingPathExtension("old.log")
				try? FileManager.default.removeItem(at: old)
				try? FileManager.default.moveItem(at: url, to: old)
			}
			if !FileManager.default.fileExists(atPath: url.path) {
				FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
			}
			file = try? FileHandle(forWritingTo: url)
			_ = try? file?.seekToEnd()
		}
		if ownCoreCallback {
			ps_log_set_callback({ level, msg, _ in
				guard let msg else { return }
				CoreLog.write(level: level, message: String(cString: msg), unified: true)
			}, nil, levels.rawValue)
		}
		write(level: 4, message: "──── log started ────", unified: false)
	}

	/// A line from the app itself.
	public static func note(_ message: String) {
		write(level: 4, message: message, unified: true)
	}

	/// A core log line forwarded by whoever owns the core callback (already in the unified log).
	public static func record(level: UInt32, message: String) {
		write(level: level, message: message, unified: false)
	}

	/// Returns once every line passed to the log so far is in the file.
	public static func flush() {
		queue.sync { try? file?.synchronize() }
	}

	/// The last `count` lines of the log file, oldest first. With `matching`, only lines
	/// containing that text (case-insensitive; `a|b` means either) count. Reads at most the last `maxBytes` of the
	/// file, so it stays cheap however large the log is. Does file I/O: not for stream threads.
	public static func tail(lines count: Int, matching: String? = nil, maxBytes: Int = 4 * 1024 * 1024) -> [String] {
		guard count > 0 else { return [] }
		flush()
		guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
		defer { try? handle.close() }
		let size = (try? handle.seekToEnd()) ?? 0
		// "a|b" matches lines containing a or b.
		let needles = (matching ?? "").lowercased().split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		func wanted(_ line: String) -> Bool {
			guard !needles.isEmpty else { return true }
			let lowered = line.lowercased()
			return needles.contains { lowered.contains($0) }
		}
		var collected: [String] = []
		var end = size
		var carry = Data()
		// Walk backwards in chunks until enough lines are found.
		let chunk: UInt64 = 256 * 1024
		var scanned = 0
		while end > 0, collected.count < count, scanned < maxBytes {
			let start = end > chunk ? end - chunk : 0
			guard (try? handle.seek(toOffset: start)) != nil, var data = try? handle.read(upToCount: Int(end - start)) else { break }
			scanned += data.count
			data.append(carry)
			var pieces = data.split(separator: 0x0A, omittingEmptySubsequences: false)
			// The first piece may be the tail of a line that starts in the previous chunk.
			carry = start > 0 ? Data(pieces.removeFirst()) : Data()
			for piece in pieces.reversed() where !piece.isEmpty {
				let line = String(decoding: piece, as: UTF8.self)
				if !wanted(line) { continue }
				collected.append(line)
				if collected.count == count { break }
			}
			end = start
		}
		if end == 0, collected.count < count, !carry.isEmpty {
			let line = String(decoding: carry, as: UTF8.self)
			if wanted(line) { collected.append(line) }
		}
		return collected.reversed()
	}

	private static func write(level: UInt32, message: String, unified: Bool) {
		let tag: String
		switch level {
		case 1: tag = "E"
		case 2: tag = "W"
		case 4: tag = "I"
		default: tag = "D"
		}
		if unified {
			switch level {
			case 1: logger.error("\(message, privacy: .public)")
			case 2: logger.warning("\(message, privacy: .public)")
			case 4: logger.info("\(message, privacy: .public)")
			default: logger.debug("\(message, privacy: .public)")
			}
		}
		let now = Date()
		queue.async {
			let line = "\(formatter.string(from: now)) [\(tag)] \(message)\n"
			if echoToStderr { FileHandle.standardError.write(Data(line.utf8)) }
			try? file?.write(contentsOf: Data(line.utf8))
		}
	}
}
