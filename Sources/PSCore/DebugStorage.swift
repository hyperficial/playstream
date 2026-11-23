import Foundation

/// Where the debugging tools put their files (stream captures, frame traces, captured pictures)
/// and the housekeeping that keeps that directory from growing without bound.
///
/// Layout: `<root>/captures/*.pscap`, `<root>/traces/*.jsonl`, `<root>/frames/<stamp>/…`.
/// Does file I/O: never call from a stream thread.
public struct DebugStorage: Sendable {
	public enum Area: String, CaseIterable, Sendable {
		case captures
		case traces
		case frames
	}

	public let root: URL

	/// `~/Library/Application Support/PlayStream/debug`
	public static var defaultRoot: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return base.appendingPathComponent("PlayStream/debug", isDirectory: true)
	}

	public init(root: URL = DebugStorage.defaultRoot) {
		self.root = root
	}

	public func directory(_ area: Area) -> URL {
		root.appendingPathComponent(area.rawValue, isDirectory: true)
	}

	private static func stamp() -> String {
		let f = DateFormatter()
		f.locale = Locale(identifier: "en_US_POSIX")
		f.dateFormat = "yyyyMMdd-HHmmss-SSS"
		return f.string(from: Date())
	}

	/// A new, not yet existing file path in `area`, named `<prefix>-<timestamp>.<ext>`.
	public func newFile(in area: Area, prefix: String, extension ext: String) throws -> URL {
		let dir = directory(area)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		return dir.appendingPathComponent("\(prefix)-\(Self.stamp()).\(ext)")
	}

	/// A new, empty directory in `area`, named `<prefix>-<timestamp>`.
	public func newDirectory(in area: Area, prefix: String) throws -> URL {
		let dir = directory(area).appendingPathComponent("\(prefix)-\(Self.stamp())", isDirectory: true)
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		return dir
	}

	public struct CleanupResult: Sendable, Equatable {
		public var removedItems = 0
		public var freedBytes: Int64 = 0
		public var remainingBytes: Int64 = 0
		public var remainingItems = 0
	}

	/// Deletes the oldest items (a capture file, a trace file or one directory of pictures)
	/// until everything fits in `maxBytes`. Items in `protecting` and anything modified within
	/// the last `graceSeconds` (a capture still being written) are never removed.
	@discardableResult
	public func cleanup(maxBytes: Int64, protecting: [URL] = [], graceSeconds: TimeInterval = 120) -> CleanupResult {
		let fm = FileManager.default
		let protected = Set(protecting.map { $0.standardizedFileURL.path })
		var items: [(url: URL, size: Int64, modified: Date)] = []
		for area in Area.allCases {
			let dir = directory(area)
			guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { continue }
			for entry in entries {
				let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
				let (size, newest) = Self.measure(entry, isDirectory: values?.isDirectory ?? false)
				items.append((entry, size, max(newest, values?.contentModificationDate ?? .distantPast)))
			}
		}
		var result = CleanupResult()
		var total = items.reduce(Int64(0)) { $0 + $1.size }
		let now = Date()
		for item in items.sorted(by: { $0.modified < $1.modified }) {
			guard total > maxBytes else { break }
			if protected.contains(item.url.standardizedFileURL.path) { continue }
			if now.timeIntervalSince(item.modified) < graceSeconds { continue }
			guard (try? fm.removeItem(at: item.url)) != nil else { continue }
			total -= item.size
			result.removedItems += 1
			result.freedBytes += item.size
		}
		result.remainingBytes = total
		result.remainingItems = items.count - result.removedItems
		return result
	}

	/// Total size and item count per area.
	public func usage() -> [String: Any] {
		let fm = FileManager.default
		var out: [String: Any] = ["root": root.path]
		var total: Int64 = 0
		for area in Area.allCases {
			var size: Int64 = 0
			var count = 0
			if let entries = try? fm.contentsOfDirectory(at: directory(area), includingPropertiesForKeys: [.isDirectoryKey]) {
				for entry in entries {
					let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
					size += Self.measure(entry, isDirectory: isDirectory).size
					count += 1
				}
			}
			out[area.rawValue] = ["items": count, "bytes": size] as [String: Any]
			total += size
		}
		out["totalBytes"] = total
		return out
	}

	private static func measure(_ url: URL, isDirectory: Bool) -> (size: Int64, newest: Date) {
		let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
		if !isDirectory {
			let values = try? url.resourceValues(forKeys: keys)
			return (Int64(values?.fileSize ?? 0), values?.contentModificationDate ?? .distantPast)
		}
		var size: Int64 = 0
		var newest = Date.distantPast
		if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) {
			for case let file as URL in walker {
				guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
				size += Int64(values.fileSize ?? 0)
				if let modified = values.contentModificationDate, modified > newest { newest = modified }
			}
		}
		return (size, newest)
	}
}
