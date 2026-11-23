import Foundation

/// Every user setting the app keeps in UserDefaults: its key, type, accepted values, default
/// and when a change takes effect. The control channel reads and writes settings through this
/// table, so a value set from the terminal is validated exactly like one chosen in the settings
/// panel, and the response can say whether it is live or waits for the next connection.
///
/// The keys and defaults mirror the `@AppStorage` declarations in `App/AppSettings.swift`; the
/// test host (`ps-core-harness selftest`) checks that the two agree.
public struct SettingDescriptor: Sendable {
	public enum Kind: Sendable, Equatable {
		case bool
		/// Whole number in `range`. `names` lets a value be given by name ("fsr1" for 3).
		case int(range: ClosedRange<Int>, allowed: [Int]?, names: [String: Int])
		case double(range: ClosedRange<Double>)
	}

	public enum Applies: String, Sendable {
		/// Takes effect at once, also in the middle of a session.
		case live
		/// Used when the next session is opened (`psctl reconnect` applies it).
		case nextConnection = "next connection"
		/// Read when the app starts.
		case nextLaunch = "next launch"
	}

	public var key: String
	public var kind: Kind
	public var defaultValue: Double
	public var applies: Applies
	public var summary: String

	public var typeName: String {
		switch kind {
		case .bool: return "bool"
		case .int: return "int"
		case .double: return "double"
		}
	}
}

public enum SettingsCatalog {
	private static func bool(_ key: String, _ value: Bool, _ applies: SettingDescriptor.Applies, _ summary: String) -> SettingDescriptor {
		SettingDescriptor(key: key, kind: .bool, defaultValue: value ? 1 : 0, applies: applies, summary: summary)
	}

	private static func int(_ key: String, _ value: Int, _ range: ClosedRange<Int>, allowed: [Int]? = nil, names: [String: Int] = [:], _ applies: SettingDescriptor.Applies, _ summary: String) -> SettingDescriptor {
		SettingDescriptor(key: key, kind: .int(range: range, allowed: allowed, names: names), defaultValue: Double(value), applies: applies, summary: summary)
	}

	private static func double(_ key: String, _ value: Double, _ range: ClosedRange<Double>, _ applies: SettingDescriptor.Applies, _ summary: String) -> SettingDescriptor {
		SettingDescriptor(key: key, kind: .double(range: range), defaultValue: value, applies: applies, summary: summary)
	}

