import PSContracts
import PSPairing
import SwiftUI

/// One console in the list: paired, seen on the network, or both.
struct ConsoleEntry: Identifiable, Equatable {
	var id: String
	var registered: RegisteredHost?
	var discovered: DiscoveredHost?

	var name: String { registered?.nickname.nonEmpty ?? discovered?.name.nonEmpty ?? "PlayStation" }
	var isPS5: Bool { registered?.isPS5 ?? discovered?.isPS5 ?? true }
	var address: String? { discovered?.address ?? registered?.lastKnownAddress }
	var state: HostState? { discovered?.state }

	var statusText: String {
		switch state {
		case .ready?:
			if let app = discovered?.runningAppName?.nonEmpty { return "On · \(app)" }
			return "On"
		case .standby?: return "Rest mode"
		case .unknown?: return "Unknown state"
		case nil: return registered == nil ? "Not found" : "Not found on this network"
		}
	}

	var statusColor: Color {
		switch state {
		case .ready?: return .green
		case .standby?: return .orange
		default: return .secondary
		}
	}

	static func merge(registered: [RegisteredHost], discovered: [DiscoveredHost]) -> [ConsoleEntry] {
		var entries: [String: ConsoleEntry] = [:]
		for host in registered { entries[host.id] = ConsoleEntry(id: host.id, registered: host) }
		for host in discovered {
			var entry = entries[host.id] ?? ConsoleEntry(id: host.id)
			entry.discovered = host
			entries[host.id] = entry
		}
		return entries.values.sorted {
			if ($0.registered != nil) != ($1.registered != nil) { return $0.registered != nil }
			return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
	}
}

private extension String {
	var nonEmpty: String? { isEmpty ? nil : self }
}

struct HomeView: View {
	@ObservedObject var model: AppModel
	@ObservedObject var discovery: DiscoveryService
	@ObservedObject var store: HostStore

	@State private var pairingHostID: String?
	@State private var showPairing = false
	@State private var showAccount = false
	@State private var showSettings = false

	private var entries: [ConsoleEntry] {
		ConsoleEntry.merge(registered: store.hosts, discovered: discovery.hosts)
	}

	var body: some View {
		VStack(spacing: 0) {
			if entries.isEmpty {
				emptyState
			} else {
				ScrollView {
					LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)], spacing: 16) {
						ForEach(entries) { entry in
							ConsoleCard(
								entry: entry,
								isConnecting: model.connectingHostID == entry.id,
								progress: model.connectingHostID == entry.id ? model.connectProgress : nil,
								onConnect: { model.connect(to: entry) },
								onPair: { pair(entry.id) },
								onWake: { model.wake(entry) },
								onForget: { store.remove(id: entry.id) }
							)
						}
					}
					.padding(24)
				}
			}
			if let error = model.lastError {
				HStack(alignment: .firstTextBaseline) {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
					Text(error).textSelection(.enabled)
					Spacer()
					Button("Dismiss") { model.lastError = nil }
				}
				.padding(12)
				.background(.thinMaterial)
			}
		}
		.frame(minWidth: 720, minHeight: 440)
		.navigationTitle("PlayStream")
		.toolbar {
			ToolbarItemGroup {
				Button {
					showAccount = true
				} label: {
					Label(store.account == nil ? "Sign in to PSN" : "PSN account", systemImage: store.account == nil ? "person.crop.circle.badge.exclamationmark" : "person.crop.circle.badge.checkmark")
				}
				.help(store.account == nil ? "Sign in to PSN (needed once, for pairing)" : "PSN account is set up")
				Button {
					pair(nil)
				} label: {
					Label("Pair console", systemImage: "plus")
				}
				.help("Pair a console")
				Button {
					showSettings.toggle()
				} label: {
					Label("Settings", systemImage: "slider.horizontal.3")
				}
				.help("Stream settings")
				.popover(isPresented: $showSettings, arrowEdge: .bottom) {
					SettingsView(settings: model.settings, input: model.input)
				}
			}
		}
		.sheet(isPresented: $showPairing) {
			PairingSheet(discovery: discovery, store: store, hostID: pairingHostID, onPaired: { _ in showPairing = false }, onCancel: { showPairing = false })
		}
		.sheet(isPresented: $showAccount) {
			PSNAccountSheet(store: store, onComplete: { _ in showAccount = false }, onCancel: { showAccount = false })
		}
	}

	private func pair(_ hostID: String?) {
		pairingHostID = hostID
		showPairing = true
	}

	private var emptyState: some View {
		VStack(spacing: 12) {
			ProgressView()
			Text("Looking for consoles on your network…")
				.font(.title3)
			Text("Turn the PlayStation on and make sure it is on the same network as this Mac.")
				.foregroundStyle(.secondary)
			Button("Pair by address…") { pair(nil) }
				.padding(.top, 8)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.padding(40)
	}
}

private struct ConsoleCard: View {
	let entry: ConsoleEntry
	let isConnecting: Bool
	let progress: String?
	let onConnect: () -> Void
	let onPair: () -> Void
	let onWake: () -> Void
	let onForget: () -> Void

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			HStack(spacing: 12) {
				Image(systemName: "playstation.logo")
					.font(.system(size: 30))
					.frame(width: 44)
				VStack(alignment: .leading, spacing: 3) {
					Text(entry.name).font(.title3.weight(.semibold))
					HStack(spacing: 6) {
						Circle().fill(entry.statusColor).frame(width: 8, height: 8)
						Text(entry.statusText).foregroundStyle(.secondary)
					}
					.font(.callout)
				}
				Spacer()
				Text(entry.isPS5 ? "PS5" : "PS4")
					.font(.caption.weight(.medium))
					.padding(.horizontal, 7)
					.padding(.vertical, 3)
					.background(.quaternary, in: Capsule())
			}
			HStack {
				if let address = entry.address {
					Text(address).font(.caption.monospaced()).foregroundStyle(.tertiary)
				}
				Spacer()
				if isConnecting {
					ProgressView().controlSize(.small)
					Text(progress ?? "Connecting…").font(.callout).foregroundStyle(.secondary)
				} else if entry.registered != nil {
					Button(entry.state == .standby ? "Wake and connect" : "Connect", action: onConnect)
						.buttonStyle(.borderedProminent)
						.keyboardShortcut(.defaultAction)
						.disabled(entry.address == nil)
				} else {
					Button("Pair…", action: onPair)
						.buttonStyle(.borderedProminent)
				}
			}
		}
		.padding(16)
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
		.contextMenu {
			if entry.registered != nil {
				Button("Connect", action: onConnect).disabled(entry.address == nil)
				Button("Wake from rest mode", action: onWake).disabled(entry.address == nil)
				Button("Pair again…", action: onPair)
				Divider()
				Button("Forget this console", role: .destructive, action: onForget)
			} else {
				Button("Pair…", action: onPair)
			}
		}
	}
}
