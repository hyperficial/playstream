import Foundation

/// A settings store for the test host that never goes near the preferences system: values
/// live in memory and, when a file is given, in a property list under the host's own
/// directory (so a relaunched host finds them again). The code under test only sees a
/// `UserDefaults`.
final class HarnessDefaults: UserDefaults {
	private let fileURL: URL?
	private let lock = NSLock()
	private var values: [String: Any] = [:]

	init(fileURL: URL?) {
		self.fileURL = fileURL
		// A suite name nobody else uses; nothing is ever stored under it because every accessor
		// the tools use is overridden below.
		super.init(suiteName: "dev.playstream.harness.unused")!
		if let fileURL, let data = try? Data(contentsOf: fileURL),
		   let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
			values = stored
		}
	}

	private func save() {
		guard let fileURL else { return }
		let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
		try? data?.write(to: fileURL, options: .atomic)
	}

	/// Forgets everything (and the file).
	func reset() {
		lock.withLock {
			values.removeAll()
			if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
		}
	}

	override func object(forKey defaultName: String) -> Any? {
		lock.withLock { values[defaultName] }
	}

	override func set(_ value: Any?, forKey defaultName: String) {
		lock.withLock {
			values[defaultName] = value
			save()
		}
	}

	override func removeObject(forKey defaultName: String) {
		lock.withLock {
			values[defaultName] = nil
			save()
		}
	}

	override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
	override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
	override func set(_ value: Float, forKey defaultName: String) { set(Double(value) as Any?, forKey: defaultName) }
	override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }

	override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
	override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0 }
	override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
	override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
}
