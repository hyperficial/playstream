import CPSBridge
import Foundation
import PSContracts

public enum WakeError: LocalizedError, Equatable {
	case noAddress
	case invalidRegistKey
	case sendFailed(String)
	case timedOut(seconds: Int)

	public var errorDescription: String? {
		switch self {
		case .noAddress: return "The console's address is unknown."
		case .invalidRegistKey: return "The saved pairing for this console is damaged."
		case let .sendFailed(reason): return "Could not send the wake signal: \(reason)."
		case let .timedOut(seconds): return "The console did not wake up within \(seconds) seconds."
		}
	}

	public var recoverySuggestion: String? {
		switch self {
		case .noAddress: return "Turn the console on once with the PS button so this Mac can find it on the network."
		case .invalidRegistKey: return "Remove the console and pair it again."
		case .sendFailed: return "Check that this Mac is on the same network as the console."
		case .timedOut: return "On the PS5, enable Settings > System > Power Saving > Features Available in Rest Mode > Stay Connected to the Internet and Enable Turning On PS5 from Network."
		}
	}
}

/// Sends the wake packet (`ps_wakeup`) to a registered console in rest mode.
/// `address` defaults to the host's `lastKnownAddress`.
public func wake(host: RegisteredHost, address: String? = nil) throws {
	guard let address = address ?? host.lastKnownAddress, !address.isEmpty else { throw WakeError.noAddress }
	guard host.registKey.count == 16 else { throw WakeError.invalidRegistKey }
	let code: Int32 = address.withCString { cHost in
		host.registKey.withUnsafeBytes { raw in
			ps_wakeup(cHost, raw.bindMemory(to: UInt8.self).baseAddress, host.isPS5)
		}
	}
	guard code == 0 else { throw WakeError.sendFailed(bridgeErrorString(code)) }
}

extension DiscoveryService {
	/// Wakes `host` and waits until discovery reports it ready. Returns immediately if it already
	/// is. The wake packet is re-sent every few seconds while waiting (harmless, and helps when
	/// the first packet is lost). A PS5 typically needs 10-30 s to come out of rest mode.
	public func wakeAndWaitUntilReady(_ host: RegisteredHost, timeout: TimeInterval = 60, resendInterval: TimeInterval = 5) async throws -> DiscoveredHost {
		start()
		if let ready = self.host(id: host.id), ready.state == .ready { return ready }

		// Give discovery a moment to find the console so we use its current address.
		if self.host(id: host.id) == nil {
			_ = await waitForHost(timeout: 2) { $0.id == host.id }
		}
		let deadline = Date().addingTimeInterval(timeout)
		var lastSend = Date.distantPast
		while Date() < deadline {
			try Task.checkCancellation()
			let current = self.host(id: host.id)
			if let current, current.state == .ready { return current }
			if Date().timeIntervalSince(lastSend) >= resendInterval {
				let address = current?.address ?? host.lastKnownAddress
				guard let address else { throw WakeError.noAddress }
				try wake(host: host, address: address)
				lastSend = Date()
			}
			try await Task.sleep(nanoseconds: 250_000_000)
		}
		throw WakeError.timedOut(seconds: Int(timeout))
	}
}
