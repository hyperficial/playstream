import Combine
import Foundation
import PSContracts
import PSCore
import PSInput
import PSPairing
import SwiftUI

/// App-wide state: the paired consoles, discovery, the controller, and the running stream.
@MainActor
final class AppModel: ObservableObject {
	let settings = AppSettings()
	let discovery = DiscoveryService()
	let store = HostStore()
	let input = ControllerInput()

	@Published var stream: StreamController?
	@Published var connectingHostID: String?
	@Published var connectProgress: String?
	@Published var lastError: String?

	private var connectTask: Task<Void, Never>?
	private var observers: Set<AnyCancellable> = []

	init() {
		// One owner for the core's process-wide log callback: BridgeLog (pairing reads the lines
		// to explain failures). Everything is mirrored into ~/Library/Logs/PlayStream/core.log.
		CoreLog.install(ownCoreCallback: false)
		BridgeLog.shared.install()
		_ = BridgeLog.shared.addObserver { line in
			CoreLog.record(level: line.level, message: line.message)
		}
		store.track(discovery)
		// Leave a trail of what discovery sees, so a "console not found" report can be diagnosed.
		discovery.$hosts
			.map { hosts in hosts.map { "\($0.name) \($0.address) \($0.state.rawValue)" }.sorted() }
			.removeDuplicates()
			.sink { CoreLog.note("Discovery: \($0.isEmpty ? "no consoles" : $0.joined(separator: ", "))") }
			.store(in: &observers)
		discovery.start()
		input.start()
		input.installKeyboardMonitor()
	}

	func connect(to entry: ConsoleEntry) {
		guard stream == nil, connectingHostID == nil else { return }
		guard let host = entry.registered else { return }
		guard let account = store.account else {
			lastError = "Sign in to PSN first (person icon in the toolbar). The console only accepts sessions from the account it was paired with."
			return
		}
		guard var address = entry.address else {
			lastError = "\(entry.name) was not found on this network."
			return
		}

		lastError = nil
		connectingHostID = host.id
		connectProgress = "Connecting…"
		connectTask = Task { [weak self] in
			guard let self else { return }
			defer {
				self.connectingHostID = nil
				self.connectProgress = nil
			}
			do {
				if entry.state == .standby {
					self.connectProgress = "Waking console…"
					let ready = try await self.discovery.wakeAndWaitUntilReady(host, timeout: 75)
					address = ready.address
					// The console answers discovery a little before it accepts sessions.
					try await Task.sleep(nanoseconds: 2_000_000_000)
				}
				try Task.checkCancellation()
				self.connectProgress = "Connecting…"
				let configuration = SessionConfiguration(
					host: host,
					address: address,
					account: account,
					profile: self.settings.profile(isPS5: host.isPS5),
					enableDualSense: self.settings.dualSenseFeatures && host.isPS5
				)
				let controller = StreamController(configuration: configuration, settings: self.settings, input: self.input)
				controller.onEnded = { [weak self, weak controller] reason, isError in
					guard let self, let controller, self.stream === controller else { return }
					self.stream = nil
					if isError { self.lastError = "Session ended: \(reason)" }
				}
				try controller.start()
				self.stream = controller
			} catch is CancellationError {
			} catch {
				self.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
			}
		}
	}

	func cancelConnect() {
		connectTask?.cancel()
	}

	func wake(_ entry: ConsoleEntry) {
		guard let host = entry.registered else { return }
		do {
			try PSPairing.wake(host: host, address: entry.address)
		} catch {
			lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
		}
	}

	func disconnect() {
		stream?.stop()
	}

	func shutdown() {
		stream?.stop()
		input.stop()
		discovery.stop()
	}
}
