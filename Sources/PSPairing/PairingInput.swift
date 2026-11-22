import Foundation
import PSContracts

/// Protocol target values (opaque to the rest of the app; mirrors chiaki `ChiakiTarget`).
public enum ConsoleTarget {
	public static let ps4v8: UInt32 = 800
	public static let ps4v9: UInt32 = 900
	public static let ps4v10: UInt32 = 1000
	public static let ps5Unknown: UInt32 = 1_000_000
	public static let ps5v1: UInt32 = 1_000_100

	public static func isPS5(_ target: UInt32) -> Bool { target >= ps5Unknown }

	/// The target to register with. chiaki only sends a valid `RP-Version` header for known
	/// targets, so an unknown PS5 (or an unset target on a host we know is a PS5) is mapped to
	/// PS5 1.0, which every PS5 firmware accepts.
	public static func forRegistration(_ target: UInt32, isPS5: Bool) -> UInt32 {
		if isPS5 && (target == ps5Unknown || target < ps5Unknown) { return ps5v1 }
		if target == 0 { return ps4v10 }
		return target
	}
}

/// Validation of what the user types during pairing.
public enum PairingInput {
	/// Normalises a console id / MAC to 12 uppercase hex digits. Accepts separators
	/// (`00:a1:b2:c3:d4:e5`, `00-A1-…`). Returns nil if it is not exactly 6 bytes of hex.
	public static func normalizeHostID(_ raw: String?) -> String? {
		guard let raw else { return nil }
		let hex = raw.uppercased().filter { $0.isHexDigit && $0.isASCII }
		let separators = raw.filter { !$0.isHexDigit }
		guard hex.count == 12, separators.allSatisfy({ ":-. ".contains($0) }) else { return nil }
		return hex
	}

	public static func hostID(fromMAC mac: Data) -> String? {
		guard mac.count == 6 else { return nil }
		return mac.map { String(format: "%02X", $0) }.joined()
	}

	/// The 8 digit "Link Device" PIN. Spaces, dashes and other separators are tolerated
	/// (the PS5 shows it as "1234 5678"). Leading zeros are significant digits but the
	/// protocol sends the PIN as a number, as chiaki does (`pin.toULong()`).
	public static func parsePIN(_ text: String) throws -> UInt32 {
		let stripped = text.filter { !$0.isWhitespace && $0 != "-" }
		guard !stripped.isEmpty else { throw RegistrationError.invalidPIN("Enter the 8 digit PIN shown on the console.") }
		guard stripped.allSatisfy(\.isASCIIDigit) else {
			throw RegistrationError.invalidPIN("The PIN can only contain digits.")
		}
		guard stripped.count == 8, let value = UInt32(stripped) else {
			throw RegistrationError.invalidPIN("The PIN has 8 digits; you entered \(stripped.count).")
		}
		return value
	}

	/// The optional 4 digit console login PIN ("Console Pin" in chiaki). Empty / nil = none (0).
	public static func parseConsolePIN(_ text: String?) throws -> UInt32 {
		let stripped = (text ?? "").filter { !$0.isWhitespace }
		if stripped.isEmpty { return 0 }
		guard stripped.count == 4, stripped.allSatisfy(\.isASCIIDigit), let value = UInt32(stripped) else {
			throw RegistrationError.invalidConsolePIN
		}
		return value
	}

	/// Address sanity check (IPv4, IPv6 or hostname). The core resolves it with getaddrinfo.
	public static func normalizeAddress(_ text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace || $0 == "/" }) else { return nil }
		return trimmed
	}
}
