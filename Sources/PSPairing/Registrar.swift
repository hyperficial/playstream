import CPSBridge
import Foundation
import PSContracts

/// Pairs this Mac with a console showing the "Link Device" PIN.
///
/// ```swift
/// let host = try await Registrar().register(host: discovered, account: account, pin: "1234 5678", consolePin: nil)
/// store.upsert(host)
/// ```
public final class Registrar: Sendable {
	public init() {}

	/// Registers with `host`. Throws `RegistrationError` (or `CancellationError` if the task was
	/// cancelled before the console answered). Inputs are validated before anything is sent.
	///
	/// If the task is cancelled after the console already accepted the PIN, the registered host
	/// is still returned: the console now considers this Mac paired, so it should be saved.
	public func register(host: DiscoveredHost, account: PSNAccount, pin: String, consolePin: String?) async throws -> RegisteredHost {
		let pinValue = try PairingInput.parsePIN(pin)
		let consolePinValue = try PairingInput.parseConsolePIN(consolePin)
		guard account.accountID.count == 8 else { throw RegistrationError.invalidAccountID }
		guard let address = PairingInput.normalizeAddress(host.address) else {
			throw RegistrationError.invalidAddress(host.address)
		}
		if host.state == .standby { throw RegistrationError.consoleAsleep }
		try Task.checkCancellation()

		let target = ConsoleTarget.forRegistration(host.target, isPS5: host.isPS5)
		let attempt = RegistAttempt(expectedHostID: host.id, fallbackName: host.name, isPS5: ConsoleTarget.isPS5(target), address: address)

		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RegisteredHost, Error>) in
				attempt.begin(continuation: continuation, target: target, accountID: account.accountID, pin: pinValue, consolePin: consolePinValue)
			}
		} onCancel: {
			attempt.cancel()
		}
	}
}

/// One registration run. Owns the `PSRegist*` and the callback context.
///
/// Lifetime rules (PSBridge.h): the callback fires exactly once on a worker thread;
/// `ps_regist_destroy` must be called exactly once, never from inside the callback, and it
/// cancels + joins the worker. The context is retained (Unmanaged) from start until destroy has
/// returned, so the callback can never see a dangling pointer.
///
/// `finish()` runs exactly once, off the callback thread, triggered by whichever comes last of
/// "ps_regist_start returned" and "callback fired", or by cancellation.
private final class RegistAttempt: @unchecked Sendable {
	enum Outcome {
		case success(RegisteredHost)
		case failed
		case canceled
	}

	let expectedHostID: String
	let fallbackName: String
	let isPS5: Bool
	let address: String

	private let lock = NSLock()
	private var continuation: CheckedContinuation<RegisteredHost, Error>?
	private var regist: OpaquePointer?
	private var startReturned = false
	private var outcome: Outcome?
	private var cancelRequested = false
	private var finishClaimed = false
	private var logObserver: UUID?
	private var logLines: [String] = []

	init(expectedHostID: String, fallbackName: String, isPS5: Bool, address: String) {
		self.expectedHostID = expectedHostID
		self.fallbackName = fallbackName
		self.isPS5 = isPS5
		self.address = address
	}

	func begin(continuation: CheckedContinuation<RegisteredHost, Error>, target: UInt32, accountID: Data, pin: UInt32, consolePin: UInt32) {
		lock.lock()
		self.continuation = continuation
		let alreadyCancelled = cancelRequested
		lock.unlock()
		if alreadyCancelled {
			resume(.failure(CancellationError()))
			return
		}

		BridgeLog.shared.install()
		let observer = BridgeLog.shared.addObserver { [weak self] line in self?.record(line) }
		lock.withLock { logObserver = observer }

		let user = Unmanaged.passRetained(self).toOpaque()
		var err: Int32 = 0
		let handle: OpaquePointer? = address.withCString { cHost in
			accountID.withUnsafeBytes { raw in
				ps_regist_start(cHost, target, raw.bindMemory(to: UInt8.self).baseAddress, pin, consolePin, registCallback, user, &err)
			}
		}

		guard let handle else {
			// The callback never fires if start failed.
			Unmanaged<RegistAttempt>.fromOpaque(user).release()
			removeLogObserver()
			resume(.failure(RegistrationError.startFailed(bridgeErrorString(err))))
			return
		}

		lock.lock()
		regist = handle
		startReturned = true
		let shouldFinish = outcome != nil || cancelRequested
		lock.unlock()
		if shouldFinish { scheduleFinish() }
	}

