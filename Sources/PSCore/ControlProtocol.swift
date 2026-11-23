import Foundation

// The control channel's wire format and the JSON helpers shared by the server, the command
// router and the hosts (the app and the headless test host).
//
// One request and one response per connection, each a single line of JSON:
//
//   request   {"cmd": "settings", "args": ["set", "stream.upscaler", "3"], "opts": {"wait": true}}
//   response  {"ok": true, "result": { ... }}        or        {"ok": false, "error": "why"}

public struct ControlRequest {
	public var command: String
	/// Positional arguments, always strings (as typed on a command line).
	public var args: [String]
	/// Named options. Values are JSON scalars.
	public var options: [String: Any]

	public init(command: String, args: [String] = [], options: [String: Any] = [:]) {
		self.command = command
		self.args = args
		self.options = options
	}

	/// Parses one request line. Also accepts a bare command line ("stats", "tune name 3") so the
	/// socket can be driven with nothing but `nc -U`.
	public static func parse(_ data: Data) throws -> ControlRequest {
		let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { throw ControlError("empty request") }
		if text.hasPrefix("{") {
			guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
				throw ControlError("request is not a JSON object")
			}
			guard let command = object["cmd"] as? String, !command.isEmpty else { throw ControlError("request has no \"cmd\"") }
			let args = (object["args"] as? [Any] ?? []).map { ControlRequest.text(of: $0) }
			return ControlRequest(command: command, args: args, options: object["opts"] as? [String: Any] ?? [:])
		}
		var words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
		let command = words.removeFirst()
		return ControlRequest(command: command, args: words)
	}

	static func text(of value: Any) -> String {
		switch value {
		case let s as String: return s
		case let n as NSNumber:
			if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
			return n.stringValue
		default: return "\(value)"
		}
	}

	// MARK: Typed access

	public func arg(_ index: Int) -> String? { index < args.count ? args[index] : nil }

	public func double(_ name: String) -> Double? {
		// Not-a-number never gets through: every caller compares or converts the result.
		switch options[name] {
		case let n as NSNumber: return n.doubleValue.isNaN ? nil : n.doubleValue
		case let s as String: return Double(s).flatMap { $0.isNaN ? nil : $0 }
		default: return nil
		}
	}

	public func int(_ name: String) -> Int? { double(name).flatMap { $0.isFinite ? Int(min(max($0, -1e15), 1e15)) : nil } }

	public func string(_ name: String) -> String? {
		guard let value = options[name], !(value is NSNull) else { return nil }
		return ControlRequest.text(of: value)
	}

	public func flag(_ name: String) -> Bool {
		switch options[name] {
		case let n as NSNumber: return n.boolValue
		case let s as String: return ["1", "true", "yes", "on"].contains(s.lowercased())
		default: return false
		}
	}
}

/// An error whose text is sent back to the client as is.
public struct ControlError: Error, LocalizedError, CustomStringConvertible {
	public var message: String
	public init(_ message: String) { self.message = message }
	public var errorDescription: String? { message }
	public var description: String { message }
}

public struct ControlResponse {
	public var ok: Bool
	public var result: Any?
	public var error: String?

	public static func success(_ result: Any = [String: Any]()) -> ControlResponse {
		ControlResponse(ok: true, result: result, error: nil)
	}

	public static func failure(_ message: String) -> ControlResponse {
		ControlResponse(ok: false, result: nil, error: message)
	}

	/// One line of JSON, newline terminated. Never fails: anything that cannot be encoded is
	/// replaced by its description.
	public func encoded() -> Data {
		var object: [String: Any] = ["ok": ok]
		if let result { object["result"] = JSONValue.sanitized(result) }
		if let error { object["error"] = error }
		var data = JSONValue.encode(object) ?? Data(#"{"ok":false,"error":"response could not be encoded"}"#.utf8)
		data.append(0x0A)
		return data
	}
}

/// Turns arbitrary Swift values into JSON-compatible ones.
public enum JSONValue {
	private static let dateFormatter: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()

