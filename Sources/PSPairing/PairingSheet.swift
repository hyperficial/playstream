import PSContracts
import SwiftUI

/// Walks the user through pairing a console: pick the console, make sure a PSN account is set
/// up, enter the Link Device PIN, pair. On success the host is saved to `store` and passed to
/// `onPaired`; the sheet dismisses itself.
///
/// ```swift
/// .sheet(isPresented: $showPairing) {
///     PairingSheet(discovery: discovery, store: store) { host in selectedHostID = host.id }
/// }
/// ```
public struct PairingSheet: View {
	@ObservedObject private var discovery: DiscoveryService
	@ObservedObject private var store: HostStore
	private let onPaired: (RegisteredHost) -> Void
	private let onCancel: () -> Void

	@Environment(\.dismiss) private var dismiss
	@StateObject private var model: PairingModel
	@State private var showAccountSheet = false
	@FocusState private var focus: Field?

	private enum Field: Hashable { case pin, manualAddress }

	/// - Parameters:
	///   - hostID: preselect this console (e.g. when the user clicked "Pair" on it).
	public init(discovery: DiscoveryService, store: HostStore, hostID: String? = nil, onPaired: @escaping (RegisteredHost) -> Void = { _ in }, onCancel: @escaping () -> Void = {}) {
		self.discovery = discovery
		self.store = store
		self.onPaired = onPaired
		self.onCancel = onCancel
		_model = StateObject(wrappedValue: PairingModel(preselectedHostID: hostID.flatMap { PairingInput.normalizeHostID($0) ?? $0 }))
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			VStack(alignment: .leading, spacing: 4) {
				Text("Pair a PlayStation").font(.title2.bold())
				Text("Pairing is needed once per console.").foregroundStyle(.secondary)
			}
			.padding([.horizontal, .top], 20)
			.padding(.bottom, 12)

			Form {
				consoleSection
				accountSection
				pinSection
				statusSection
			}
			.formStyle(.grouped)
			.disabled(model.isPairing)

			Divider()
			buttons.padding(16)
		}
		.frame(width: 520)
		.frame(minHeight: 560)
		.onAppear {
			discovery.start()
			model.autoselect(from: discovery.hosts)
			focus = .pin
		}
		.onChange(of: discovery.hosts) { _, hosts in model.autoselect(from: hosts) }
		.onChange(of: model.pairedHost) { _, host in
			guard let host else { return }
			store.upsert(host)
			if let account = model.accountUsed { store.setAccount(account) }
			onPaired(host)
			dismiss()
		}
		.sheet(isPresented: $showAccountSheet) {
			PSNAccountSheet(store: store)
		}
	}

	// MARK: Sections

	@ViewBuilder
	private var consoleSection: some View {
		Section {
			if discovery.hosts.isEmpty {
				HStack(spacing: 8) {
					if discovery.isRunning { ProgressView().controlSize(.small) }
					Text(discovery.lastError ?? "Looking for consoles on your network…")
						.foregroundStyle(.secondary)
				}
			}
			Picker("Console", selection: $model.selection) {
				ForEach(discovery.hosts) { host in
					ConsoleRow(host: host, isPaired: store.isRegistered(host))
						.tag(Optional(PairingModel.Selection.discovered(host.id)))
						.disabled(host.state == .standby)
				}
				Text("Enter an IP address").tag(Optional(PairingModel.Selection.manual))
			}
			.pickerStyle(.radioGroup)
			.labelsHidden()
			.onChange(of: model.selection) { _, selection in
				focus = selection == .manual ? .manualAddress : .pin
			}
			if model.selection == .manual {
				TextField("IP address", text: $model.manualAddress, prompt: Text("192.168.1.20"))
					.focused($focus, equals: .manualAddress)
					.onSubmit { focus = .pin }
			}
		} header: {
			Text("Console")
		} footer: {
			if discovery.hosts.contains(where: { $0.state == .standby }) {
				Text("Consoles in rest mode must be turned on to pair.").foregroundStyle(.secondary)
			}
		}
	}

	@ViewBuilder
	private var accountSection: some View {
		Section("PlayStation Network account") {
			HStack {
				if let account = store.account {
					Label(account.onlineID ?? "Account set up", systemImage: "person.crop.circle.badge.checkmark")
					Spacer()
					Button("Change…") { showAccountSheet = true }
				} else {
					Label("No account set up yet", systemImage: "person.crop.circle.badge.exclamationmark")
						.foregroundStyle(.orange)
					Spacer()
					Button("Set Up Account…") { showAccountSheet = true }
				}
			}
		}
	}

	@ViewBuilder
	private var pinSection: some View {
		Section {
			VStack(alignment: .leading, spacing: 6) {
				Text("On the PS5, go to **Settings › System › Remote Play › Link Device**. It shows an 8 digit PIN that is valid for a few minutes.")
					.fixedSize(horizontal: false, vertical: true)
				Text("Remote Play must be turned on (Settings › System › Remote Play › Enable Remote Play).")
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			TextField("PIN", text: $model.pin, prompt: Text("1234 5678"))
				.font(.title3.monospacedDigit())
				.focused($focus, equals: .pin)
				.onChange(of: model.pin) { _, value in model.sanitizePIN(value) }
				.onSubmit { pair() }
		} header: {
			Text("Link Device PIN")
		}
	}

	@ViewBuilder
	private var statusSection: some View {
		if model.isPairing {
			Section {
				HStack(spacing: 10) {
					ProgressView().controlSize(.small)
					Text("Pairing with \(model.pairingTargetName)…")
				}
			}
		} else if let failure = model.failure {
			Section {
				Label {
					VStack(alignment: .leading, spacing: 4) {
						Text(failure.message).fontWeight(.semibold)
						if let hint = failure.hint {
							Text(hint).foregroundStyle(.secondary)
						}
					}
					.fixedSize(horizontal: false, vertical: true)
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
				}
			}
		}
	}

	private var buttons: some View {
		HStack {
			if model.isPairing {
				Text("Keep the Link Device screen open on the PS5.")
					.font(.callout)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Button("Cancel") {
				if model.isPairing {
					model.cancelPairing()
				} else {
					onCancel()
					dismiss()
				}
			}
			.keyboardShortcut(.cancelAction)
			Button(model.failure == nil ? "Pair" : "Try Again") { pair() }
				.keyboardShortcut(.defaultAction)
				.disabled(!canPair)
		}
	}

	private var canPair: Bool {
		!model.isPairing && store.account != nil && model.pinDigits.count == 8 && model.resolveHost(in: discovery.hosts) != nil
	}

	private func pair() {
		guard canPair, let account = store.account, let host = model.resolveHost(in: discovery.hosts) else {
			if store.account == nil { showAccountSheet = true }
			return
		}
		model.pair(host: host, account: account)
	}
}

// MARK: - Rows

private struct ConsoleRow: View {
	let host: DiscoveredHost
	let isPaired: Bool

	var body: some View {
		HStack(spacing: 8) {
			Image(systemName: "playstation.logo")
			VStack(alignment: .leading, spacing: 1) {
				HStack(spacing: 6) {
					Text(host.name).fontWeight(.medium)
					if isPaired {
						Text("Paired").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
							.background(.quaternary, in: Capsule())
					}
				}
				Text("\(host.address) · \(stateText)").font(.caption).foregroundStyle(.secondary)
			}
		}
		.padding(.vertical, 2)
	}

	private var stateText: String {
		switch host.state {
		case .ready: return "On"
		case .standby: return "Rest mode, turn it on to pair"
		case .unknown: return "Unknown state"
		}
	}
}

// MARK: - Model

@MainActor
final class PairingModel: ObservableObject {
	enum Selection: Hashable {
		case discovered(String)
		case manual
	}

	struct Failure: Equatable {
		var message: String
		var hint: String?
	}

	@Published var selection: Selection?
	@Published var manualAddress = ""
	@Published var pin = ""
	@Published private(set) var isPairing = false
	@Published private(set) var failure: Failure?
	@Published private(set) var pairedHost: RegisteredHost?
	@Published private(set) var pairingTargetName = ""
	private(set) var accountUsed: PSNAccount?

	private let preselectedHostID: String?
	private var task: Task<Void, Never>?
	private let registrar = Registrar()

	init(preselectedHostID: String?) {
		self.preselectedHostID = preselectedHostID
		if let preselectedHostID { selection = .discovered(preselectedHostID) }
	}

	var pinDigits: String { pin.filter(\.isASCIIDigit) }

	/// Keeps digits only (pasting "1234 5678" works), groups as "1234 5678", max 8 digits.
	func sanitizePIN(_ value: String) {
		let digits = String(value.filter(\.isASCIIDigit).prefix(8))
		let formatted = digits.count > 4 ? digits.prefix(4) + " " + digits.dropFirst(4) : Substring(digits)
		if String(formatted) != value { pin = String(formatted) }
	}

	/// Selects the only ready console if the user has not chosen anything yet.
	func autoselect(from hosts: [DiscoveredHost]) {
		guard selection == nil else { return }
		let ready = hosts.filter { $0.state != .standby }
		if ready.count == 1 { selection = .discovered(ready[0].id) }
	}

	func resolveHost(in hosts: [DiscoveredHost]) -> DiscoveredHost? {
		switch selection {
		case let .discovered(id):
			return hosts.first { $0.id == id && $0.state != .standby }
		case .manual:
			guard let address = PairingInput.normalizeAddress(manualAddress) else { return nil }
			if let found = hosts.first(where: { $0.address == address }) { return found }
			// Not discovered (e.g. another subnet): assume a current PS5.
			return DiscoveredHost(id: "", name: address, address: address, isPS5: true, state: .unknown, systemVersion: "", target: ConsoleTarget.ps5v1, requestPort: 9295)
		case nil:
			return nil
		}
	}

	func pair(host: DiscoveredHost, account: PSNAccount) {
		guard !isPairing else { return }
		failure = nil
		isPairing = true
		pairingTargetName = host.name
		accountUsed = account
		let pin = self.pin
		task = Task { [weak self, registrar] in
			do {
				let registered = try await registrar.register(host: host, account: account, pin: pin, consolePin: nil)
				self?.isPairing = false
				self?.pairedHost = registered
			} catch is CancellationError {
				self?.isPairing = false
			} catch {
				guard let self else { return }
				self.isPairing = false
				self.failure = Failure(
					message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
					hint: (error as? LocalizedError)?.recoverySuggestion
				)
				// A rejected PIN is spent; make the user type the new one.
				if let e = error as? RegistrationError, e == .wrongPIN || e == .linkScreenNotOpen { self.pin = "" }
			}
		}
	}

	func cancelPairing() {
		task?.cancel()
	}
}