	func cancel() {
		lock.lock()
		cancelRequested = true
		let canDestroyNow = startReturned
		lock.unlock()
		// ps_regist_destroy cancels the worker; its CANCELED callback then just records.
		if canDestroyNow { scheduleFinish() }
		// Otherwise begin() sees cancelRequested once start returns (or before starting).
	}

	/// Called on the worker thread from inside the C callback.
	fileprivate func callbackFired(result: Int32, host: UnsafePointer<PSRegisteredHost>?) {
		let outcome: Outcome
		if result == PS_REGIST_RESULT_SUCCESS, let host {
			outcome = .success(makeRegisteredHost(host.pointee))
		} else if result == PS_REGIST_RESULT_CANCELED {
			outcome = .canceled
		} else {
			outcome = .failed
		}
		lock.lock()
		self.outcome = outcome
		let shouldFinish = startReturned
		lock.unlock()
		// Never destroy from inside the callback: hop to another thread.
		if shouldFinish { scheduleFinish() }
	}

	private func scheduleFinish() {
		lock.lock()
		if finishClaimed {
			lock.unlock()
			return
		}
		finishClaimed = true
		lock.unlock()
		DispatchQueue.global(qos: .userInitiated).async { self.finish() }
	}

	private func finish() {
		let handle = lock.withLock { regist }
		if let handle {
			ps_regist_destroy(handle) // joins the worker; callback has fired once this returns
		}
		removeLogObserver()
		let (outcome, cancelled, lines) = lock.withLock { (self.outcome, cancelRequested, logLines) }
		// Balance passRetained from begin(). `self` stays alive through this method's frame.
		Unmanaged.passUnretained(self).release()

		switch outcome {
		case let .success(host):
			resume(.success(host))
		case .canceled, .none:
			resume(.failure(cancelled ? CancellationError() : RegistrationError.diagnose(logLines: lines, address: address)))
		case .failed:
			resume(.failure(cancelled ? CancellationError() : RegistrationError.diagnose(logLines: lines, address: address)))
		}
	}

	private func resume(_ result: Result<RegisteredHost, Error>) {
		let continuation = lock.withLock { () -> CheckedContinuation<RegisteredHost, Error>? in
			defer { self.continuation = nil }
			return self.continuation
		}
		continuation?.resume(with: result)
	}

	private func record(_ line: BridgeLog.Line) {
		let text = line.message
		guard text.range(of: "regist", options: .caseInsensitive) != nil
			|| text.range(of: "refused", options: .caseInsensitive) != nil
			|| text.contains("Application Reason") else { return }
		lock.withLock {
			if logLines.count < 200 { logLines.append(text) }
		}
	}

	private func removeLogObserver() {
		if let id = lock.withLock({ () -> UUID? in defer { logObserver = nil }; return logObserver }) {
			BridgeLog.shared.removeObserver(id)
		}
	}

	private func makeRegisteredHost(_ raw: PSRegisteredHost) -> RegisteredHost {
		var raw = raw
		let mac = withUnsafeBytes(of: &raw.server_mac) { Data($0) }
		let registKey = withUnsafeBytes(of: &raw.rp_regist_key) { Data($0) }
		let rpKey = withUnsafeBytes(of: &raw.rp_key) { Data($0) }
		let nickname = withUnsafeBytes(of: &raw.server_nickname) { buffer -> String in
			let bytes = buffer.prefix { $0 != 0 }
			return String(decoding: bytes, as: UTF8.self)
		}
		let id = PairingInput.hostID(fromMAC: mac).flatMap { $0 == "000000000000" ? nil : $0 } ?? expectedHostID
		return RegisteredHost(
			id: id,
			nickname: nickname.isEmpty ? fallbackName : nickname,
			isPS5: ConsoleTarget.isPS5(raw.target) || isPS5,
			target: raw.target,
			registKey: registKey,
			rpKey: rpKey,
			rpKeyType: raw.rp_key_type,
			serverMAC: mac,
			lastKnownAddress: address
		)
	}
}

private let registCallback: PSRegistCallback = { result, host, user in
	guard let user else { return }
	Unmanaged<RegistAttempt>.fromOpaque(user).takeUnretainedValue().callbackFired(result: result, host: host)
}

