import Combine
import Darwin
import Foundation
import PSContracts

/// Persists registered consoles and the PSN account, and nothing else.
///
/// Stored as JSON at `~/Library/Application Support/PlayStream/pairing.json` with 0600
/// permissions (directory 0700), written atomically. These are secrets: the regist key and
/// rp key let anyone on the LAN start a Remote Play session as this Mac.
@MainActor
public final class HostStore: ObservableObject {
	@Published public private(set) var hosts: [RegisteredHost] = []
	@Published public private(set) var account: PSNAccount?
	/// Last load/save problem, for showing in the UI. Loading never throws.
	@Published public private(set) var lastError: String?

	public let fileURL: URL
	private var discoverySubscription: AnyCancellable?

	public static var defaultDirectory: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return base.appendingPathComponent("PlayStream", isDirectory: true)
	}

	/// - Parameter directory: where to keep `pairing.json`; defaults to Application Support/PlayStream.
	public init(directory: URL? = nil) {
		fileURL = (directory ?? Self.defaultDirectory).appendingPathComponent("pairing.json")
		load()
	}

	// MARK: Queries

	public func host(id: String) -> RegisteredHost? {
		let id = PairingInput.normalizeHostID(id) ?? id
		return hosts.first { $0.id == id }
	}

	public func isRegistered(_ discovered: DiscoveredHost) -> Bool {
		host(id: discovered.id) != nil
	}

	// MARK: Mutations

	/// Adds a host, or replaces the one with the same id (re-pairing yields new keys).
	public func upsert(_ host: RegisteredHost) {
		var host = host
		host.id = PairingInput.normalizeHostID(host.id) ?? host.id
		if let index = hosts.firstIndex(where: { $0.id == host.id }) {
			if host.lastKnownAddress == nil { host.lastKnownAddress = hosts[index].lastKnownAddress }
			hosts[index] = host
		} else {
			hosts.append(host)
		}
		save()
	}

	public func rename(id: String, to nickname: String) {
		guard let index = hosts.firstIndex(where: { $0.id == id }) else { return }
		hosts[index].nickname = nickname
		save()
	}

	public func remove(id: String) {
		let id = PairingInput.normalizeHostID(id) ?? id
		let before = hosts.count
		hosts.removeAll { $0.id == id }
		if hosts.count != before { save() }
	}

	public func setAccount(_ account: PSNAccount?) {
		if let account, account.accountID.count != 8 { return }
		guard account != self.account else { return }
		self.account = account
		save()
	}

	/// Updates `lastKnownAddress` of registered consoles seen by discovery. Saves only on change.
	public func noteDiscovered(_ discovered: [DiscoveredHost]) {
		var changed = false
		for d in discovered {
			guard let index = hosts.firstIndex(where: { $0.id == d.id }), hosts[index].lastKnownAddress != d.address else { continue }
			hosts[index].lastKnownAddress = d.address
			changed = true
		}
		if changed { save() }
	}

	/// Keeps `lastKnownAddress` up to date from a discovery service for as long as this store lives.
	public func track(_ discovery: DiscoveryService) {
		discoverySubscription = discovery.$hosts
			.receive(on: DispatchQueue.main)
			.sink { [weak self] hosts in
				MainActor.assumeIsolated { self?.noteDiscovered(hosts) }
			}
	}

	/// Re-reads the file from disk.
	public func reload() { load() }

	// MARK: Persistence

	struct FileContents: Codable {
		var version: Int = 1
		var account: PSNAccount?
		var hosts: [RegisteredHost] = []
	}

	/// Decodes one host, skipping (not failing on) bad entries.
	private struct LenientHost: Decodable {
		let value: RegisteredHost?
		init(from decoder: Decoder) throws {
			value = try? RegisteredHost(from: decoder)
		}
	}

	private struct LenientFile: Decodable {
		let version: Int?
		let account: PSNAccount?
		let hosts: [LenientHost]?
		enum CodingKeys: String, CodingKey { case version, account, hosts }
		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			version = try? c.decodeIfPresent(Int.self, forKey: .version)
			account = try? c.decodeIfPresent(PSNAccount.self, forKey: .account)
			hosts = try? c.decodeIfPresent([LenientHost].self, forKey: .hosts)
		}
	}

	private func load() {
		let path = fileURL.path
		guard FileManager.default.fileExists(atPath: path) else {
			hosts = []
			account = nil
			return
		}
		tightenPermissions()
		let data: Data
		do {
			data = try Data(contentsOf: fileURL)
		} catch {
			lastError = "Could not read saved consoles: \(error.localizedDescription)"
			return
		}
		guard let file = try? JSONDecoder().decode(LenientFile.self, from: data) else {
			backUpUnreadableFile(suffix: "corrupt")
			hosts = []
			account = nil
			lastError = "The saved consoles file was damaged and has been set aside. Pair again."
			return
		}
		var loaded: [RegisteredHost] = []
		var dropped = 0
		for entry in file.hosts ?? [] {
			guard var host = entry.value, let id = PairingInput.normalizeHostID(host.id),
			      host.registKey.count == 16, host.rpKey.count == 16 else {
				dropped += 1
				continue
			}
			host.id = id
			if !loaded.contains(where: { $0.id == id }) { loaded.append(host) }
		}
		let validAccount = file.account.flatMap { $0.accountID.count == 8 ? $0 : nil }
		if dropped > 0 || (file.account != nil && validAccount == nil) {
			// Keep the original before the next save overwrites it.
			backUpUnreadableFile(suffix: "bak")
			lastError = "Some saved pairing data could not be read and was skipped."
		}
		hosts = loaded
		account = validAccount
	}

	private func save() {
		let contents = FileContents(account: account, hosts: hosts)
		do {
			let encoder = JSONEncoder()
			encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
			try writeSecretFile(encoder.encode(contents))
			lastError = nil
		} catch {
			lastError = "Could not save pairing data: \(error.localizedDescription)"
		}
	}

	/// Atomic write with 0600 from the first byte: temp file created with O_EXCL and mode
	/// 0600 in the same directory, fsync, rename over the target.
	private func writeSecretFile(_ data: Data) throws {
		let dir = fileURL.deletingLastPathComponent()
		try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		chmod(dir.path, 0o700)

		let tmpPath = dir.appendingPathComponent(".pairing.json.\(UUID().uuidString).tmp").path
		let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
		guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		var ok = false
		defer {
			if !ok { unlink(tmpPath) }
		}
		fchmod(fd, 0o600) // in case of an unusual umask
		let written = data.withUnsafeBytes { raw -> Bool in
			var offset = 0
			while offset < raw.count {
				let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
				if n < 0 {
					if errno == EINTR { continue }
					return false
				}
				offset += n
			}
			return true
		}
		let syncOK = fsync(fd) == 0
		close(fd)
		guard written, syncOK else { throw POSIXError(.EIO) }
		guard Darwin.rename(tmpPath, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		ok = true
	}

	private func tightenPermissions() {
		chmod(fileURL.deletingLastPathComponent().path, 0o700)
		chmod(fileURL.path, 0o600)
	}

	private func backUpUnreadableFile(suffix: String) {
		let stamp = Int(Date().timeIntervalSince1970)
		let backup = fileURL.deletingPathExtension().appendingPathExtension("\(suffix)-\(stamp).json")
		try? FileManager.default.copyItem(at: fileURL, to: backup)
		chmod(backup.path, 0o600)
	}
}
