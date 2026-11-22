import CPSBridge
import Combine
import Foundation
import PSContracts

/// LAN discovery of PS4/PS5 consoles. Publishes the current host list on the main thread.
///
/// ```swift
/// @StateObject var discovery = DiscoveryService()
/// .onAppear { discovery.start() }
/// ```
@MainActor
public final class DiscoveryService: ObservableObject {
	/// Consoles currently answering on the LAN, sorted by name. Ids are 12 uppercase hex digits.
	@Published public private(set) var hosts: [DiscoveredHost] = []
	@Published public private(set) var isRunning = false
	/// Set when starting discovery failed (e.g. no network / local network access denied).
	@Published public private(set) var lastError: String?

	private var handle: OpaquePointer?
	private var context: DiscoveryContext?

	public init() {}

	/// Starts discovery. Calling it while running does nothing.
	public func start() {
		guard handle == nil else { return }
		BridgeLog.shared.install()
		let context = DiscoveryContext(service: self)
		let user = Unmanaged.passRetained(context).toOpaque()
		var err: Int32 = 0
		guard let discovery = ps_discovery_start(discoveryCallback, user, &err) else {
			Unmanaged<DiscoveryContext>.fromOpaque(user).release()
			lastError = "Could not start looking for consoles: \(bridgeErrorString(err))."
			isRunning = false
			return
		}
		self.handle = discovery
		self.context = context
		lastError = nil
		isRunning = true
	}

	/// Stops discovery and clears the host list. Calling it while stopped does nothing.
	public func stop() {
		guard let handle, let context else { return }
		context.isActive = false // drop updates already queued for the main thread
		self.handle = nil
		self.context = nil
		ps_discovery_stop(handle) // no callback after this returns
		Unmanaged.passUnretained(context).release() // balances passRetained in start()
		hosts = []
		isRunning = false
	}

	deinit {
		if let handle, let context {
			context.isActive = false
			ps_discovery_stop(handle)
			Unmanaged.passUnretained(context).release()
		}
	}

	public func host(id: String) -> DiscoveredHost? {
		let id = PairingInput.normalizeHostID(id) ?? id
		return hosts.first { $0.id == id }
	}

	public func host(address: String) -> DiscoveredHost? {
		hosts.first { $0.address == address }
	}

	/// Waits until a host matching `predicate` is discovered (starting discovery if needed).
	/// Returns nil on timeout or task cancellation.
	public func waitForHost(timeout: TimeInterval, where predicate: @escaping (DiscoveredHost) -> Bool) async -> DiscoveredHost? {
		start()
		if let match = hosts.first(where: predicate) { return match }
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline, !Task.isCancelled {
			try? await Task.sleep(nanoseconds: 200_000_000)
			if let match = hosts.first(where: predicate) { return match }
		}
		return nil
	}

	/// Waits until the console with `id` is reported in `state` (default: ready).
	public func waitForHost(id: String, state: HostState = .ready, timeout: TimeInterval) async -> DiscoveredHost? {
		let id = PairingInput.normalizeHostID(id) ?? id
		return await waitForHost(timeout: timeout) { $0.id == id && $0.state == state }
	}

	fileprivate func apply(_ newHosts: [DiscoveredHost], from context: DiscoveryContext) {
		guard context.isActive, context === self.context else { return }
		if newHosts != hosts { hosts = newHosts }
	}
}

/// Callback context. Retained for the lifetime of the C discovery handle.
private final class DiscoveryContext: @unchecked Sendable {
	weak var service: DiscoveryService?
	/// Only touched on the main thread.
	var isActive = true
	init(service: DiscoveryService) { self.service = service }
}

private let discoveryCallback: PSDiscoveryCallback = { hostsPtr, count, user in
	guard let user else { return }
	let context = Unmanaged<DiscoveryContext>.fromOpaque(user).takeUnretainedValue()
	// Copy everything now: the strings are only valid during this callback.
	var result: [DiscoveredHost] = []
	var seen = Set<String>()
	if let hostsPtr {
		for raw in UnsafeBufferPointer(start: hostsPtr, count: count) {
			guard let host = DiscoveredHost(bridge: raw), seen.insert(host.id).inserted else { continue }
			result.append(host)
		}
	}
	result.sort { ($0.name.localizedLowercase, $0.id) < ($1.name.localizedLowercase, $1.id) }
	DispatchQueue.main.async {
		MainActor.assumeIsolated {
			context.service?.apply(result, from: context)
		}
	}
}

extension DiscoveredHost {
	/// Converts a bridge host; returns nil if it has no usable id or address.
	init?(bridge raw: PSDiscoveredHost) {
		func str(_ p: UnsafePointer<CChar>?) -> String? {
			guard let p else { return nil }
			let s = String(cString: p)
			return s.isEmpty ? nil : s
		}
		guard let id = PairingInput.normalizeHostID(str(raw.host_id)), let address = str(raw.host_addr) else {
			return nil
		}
		let state: HostState
		switch raw.state {
		case Int32(PS_HOST_STATE_READY): state = .ready
		case Int32(PS_HOST_STATE_STANDBY): state = .standby
		default: state = .unknown
		}
		self.init(
			id: id,
			name: str(raw.host_name) ?? (raw.ps5 ? "PS5" : "PS4"),
			address: address,
			isPS5: raw.ps5,
			state: state,
			systemVersion: str(raw.system_version) ?? "",
			target: raw.target,
			requestPort: raw.request_port,
			runningAppName: str(raw.running_app_name),
			runningAppTitleID: str(raw.running_app_titleid)
		)
	}
}