	public static let all: [SettingDescriptor] = [
		// Stream request (what we ask the console for)
		int("stream.resolution", 1080, 540...1080, allowed: [1080, 720, 540], .nextConnection, "Stream height: 1080, 720 or 540."),
		int("stream.fps", 60, 30...60, allowed: [60, 30], .nextConnection, "Stream frame rate: 60 or 30."),
		double("stream.bitrateMbps", 30, 2...100, .nextConnection, "Requested video bitrate, Mbit/s."),
		int("stream.codec", 2, 0...2, names: ["h264": 0, "hevc": 1, "hdr": 2, "hevchdr": 2], .nextConnection, "0 H.264, 1 HEVC, 2 HEVC HDR."),
		bool("stream.dualsense", true, .nextConnection, "Ask for DualSense haptics and adaptive triggers."),
		bool("stream.hapticsAsRumble", true, .nextConnection, "Play the haptics stream through the rumble motors."),
		int("stream.startBitrateHint", 0, 0...2, names: ["off": 0, "a": 1, "b": 2], .nextConnection, "Experimental start-bitrate hint: 0 off, 1 variant A, 2 variant B."),
		bool("stream.startFullscreen", true, .nextConnection, "Enter full screen when a session starts."),

		// Presentation (live)
		int("stream.upscaler", 0, 0...3, names: ["off": 0, "bicubic": 1, "metalfx": 2, "fsr1": 3, "fsr": 3], .live, "0 off, 1 bicubic, 2 MetalFX, 3 FSR 1. Switches to the Metal renderer."),
		double("stream.upscalerSharpness", 0.5, 0...1, .live, "FSR 1 sharpening, 0 (none) to 1."),
		int("stream.frameGeneration", 0, 0...2, names: ["off": 0, "to60": 1, "60": 1, "to120": 2, "120": 2], .live, "0 off, 1 fill 30 fps content to 60, 2 double to 120."),
		double("stream.frameGenerationMaxDelay", 45, 0...200, .live, "Most delay frame generation may add, ms (the panel offers 30 to 70)."),
		int("stream.frameGenerationMethod", 0, 0...1, names: ["extrapolate": 0, "predict": 0, "interpolate": 1, "inbetween": 1], .live, "0 predict ahead, 1 in-between pictures."),
		bool("stream.lowLatencyRenderer", false, .live, "Use the Metal renderer even without upscaling or frame generation."),
		bool("stream.framePacing", true, .live, "Show frames on a steady cadence instead of on arrival."),
		int("stream.statsLevel", 0, 0...2, names: ["off": 0, "compact": 1, "full": 2], .live, "Stats overlay: 0 off, 1 compact, 2 full."),
		double("audio.volume", 1, 0...1, .live, "Game audio volume, 0 to 1."),

		// Controller (live)
		double("controller.lightBrightness", 0.4, 0...1, .live, "Light bar brightness, 0 to 1."),
		bool("controller.playerLEDs", true, .live, "Player number lights."),
		double("controller.rumbleStrength", 1, 0...1, .live, "Rumble strength, 0 to 1."),
		bool("controller.motion", true, .live, "Read the motion sensors."),
		bool("controller.keyboard", true, .live, "Keyboard as controller."),

		// Debugging tools
		bool("debug.controlChannel", true, .live, "The local control socket psctl talks to. Turning it off from psctl cuts psctl off."),
		double("debug.flightRecorderSeconds", 60, 0...600, .live, "Seconds of encoded video kept in memory for `psctl capture`. 0 turns the flight recorder off."),
		int("debug.flightRecorderMegabytes", 256, 16...4096, .live, "Memory bound of the flight recorder, MiB."),
		double("debug.flightRecorderKeyframeSeconds", 0, 0...600, .live, "Request a keyframe whenever none arrived for this long, so every capture is decodable from its start. 0 never asks (no extra load on the stream)."),
		bool("debug.hitchNotes", true, .live, "Write a `Hitch:` line into the log when a visible hitch is detected."),
		double("debug.hitchFrameFactor", 2.5, 1.2...20, .live, "A picture that stays on screen this many times longer than normal counts as a hitch."),
		int("debug.maxDiskMegabytes", 4096, 64...200_000, .live, "Size bound of the debug directory, MiB. The oldest files are deleted first."),

		// No-click restart
		bool("resume.autoReconnect", true, .nextLaunch, "At launch, reconnect to the console that was streaming when the app last quit or crashed. (`psctl relaunch` always brings its session back.)"),
		double("resume.windowSeconds", 900, 0...86_400, .nextLaunch, "How long after a quit (or crash) a launch still resumes the session, seconds. Later than that, the owner was done playing. 0: never."),
	]

	private static let byKey: [String: SettingDescriptor] = Dictionary(uniqueKeysWithValues: all.map { ($0.key, $0) })

	/// Looks a setting up by its full key, or by the part after the dot when that is unambiguous
	/// ("upscaler" finds "stream.upscaler").
	public static func descriptor(for name: String) -> SettingDescriptor? {
		if let exact = byKey[name] { return exact }
		let lowered = name.lowercased()
		let matches = all.filter { $0.key.lowercased() == lowered || $0.key.lowercased().hasSuffix("." + lowered) }
		return matches.count == 1 ? matches[0] : nil
	}

	// MARK: Reading

	public static func value(of descriptor: SettingDescriptor, in defaults: UserDefaults) -> Any {
		let stored = defaults.object(forKey: descriptor.key)
		switch descriptor.kind {
		case .bool:
			if let n = stored as? NSNumber { return n.boolValue }
			if let s = stored as? String, let b = parseBool(s) { return b }
			return descriptor.defaultValue != 0
		case .int:
			if let n = stored as? NSNumber { return n.intValue }
			if let s = stored as? String, let i = Int(s) { return i }
			return Int(descriptor.defaultValue)
		case .double:
			if let n = stored as? NSNumber { return n.doubleValue }
			if let s = stored as? String, let d = Double(s) { return d }
			return descriptor.defaultValue
		}
	}

	public static func bool(_ key: String, in defaults: UserDefaults) -> Bool {
		guard let d = byKey[key] else { return false }
		return value(of: d, in: defaults) as? Bool ?? false
	}

	public static func int(_ key: String, in defaults: UserDefaults) -> Int {
		guard let d = byKey[key] else { return 0 }
		return value(of: d, in: defaults) as? Int ?? 0
	}

	public static func double(_ key: String, in defaults: UserDefaults) -> Double {
		guard let d = byKey[key] else { return 0 }
		return value(of: d, in: defaults) as? Double ?? 0
	}

	/// key -> current value for every setting.
	public static func snapshot(_ defaults: UserDefaults) -> [String: Any] {
		var out: [String: Any] = [:]
		for d in all { out[d.key] = value(of: d, in: defaults) }
		return out
	}