	public static func string(from date: Date) -> String { dateFormatter.string(from: date) }

	/// Compact JSON for an already sanitized value, or nil when it still is not valid JSON.
	/// `JSONSerialization` raises an Objective-C exception for an invalid object, which would
	/// take the whole process down, so validity is checked first.
	public static func encode(_ object: Any) -> Data? {
		guard JSONSerialization.isValidJSONObject(object) else { return nil }
		return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
	}

	/// A JSON-safe copy of a value built from dictionaries, arrays and scalars: non-finite
	/// numbers become null, dates ISO 8601, URLs paths, anything unknown its description.
	public static func sanitized(_ value: Any) -> Any {
		switch value {
		case let dict as [String: Any]:
			return dict.mapValues { sanitized($0) }
		case let array as [Any]:
			return array.map { sanitized($0) }
		case let s as String:
			return s
		case let n as NSNumber:
			if CFGetTypeID(n) != CFBooleanGetTypeID(), !n.doubleValue.isFinite { return NSNull() }
			return n
		case is NSNull:
			return value
		case let d as Date:
			return string(from: d)
		case let u as URL:
			return u.isFileURL ? u.path : u.absoluteString
		case let d as Data:
			return d.base64EncodedString()
		default:
			return reflect(value)
		}
	}

	/// Converts any value to JSON by reflection: every stored property of a struct becomes a
	/// key, optionals become the value or null, enums their raw value or case name. This is how
	/// the complete stats structures are reported without a hand-written field list that would
	/// go stale whenever a field is added.
	public static func reflect(_ value: Any) -> Any {
		switch value {
		case let v as Bool: return v
		case let v as Int: return v
		case let v as Int8: return Int(v)
		case let v as Int16: return Int(v)
		case let v as Int32: return Int(v)
		case let v as Int64: return v
		case let v as UInt: return v
		case let v as UInt8: return Int(v)
		case let v as UInt16: return Int(v)
		case let v as UInt32: return v
		case let v as UInt64: return v
		case let v as Double: return v.isFinite ? rounded(v) : NSNull()
		case let v as Float: return v.isFinite ? rounded(Double(v)) : NSNull()
		case let v as CGFloat: return v.isFinite ? rounded(Double(v)) : NSNull()
		case let v as String: return v
		case let v as Date: return string(from: v)
		case let v as URL: return v.isFileURL ? v.path : v.absoluteString
		case let v as Data: return v.base64EncodedString()
		case is NSNull: return NSNull()
		default: break
		}
		let mirror = Mirror(reflecting: value)
		switch mirror.displayStyle {
		case .optional:
			guard let child = mirror.children.first else { return NSNull() }
			return reflect(child.value)
		case .collection, .set:
			return mirror.children.map { reflect($0.value) }
		case .dictionary:
			var out: [String: Any] = [:]
			for child in mirror.children {
				let pair = Mirror(reflecting: child.value).children.map(\.value)
				guard pair.count == 2 else { continue }
				out["\(pair[0])"] = reflect(pair[1])
			}
			return out
		case .struct, .class:
			if mirror.children.isEmpty { return "\(value)" }
			var out: [String: Any] = [:]
			var index = 0
			for child in mirror.children {
				out[child.label ?? "_\(index)"] = reflect(child.value)
				index += 1
			}
			return out
		case .tuple:
			return mirror.children.map { reflect($0.value) }
		case .enum:
			if let raw = value as? any RawRepresentable { return reflect(raw.rawValue) }
			// A case with a payload shows as `name(payload)`; keep that readable form.
			return "\(value)"
		default:
			return "\(value)"
		}
	}

	/// Keeps numbers short in the output (six decimals is far below anything we measure).
	private static func rounded(_ v: Double) -> Double {
		guard abs(v) < 1e12 else { return v }
		return (v * 1_000_000).rounded() / 1_000_000
	}
}