/// Errors from pairing, phrased for the person holding the controller.
public enum RegistrationError: LocalizedError, Equatable {
	case invalidPIN(String)
	case invalidConsolePIN
	case invalidAccountID
	case invalidAddress(String)
	case consoleAsleep
	case startFailed(String)
	/// The console actively refused: its Link Device screen is not open.
	case linkScreenNotOpen
	/// Nothing answered at the address within the timeout.
	case consoleNotResponding(address: String)
	/// macOS blocked the connection (Local Network privacy).
	case localNetworkDenied
	case wrongPIN
	case accountRejected
	case remotePlayInUse
	case versionMismatch
	case consoleRejected(detail: String)
	case failed(detail: String?)

	public var errorDescription: String? {
		switch self {
		case let .invalidPIN(message): return message
		case .invalidConsolePIN: return "The console login PIN has 4 digits. Leave it empty if you don't use one."
		case .invalidAccountID: return "The PSN account ID is not set up correctly (it must be 8 bytes)."
		case let .invalidAddress(address): return "\"\(address)\" is not a valid console address."
		case .consoleAsleep: return "The console is in rest mode."
		case let .startFailed(reason): return "Pairing could not start: \(reason)."
		case .linkScreenNotOpen: return "The console refused the connection."
		case let .consoleNotResponding(address): return "No console answered at \(address)."
		case .localNetworkDenied: return "macOS blocked PlayStream from talking to devices on your network."
		case .wrongPIN: return "The console did not accept the PIN."
		case .accountRejected: return "The console did not accept the PSN account ID."
		case .remotePlayInUse: return "Remote Play is already in use on the console."
		case .versionMismatch: return "The console rejected this Remote Play protocol version."
		case let .consoleRejected(detail): return "The console rejected the pairing (\(detail))."
		case let .failed(detail):
			if let detail { return "Pairing failed: \(detail)" }
			return "Pairing failed."
		}
	}

	public var recoverySuggestion: String? {
		switch self {
		case .invalidPIN, .invalidConsolePIN, .invalidAddress, .startFailed:
			return nil
		case .invalidAccountID, .accountRejected:
			return "Set up the account again by signing in with the same PSN account that is signed in on the PS5. The account ID must belong to a user on that console."
		case .consoleAsleep:
			return "Turn the PS5 on (press the PS button) and open Settings > System > Remote Play > Link Device."
		case .linkScreenNotOpen:
			return "On the PS5, open Settings > System > Remote Play > Link Device and keep that screen with the PIN open while you pair."
		case .consoleNotResponding:
			return "Check that the PS5 is on, on the same network as this Mac, and showing the Link Device screen. Make sure Settings > System > Remote Play > Enable Remote Play is on."
		case .localNetworkDenied:
			return "Open System Settings > Privacy & Security > Local Network and turn PlayStream on, then try again."
		case .wrongPIN:
			return "The PIN changes every few minutes and after each attempt. Back out of Link Device on the PS5, open it again and enter the new PIN."
		case .remotePlayInUse:
			return "Disconnect the other Remote Play device and try again."
		case .versionMismatch:
			return "Update the PS5 system software and try again."
		case .consoleRejected, .failed:
			return "Open Link Device again on the PS5 to get a fresh PIN and retry. If it keeps failing, restart Remote Play on the console."
		}
	}

	/// Maps the core's log output for a failed attempt to an actionable error.
	public static func diagnose(logLines: [String], address: String) -> RegistrationError {
		let joined = logLines.joined(separator: "\n")
		func has(_ s: String) -> Bool { joined.range(of: s, options: .caseInsensitive) != nil }

		if has("0x80108b09") { return .wrongPIN }
		if has("0x80108b02") { return .accountRejected }
		if has("0x80108b10") { return .remotePlayInUse }
		if has("0x80108b11") { return .versionMismatch }
		if has("refused the registration search") || has("Connection refused") { return .linkScreenNotOpen }
		if has("No route to host") || has("Host is unreachable") || has("Operation not permitted") { return .localNetworkDenied }
		if has("timed out waiting for search response") || has("failed to connect for search") { return .consoleNotResponding(address: address) }
		if has("getaddrinfo") { return .invalidAddress(address) }
		if let line = logLines.last(where: { $0.contains("HTTP code") }) {
			if let reason = logLines.last(where: { $0.contains("Application Reason") }) {
				return .consoleRejected(detail: reason.components(separatedBy: "Application Reason: ").last ?? reason)
			}
			return .consoleRejected(detail: line.components(separatedBy: "Regist ").last ?? line)
		}
		if has("timed out") { return .consoleNotResponding(address: address) }
		return .failed(detail: logLines.last)
	}
}