	/// Full listing for `settings get`: value, default, type, range and when a change applies.
	public static func listing(_ defaults: UserDefaults) -> [[String: Any]] {
		all.map { describe($0, in: defaults) }
	}

	public static func describe(_ d: SettingDescriptor, in defaults: UserDefaults) -> [String: Any] {
		var out: [String: Any] = [
			"key": d.key, "value": value(of: d, in: defaults), "type": d.typeName,
			"applies": d.applies.rawValue, "summary": d.summary,
			"isDefault": defaults.object(forKey: d.key) == nil,
		]
		switch d.kind {
		case .bool:
			out["default"] = d.defaultValue != 0
		case .int(let range, let allowed, let names):
			out["default"] = Int(d.defaultValue)
			if let allowed { out["allowed"] = allowed } else { out["range"] = [range.lowerBound, range.upperBound] }
			if !names.isEmpty { out["names"] = names }
		case .double(let range):
			out["default"] = d.defaultValue
			out["range"] = [range.lowerBound, range.upperBound]
		}
		return out
	}

	/// A value that changes whenever any setting changes. Lets the app notice edits made from
	/// outside its process (`defaults write`), which post no change notification in the app.
	public static func fingerprint(_ defaults: UserDefaults) -> String {
		all.map { "\(value(of: $0, in: defaults))" }.joined(separator: "|")
	}

	// MARK: Writing

	public struct Change {
		public var descriptor: SettingDescriptor
		public var oldValue: Any
		public var newValue: Any
		public var changed: Bool
	}

	private static func parseBool(_ text: String) -> Bool? {
		switch text.lowercased() {
		case "1", "true", "yes", "on": return true
		case "0", "false", "no", "off": return false
		default: return nil
		}
	}

	/// Checks `text` against the setting's type and range without storing anything. Returns the
	/// setting and the typed value (nil for "default", which means: remove the stored value).
	/// Throws a `ControlError` explaining what is accepted when the value is not.
	public static func parse(_ name: String, _ text: String) throws -> (descriptor: SettingDescriptor, value: Any?) {
		guard let d = descriptor(for: name) else {
			let close = all.map(\.key).filter { $0.lowercased().contains(name.lowercased()) }
			throw ControlError("unknown setting \"\(name)\"" + (close.isEmpty ? "; `settings get` lists them all" : "; did you mean \(close.joined(separator: ", "))?"))
		}
		let trimmed = text.trimmingCharacters(in: .whitespaces)
		if trimmed.lowercased() == "default" { return (d, nil) }
		switch d.kind {
		case .bool:
			guard let value = parseBool(trimmed) else { throw ControlError("\(d.key) is on or off; \"\(text)\" is neither (use true/false, on/off, 1/0)") }
			return (d, value)
		case .int(let range, let allowed, let names):
			let value: Int
			if let named = names[trimmed.lowercased()] {
				value = named
			} else if let number = Int(trimmed) {
				value = number
			} else if let number = Double(trimmed), number == number.rounded(), abs(number) < 1e9 {
				value = Int(number)
			} else {
				let hint = names.isEmpty ? "" : " or one of " + names.keys.sorted().joined(separator: ", ")
				throw ControlError("\(d.key) takes a whole number\(hint); got \"\(text)\"")
			}
			if let allowed {
				guard allowed.contains(value) else { throw ControlError("\(d.key) must be one of \(allowed.map(String.init).joined(separator: ", ")); got \(value)") }
			} else {
				guard range.contains(value) else { throw ControlError("\(d.key) must be between \(range.lowerBound) and \(range.upperBound); got \(value)") }
			}
			return (d, value)
		case .double(let range):
			guard let value = Double(trimmed), value.isFinite else { throw ControlError("\(d.key) takes a number; got \"\(text)\"") }
			guard range.contains(value) else { throw ControlError("\(d.key) must be between \(range.lowerBound) and \(range.upperBound); got \(value)") }
			return (d, value)
		}
	}

	/// Validates `text` for the setting and stores it with the same type the app's own settings
	/// code uses. "default" removes the stored value.
	public static func set(_ name: String, to text: String, in defaults: UserDefaults) throws -> Change {
		let (d, parsed) = try parse(name, text)
		let old = value(of: d, in: defaults)
		switch parsed {
		case nil: defaults.removeObject(forKey: d.key)
		case let v as Bool: defaults.set(v, forKey: d.key)
		case let v as Int: defaults.set(v, forKey: d.key)
		case let v as Double: defaults.set(v, forKey: d.key)
		default: break
		}
		let new = value(of: d, in: defaults)
		return Change(descriptor: d, oldValue: old, newValue: new, changed: "\(old)" != "\(new)")
	}
}
