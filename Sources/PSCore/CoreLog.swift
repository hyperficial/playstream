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

	public static var fileURL: URL {
		FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
			.appendingPathComponent("Logs/PlayStream/core.log")
	}

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
	public static func install(levels: Level = .standard, echoToStderr: Bool = false, ownCoreCallback: Bool = true) {
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
