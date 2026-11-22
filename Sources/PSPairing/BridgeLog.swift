import CPSBridge
import Foundation
import os

/// Routes the protocol core's log (`ps_log_set_callback`, process wide) to observers.
///
/// Registration only reports success / failed / canceled; *why* it failed (console refused,
/// wrong PIN, timeout, ...) is only in the core log, so `Registrar` listens here to produce a
/// message a human can act on.
///
/// The level mask is clamped to error | warning | info on purpose: at verbose level the core
/// hex dumps the decrypted registration response, which contains the session keys.
///
/// Note: `ps_log_set_callback` is process wide. If another module installs its own callback
/// after this one, registration errors fall back to a generic message.
public final class BridgeLog: @unchecked Sendable {
	public static let shared = BridgeLog()

	public struct Line: Sendable {
		public let level: UInt32
		public let message: String
	}

	private let lock = NSLock()
	private var observers: [UUID: @Sendable (Line) -> Void] = [:]
	private var installed = false
	/// Also print core log lines to stderr (handy in the harness).
	public var echoToStderr: Bool {
		get { lock.withLock { _echo } }
		set { lock.withLock { _echo = newValue } }
	}
	private var _echo = false
	private let logger = Logger(subsystem: "PlayStream", category: "core")

	private init() {}

	/// Installs the bridge log callback (idempotent; reinstalls if `force`).
	public func install(force: Bool = false) {
		let shouldInstall: Bool = lock.withLock {
			if installed && !force { return false }
			installed = true
			return true
		}
		guard shouldInstall else { return }
		let mask = PS_LOG_ERROR | PS_LOG_WARNING | PS_LOG_INFO
		ps_log_set_callback(bridgeLogCallback, Unmanaged.passUnretained(self).toOpaque(), mask)
	}

	@discardableResult
	public func addObserver(_ observer: @escaping @Sendable (Line) -> Void) -> UUID {
		let id = UUID()
		lock.withLock { observers[id] = observer }
		return id
	}

	public func removeObserver(_ id: UUID) {
		_ = lock.withLock { observers.removeValue(forKey: id) }
	}

	fileprivate func deliver(level: UInt32, message: String) {
		let line = Line(level: level, message: message)
		let (targets, echo) = lock.withLock { (Array(observers.values), _echo) }
		switch level {
		case PS_LOG_ERROR: logger.error("\(message, privacy: .public)")
		case PS_LOG_WARNING: logger.warning("\(message, privacy: .public)")
		default: logger.info("\(message, privacy: .public)")
		}
		if echo {
			let tag = level == PS_LOG_ERROR ? "E" : level == PS_LOG_WARNING ? "W" : "I"
			FileHandle.standardError.write(Data("[core \(tag)] \(message)\n".utf8))
		}
		for observer in targets { observer(line) }
	}
}

private let bridgeLogCallback: PSLogCallback = { level, msg, user in
	guard let user, let msg else { return }
	// Never let verbose/debug output through, even if the mask was widened elsewhere.
	guard level & (PS_LOG_VERBOSE | PS_LOG_DEBUG) == 0 else { return }
	let log = Unmanaged<BridgeLog>.fromOpaque(user).takeUnretainedValue()
	log.deliver(level: level, message: String(cString: msg))
}

/// `ps_error_string` as a Swift string.
func bridgeErrorString(_ code: Int32) -> String {
	guard let s = ps_error_string(code) else { return "error \(code)" }
	return String(cString: s)
}
