import Darwin
import Foundation
import PSContracts
import PSPairing

/// Offline checks: no console, no Sony login, no network.
@MainActor
func runSelfTest(storeDir: URL?, network: Bool) async -> Bool {
	var failures = 0
	var passes = 0
	func check(_ condition: @autoclosure () -> Bool, _ name: String) {
		if condition() {
			passes += 1
		} else {
			failures += 1
			print("FAIL: \(name)")
		}
	}
	func throwsError(_ body: () throws -> Void) -> Bool {
		do { try body(); return false } catch { return true }
	}

	// MARK: Account id encoding — vectors from scripts/psn-account-id.py:
	// base64.b64encode(user_id.to_bytes(8, "little"))
	let vectors: [(UInt64, String)] = [
		(0, "AAAAAAAAAAA="),
		(1, "AQAAAAAAAAA="),
		(1_234_567_890_123_456_789, "FYHpffQQIhE="),
		(6_665_123_456_789_012_345, "eV8IenhGf1w="),
		(9_223_372_036_854_775_807, "/////////38="),
		(18_446_744_073_709_551_615, "//////////8="),
	]
	for (uid, b64) in vectors {
		check(PSNAuth.accountID(fromUserID: uid).base64EncodedString() == b64, "accountID(\(uid)) == \(b64)")
		check((try? PSNAuth.accountID(fromUserIDString: String(uid)))?.base64EncodedString() == b64, "accountID(string \(uid))")
		check((try? PSNAuth.parseAccountID(b64)) == Data(base64Encoded: b64), "parseAccountID(\(b64))")
		check(PSNAuth.userID(fromAccountID: Data(base64Encoded: b64)!) == uid, "userID roundtrip \(uid)")
		check(PSNAccount(accountID: PSNAuth.accountID(fromUserID: uid)).accountIDBase64 == b64, "PSNAccount.accountIDBase64 \(uid)")
	}
	check((try? PSNAuth.parseAccountID("  FYHpffQQIhE  ")) == Data(base64Encoded: "FYHpffQQIhE="), "parseAccountID unpadded + whitespace")
	check((try? PSNAuth.parseAccountID("1234567890123456789")) == Data(base64Encoded: "FYHpffQQIhE="), "parseAccountID decimal")
	check(throwsError { _ = try PSNAuth.parseAccountID("") }, "parseAccountID empty")
	check(throwsError { _ = try PSNAuth.parseAccountID("AAAA") }, "parseAccountID 3 bytes")
	check(throwsError { _ = try PSNAuth.parseAccountID("AAAAAAAAAAAAAAAA") }, "parseAccountID 12 bytes")
	check(throwsError { _ = try PSNAuth.parseAccountID("not base64!!") }, "parseAccountID garbage")
	check(throwsError { _ = try PSNAuth.parseAccountID("99999999999999999999999") }, "parseAccountID decimal overflow")

	// MARK: Login URL — must equal chiaki-ng's PSNAuth::LOGIN_URL + "duid=<duid>&"
	let duid = PSNAuth.makeDeviceUID()
	check(duid.count == 48 && duid.hasPrefix("0000000700410080") && duid.allSatisfy { "0123456789abcdef".contains($0) }, "duid format")
	check(PSNAuth.makeDeviceUID() != duid, "duid is random")
	let chiakiLoginURL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?service_entity=urn:service-entity:psn&response_type=code&client_id=%1&redirect_uri=https://remoteplay.dl.playstation.net/remoteplay/redirect&scope=psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal&"
		.replacingOccurrences(of: "%1", with: "ba495a24-818c-472b-b12d-ff231c1b5745") + "duid=\(duid)&"
	let url = PSNAuth.authorizeURL(deviceUID: duid)
	check(url.absoluteString.removingPercentEncoding == chiakiLoginURL, "authorize URL equals chiaki LOGIN_URL + duid")
	check(url.absoluteString == chiakiLoginURL.replacingOccurrences(of: " ", with: "%20"), "authorize URL encodes only spaces")
	let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
	func q(_ name: String) -> String? { items.first { $0.name == name }?.value }
	check(url.host == "auth.api.sonyentertainmentnetwork.com" && url.path == "/2.0/oauth/authorize", "authorize host/path")
	check(q("client_id") == "ba495a24-818c-472b-b12d-ff231c1b5745", "client_id")
	check(q("redirect_uri") == "https://remoteplay.dl.playstation.net/remoteplay/redirect", "redirect_uri")
	check(q("scope") == "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update", "scope")
	check(q("response_type") == "code" && q("prompt") == "always" && q("duid") == duid, "response_type/prompt/duid")

	// Token body — chiaki-ng PSNAccountID::GetPsnAccountId
	let chiakiBody = "grant_type=authorization_code&code=%1&scope=psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update&redirect_uri=https://remoteplay.dl.playstation.net/remoteplay/redirect&"
	check(PSNAuth.tokenRequestBody(code: "v3AbC123") == chiakiBody.replacingOccurrences(of: "%1", with: "v3AbC123"), "token body equals chiaki")
	check(!PSNAuth.tokenRequestBody(code: "a&b=c").contains("a&b=c"), "token body escapes code")

	// MARK: Redirect parsing
	let redirect = URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=v3Xyz789&cid=abc-123")!
	check(PSNAuth.isRedirect(redirect), "isRedirect")
	check((try? PSNAuth.authorizationCode(fromRedirect: redirect)) == "v3Xyz789", "code from redirect")
	check((try? PSNAuth.authorizationCode(fromPastedText: "  https://remoteplay.dl.playstation.net/remoteplay/redirect?cid=1&code=Q1w2E3\n")) == "Q1w2E3", "code from pasted text")
	check(!PSNAuth.isRedirect(URL(string: "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize?redirect_uri=https://remoteplay.dl.playstation.net/remoteplay/redirect")!), "authorize page is not the redirect")
	check(!PSNAuth.isRedirect(URL(string: "https://evil.example/remoteplay/redirect?code=x")!), "other host is not the redirect")
	do {
		_ = try PSNAuth.authorizationCode(fromRedirect: URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?error=access_denied&error_description=User%20denied")!)
		check(false, "error redirect throws")
	} catch let e as PSNAuthError {
		check(e == .loginRejected(error: "access_denied", description: "User denied"), "error redirect -> loginRejected")
	} catch { check(false, "error redirect type") }
	check((try? PSNAuth.authorizationCode(fromRedirect: URL(string: "https://remoteplay.dl.playstation.net/remoteplay/redirect?code=")!)) == nil, "empty code rejected")
	check((try? PSNAuth.authorizationCode(fromPastedText: "hello")) == nil, "garbage paste rejected")

	// MARK: PIN handling
	check((try? PairingInput.parsePIN("12345678")) == 12_345_678, "pin plain")
	check((try? PairingInput.parsePIN("1234 5678")) == 12_345_678, "pin with space")
	check((try? PairingInput.parsePIN("  0012 3456 ")) == 123_456, "pin leading zeros + padding")
	check((try? PairingInput.parsePIN("1234-5678")) == 12_345_678, "pin with dash")
	check((try? PairingInput.parsePIN("99999999")) == 99_999_999, "pin max")
	for bad in ["", "1234567", "123456789", "1234a678", "１２３４５６７８", "12.345678"] {
		check(throwsError { _ = try PairingInput.parsePIN(bad) }, "pin rejects \"\(bad)\"")
	}
	check((try? PairingInput.parseConsolePIN(nil)) == 0, "console pin nil")
	check((try? PairingInput.parseConsolePIN(" ")) == 0, "console pin blank")
	check((try? PairingInput.parseConsolePIN("0420")) == 420, "console pin 4 digits")
	check(throwsError { _ = try PairingInput.parseConsolePIN("123") }, "console pin rejects 3 digits")
	check(throwsError { _ = try PairingInput.parseConsolePIN("12345") }, "console pin rejects 5 digits")

	// MARK: Host ids / targets
	check(PairingInput.normalizeHostID("00a1b2c3d4e5") == "00A1B2C3D4E5", "host id lowercase")
	check(PairingInput.normalizeHostID("00:A1:B2:C3:D4:E5") == "00A1B2C3D4E5", "host id colons")
	check(PairingInput.normalizeHostID("00-a1-b2-c3-d4-e5") == "00A1B2C3D4E5", "host id dashes")
	check(PairingInput.normalizeHostID("00E42127359") == nil, "host id too short")
	check(PairingInput.normalizeHostID("00E42127359G") == nil, "host id non-hex")
	check(PairingInput.normalizeHostID(nil) == nil, "host id nil")
	check(PairingInput.hostID(fromMAC: Data([0x00, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5])) == "00A1B2C3D4E5", "host id from mac")
	check(ConsoleTarget.forRegistration(1_000_100, isPS5: true) == 1_000_100, "target PS5_1 kept")
	check(ConsoleTarget.forRegistration(1_000_000, isPS5: true) == 1_000_100, "target PS5_UNKNOWN -> PS5_1")
	check(ConsoleTarget.forRegistration(0, isPS5: true) == 1_000_100, "target unset PS5 -> PS5_1")
	check(ConsoleTarget.forRegistration(1000, isPS5: false) == 1000, "target PS4_10 kept")

	// MARK: Error diagnosis from the core log (messages verbatim from lib/src/regist.c)
	let a = "192.168.1.20"
	check(RegistrationError.diagnose(logLines: ["Regist failed to receive search response: Connection refused", "The console refused the registration search, keep its Link Device (PS5) or Add Device (PS4) screen with the code open while registering"], address: a) == .linkScreenNotOpen, "diagnose refused")
	check(RegistrationError.diagnose(logLines: ["Regist timed out waiting for search response", "Regist search failed"], address: a) == .consoleNotResponding(address: a), "diagnose timeout")
	check(RegistrationError.diagnose(logLines: ["Regist received HTTP code 403", "Reported Application Reason: 0x80108b09 (Regist failed, probably invalid PIN)", "Regist eventually failed"], address: a) == .wrongPIN, "diagnose wrong pin")
	check(RegistrationError.diagnose(logLines: ["Regist received HTTP code 403", "Reported Application Reason: 0x80108b02 (Invalid PSN ID)"], address: a) == .accountRejected, "diagnose bad account")
	check(RegistrationError.diagnose(logLines: ["Regist failed to send search: No route to host"], address: a) == .localNetworkDenied, "diagnose no route")
	check(RegistrationError.diagnose(logLines: ["Regist failed to getaddrinfo on ps5.local"], address: "ps5.local") == .invalidAddress("ps5.local"), "diagnose getaddrinfo")
	check(RegistrationError.diagnose(logLines: ["Regist received HTTP code 500"], address: a) == .consoleRejected(detail: "received HTTP code 500"), "diagnose http")
	check(RegistrationError.diagnose(logLines: [], address: a) == .failed(detail: nil), "diagnose nothing")
	check(RegistrationError.wrongPIN.recoverySuggestion?.contains("Link Device") == true, "wrong pin has hint")

	// MARK: Registrar input validation (rejected before anything reaches the bridge)
	let host = DiscoveredHost(id: "00A1B2C3D4E5", name: "PS5-123", address: "192.168.1.20", isPS5: true, state: .ready, systemVersion: "", target: 1_000_100, requestPort: 9295)
	let account = PSNAccount(accountID: PSNAuth.accountID(fromUserID: 1))
	func registerError(_ host: DiscoveredHost, _ account: PSNAccount, _ pin: String, _ cpin: String? = nil) async -> RegistrationError? {
		do { _ = try await Registrar().register(host: host, account: account, pin: pin, consolePin: cpin); return nil } catch { return error as? RegistrationError }
	}
	if case .invalidPIN = await registerError(host, account, "1234") {} else { check(false, "register rejects short pin") }
	let e1 = await registerError(host, account, "12345678", "12")
	check(e1 == .invalidConsolePIN, "register rejects bad console pin")
	let e2 = await registerError(host, PSNAccount(accountID: Data([1, 2, 3])), "12345678")
	check(e2 == .invalidAccountID, "register rejects 3 byte account")
	var sleeping = host
	sleeping.state = .standby
	let e3 = await registerError(sleeping, account, "12345678")
	check(e3 == .consoleAsleep, "register rejects standby console")
	var noAddress = host
	noAddress.address = " "
	let e4 = await registerError(noAddress, account, "12345678")
	check(e4 == .invalidAddress(" "), "register rejects empty address")
	let cancelled = Task { () -> Error? in
		withUnsafeCurrentTask { $0?.cancel() }
		do { _ = try await Registrar().register(host: host, account: account, pin: "12345678", consolePin: nil); return nil } catch { return error }
	}
	let e5 = await cancelled.value
	check(e5 is CancellationError, "register honours prior cancellation")

	// MARK: HostStore
	let dir = (storeDir ?? FileManager.default.temporaryDirectory).appendingPathComponent("pairing-selftest-\(UUID().uuidString)", isDirectory: true)
	defer { try? FileManager.default.removeItem(at: dir) }
	func mode(_ path: String) -> mode_t {
		var st = stat()
		return stat(path, &st) == 0 ? st.st_mode & 0o777 : 0
	}
	let key = Data((0 ..< 16).map { UInt8($0) })
	let registered = RegisteredHost(id: "00a1b2c3d4e5", nickname: "PS5-123", isPS5: true, target: 1_000_100, registKey: key, rpKey: key, rpKeyType: 0, serverMAC: Data([0x00, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5]))
	do {
		let store = HostStore(directory: dir)
		check(store.hosts.isEmpty && store.account == nil && store.lastError == nil, "store starts empty")
		store.upsert(registered)
		store.setAccount(account)
		check(store.lastError == nil, "store saves (\(store.lastError ?? ""))")
		check(store.host(id: "00:A1:B2:C3:D4:E5")?.nickname == "PS5-123", "store normalises id")
		check(mode(store.fileURL.path) == 0o600, "file is 0600 (got \(String(mode(store.fileURL.path), radix: 8)))")
		check(mode(dir.path) == 0o700, "dir is 0700")
		store.noteDiscovered([host])
		check(store.hosts.first?.lastKnownAddress == "192.168.1.20", "discovery updates lastKnownAddress")
		var rekeyed = registered
		rekeyed.rpKey = Data(repeating: 9, count: 16)
		store.upsert(rekeyed)
		check(store.hosts.count == 1 && store.hosts[0].rpKey == rekeyed.rpKey && store.hosts[0].lastKnownAddress == "192.168.1.20", "upsert replaces, keeps address")

		let reloaded = HostStore(directory: dir)
		check(reloaded.hosts == store.hosts && reloaded.account == account, "store reloads identically")
		let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
		check(files == ["pairing.json"], "no temp files left (\(files))")
		let json = (try? String(contentsOf: store.fileURL, encoding: .utf8)) ?? ""
		check(json.contains("\"hosts\"") && json.contains("\"account\"") && json.contains("\"version\""), "file layout")

		reloaded.remove(id: "00A1B2C3D4E5")
		check(HostStore(directory: dir).hosts.isEmpty, "remove persists")

		// One valid + one broken host: keep the valid one, back up the file.
		let mixed = """
		{"version":1,"account":{"accountID":"AQAAAAAAAAA="},"hosts":[
		 {"id":"00A1B2C3D4E5","nickname":"Good","isPS5":true,"target":1000100,"registKey":"\(key.base64EncodedString())","rpKey":"\(key.base64EncodedString())","rpKeyType":0,"serverMAC":"AKGyw9Tl"},
		 {"id":"zzz","nickname":"Bad"},
		 {"id":"AABBCCDDEEFF","nickname":"ShortKey","isPS5":true,"target":1000100,"registKey":"AAEC","rpKey":"AAEC","rpKeyType":0,"serverMAC":"AKGyw9Tl"}
		]}
		"""
		try? Data(mixed.utf8).write(to: store.fileURL)
		chmod(store.fileURL.path, 0o644)
		let tolerant = HostStore(directory: dir)
		check(tolerant.hosts.map(\.nickname) == ["Good"], "tolerant load keeps valid host (\(tolerant.hosts.map(\.nickname)))")
		check(tolerant.account?.accountID == Data(base64Encoded: "AQAAAAAAAAA="), "tolerant load keeps account")
		check(tolerant.lastError != nil, "tolerant load reports skipped entries")
		check(mode(store.fileURL.path) == 0o600, "load tightens 0644 to 0600")
		let backups = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains(".bak-") }
		check(backups.count == 1 && mode(dir.appendingPathComponent(backups[0]).path) == 0o600, "backup kept with 0600")

		try? Data("{ not json".utf8).write(to: store.fileURL)
		let corrupt = HostStore(directory: dir)
		check(corrupt.hosts.isEmpty && corrupt.lastError != nil, "corrupt file tolerated")
		check(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.contains(".corrupt-") }, "corrupt file set aside")
	}

	if network {
		// Live lifetime checks against TEST-NET-1 (192.0.2.1, RFC 5737): nothing answers there, so
		// these never reach a real console.
		let testNet = DiscoveredHost(id: "", name: "TEST-NET", address: "192.0.2.1", isPS5: true, state: .unknown, systemVersion: "", target: 1_000_100, requestPort: 9295)

		// 1. Cancel mid-flight: ps_regist_destroy from the cancel path, CANCELED callback inside it.
		let started = Date()
		let task = Task { () -> Error? in
			do { _ = try await Registrar().register(host: testNet, account: account, pin: "12345678", consolePin: nil); return nil } catch { return error }
		}
		try? await Task.sleep(nanoseconds: 500_000_000)
		task.cancel()
		let cancelError = await task.value
		let elapsed = Date().timeIntervalSince(started)
		check(cancelError is CancellationError, "mid-flight cancel -> CancellationError (got \(String(describing: cancelError)))")
		check(elapsed < 1.5, "mid-flight cancel is prompt (\(String(format: "%.2f", elapsed)) s)")

		// 2. Timeout path: callback FAILED, destroy off the callback thread, diagnosed error.
		let timeoutError = await registerError(testNet, account, "12345678")
		check(timeoutError == .consoleNotResponding(address: "192.0.2.1"), "timeout -> consoleNotResponding (got \(String(describing: timeoutError)))")

		// 3. Several concurrent attempts, half cancelled at different times: no crash, all finish.
		let results = await withTaskGroup(of: Error?.self, returning: [Error?].self) { group in
			for i in 0 ..< 6 {
				group.addTask {
					let inner = Task { () -> Error? in
						do { _ = try await Registrar().register(host: testNet, account: account, pin: "12345678", consolePin: nil); return nil } catch { return error }
					}
					if i % 2 == 0 {
						try? await Task.sleep(nanoseconds: UInt64(i) * 150_000_000)
						inner.cancel()
					}
					return await inner.value
				}
			}
			var all: [Error?] = []
			for await r in group { all.append(r) }
			return all
		}
		check(results.count == 6 && results.allSatisfy { $0 != nil }, "concurrent attempts all finish with an error")
		check(results.filter { $0 is CancellationError }.count == 3, "concurrent: 3 cancelled")

		// 4. Discovery start/stop idempotence and restart (only listens + broadcasts SRCH).
		let discovery = DiscoveryService()
		discovery.start()
		discovery.start()
		check(discovery.isRunning && discovery.lastError == nil, "discovery starts (\(discovery.lastError ?? ""))")
		let first = await discovery.waitForHost(timeout: 4) { _ in true }
		discovery.stop()
		discovery.stop()
		check(!discovery.isRunning && discovery.hosts.isEmpty, "discovery stop clears hosts")
		try? await Task.sleep(nanoseconds: 300_000_000)
		check(discovery.hosts.isEmpty, "no updates after stop")
		discovery.start()
		if first != nil {
			let again = await discovery.waitForHost(timeout: 4) { $0.id == first!.id }
			check(again != nil, "discovery restart finds \(first!.name) again")
			print("  (discovered \(first!.name) \(first!.address) \(first!.state.rawValue) id=\(first!.id))")
		} else {
			print("  (no console answered discovery; restart check skipped)")
		}
		discovery.stop()

		// 5. Wake call path (packet to TEST-NET).
		let fakeKey = Data("1a2b3c4d".utf8) + Data(repeating: 0, count: 8)
		let wakeHost = RegisteredHost(id: "AABBCCDDEEFF", nickname: "x", isPS5: true, target: 1_000_100, registKey: fakeKey, rpKey: key, rpKeyType: 0, serverMAC: Data(repeating: 0, count: 6), lastKnownAddress: "192.0.2.1")
		check((try? wake(host: wakeHost)) != nil, "wake sends")
		var noAddr = wakeHost
		noAddr.lastKnownAddress = nil
		do { try wake(host: noAddr); check(false, "wake without address throws") } catch { check((error as? WakeError) == .noAddress, "wake without address -> noAddress") }
		var badKey = wakeHost
		badKey.registKey = Data(repeating: 0xFF, count: 16)
		do { try wake(host: badKey); check(false, "wake with bad key throws") } catch { check(error is WakeError, "wake with non-hex key -> WakeError") }
	}

	print("selftest: \(passes) passed, \(failures) failed")
	return failures == 0
}
