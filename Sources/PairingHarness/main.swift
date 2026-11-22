import Foundation
import PSContracts
import PSPairing

// ps-pairing-harness: exercise PSPairing from the command line.

let usage = """
usage: ps-pairing-harness [--store <dir>] [--log] <command>

  discover [seconds]                              list consoles on the LAN (default 5 s)
  register <ip> <account-id-base64> <pin> [console-pin]
                                                  pair, print the result as JSON, save it
  wake <host-id> [--no-wait] [timeout-seconds]    wake a paired console, wait until ready
  list                                            show saved consoles (no secrets)
  psn-login-url                                   print Sony's sign-in URL (open it in a browser)
  psn-account <redirect-url>                      exchange the redirect URL for the account id,
                                                  print it (base64) and save it
  selftest [net]                                  offline checks of input handling / PSN helpers;
                                                  "net" adds lifetime checks against 192.0.2.1 (TEST-NET)

  --store <dir>   use <dir> instead of ~/Library/Application Support/PlayStream
  --log           echo protocol core log lines to stderr
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
	FileHandle.standardError.write(Data("error: \(message)\n".utf8))
	exit(code)
}

func describe(_ error: Error) -> String {
	let e = error as? LocalizedError
	var text = e?.errorDescription ?? "\(error)"
	if let hint = e?.recoverySuggestion { text += "\n  hint: \(hint)" }
	return text
}

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
var storeDir: URL?
if let i = args.firstIndex(of: "--store") {
	guard i + 1 < args.count else { fail("--store needs a directory") }
	storeDir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
	args.removeSubrange(i ... i + 1)
}
if let i = args.firstIndex(of: "--log") {
	BridgeLog.shared.echoToStderr = true
	args.remove(at: i)
}
guard let command = args.first else {
	print(usage)
	exit(2)
}
let rest = Array(args.dropFirst())

@MainActor
func printHosts(_ hosts: [DiscoveredHost], store: HostStore?) {
	if hosts.isEmpty {
		print("  (no consoles found)")
		return
	}
	for h in hosts {
		let paired = store?.host(id: h.id) != nil ? " [paired]" : ""
		var line = "  \(h.name)  \(h.address)  \(h.state.rawValue)  id=\(h.id)  \(h.isPS5 ? "PS5" : "PS4")  fw=\(h.systemVersion)  target=\(h.target)  port=\(h.requestPort)\(paired)"
		if let app = h.runningAppName { line += "  app=\(app)" + (h.runningAppTitleID.map { " (\($0))" } ?? "") }
		print(line)
	}
}

@MainActor
func runDiscover(seconds: Double) async {
	let store = HostStore(directory: storeDir)
	let discovery = DiscoveryService()
	discovery.start()
	if let error = discovery.lastError { fail(error) }
	print("Discovering for \(Int(seconds)) s…")
	var last: [DiscoveredHost] = []
	let deadline = Date().addingTimeInterval(seconds)
	while Date() < deadline {
		try? await Task.sleep(nanoseconds: 250_000_000)
		if discovery.hosts != last {
			last = discovery.hosts
			print("[\(String(format: "%.1f", seconds - deadline.timeIntervalSinceNow)) s] \(last.count) console(s):")
			printHosts(last, store: store)
		}
	}
	store.noteDiscovered(discovery.hosts)
	discovery.stop()
	discovery.stop() // idempotent
	print("Final:")
	printHosts(last, store: store)
}

@MainActor
func runRegister(ip: String, accountText: String, pin: String, consolePin: String?) async {
	let accountID: Data
	do { accountID = try PSNAuth.parseAccountID(accountText) } catch { fail(describe(error)) }
	do { _ = try PairingInput.parsePIN(pin) } catch { fail(describe(error)) }

	let store = HostStore(directory: storeDir)
	let discovery = DiscoveryService()
	print("Looking for the console at \(ip)…")
	var host = await discovery.waitForHost(timeout: 3) { $0.address == ip }
	discovery.stop()
	if let found = host {
		print("Found \(found.name) (\(found.id)), state \(found.state.rawValue), target \(found.target)")
	} else {
		print("Not found by discovery; assuming a PS5 (target \(ConsoleTarget.ps5v1)).")
		host = DiscoveredHost(id: "", name: ip, address: ip, isPS5: true, state: .unknown, systemVersion: "", target: ConsoleTarget.ps5v1, requestPort: 9295)
	}
	let account = PSNAccount(accountID: accountID)
	print("Registering… keep Link Device open on the console.")
	do {
		let registered = try await Registrar().register(host: host!, account: account, pin: pin, consolePin: consolePin)
		store.upsert(registered)
		store.setAccount(account)
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		print(String(decoding: try encoder.encode(registered), as: UTF8.self))
		print("Saved to \(store.fileURL.path)")
		if let error = store.lastError { print("warning: \(error)") }
	} catch {
		fail(describe(error))
	}
}

@MainActor
func runWake(id: String, wait: Bool, timeout: Double) async {
	let store = HostStore(directory: storeDir)
	guard let host = store.host(id: id) else {
		fail("no paired console with id \(id). Paired: \(store.hosts.map(\.id).joined(separator: ", "))")
	}
	let discovery = DiscoveryService()
	store.track(discovery)
	if !wait {
		discovery.start()
		_ = await discovery.waitForHost(timeout: 2) { $0.id == host.id }
		let address = discovery.host(id: host.id)?.address ?? host.lastKnownAddress
		do {
			try wake(host: host, address: address)
			print("Wake packet sent to \(address ?? "?").")
		} catch { fail(describe(error)) }
		discovery.stop()
		return
	}
	print("Waking \(host.nickname)…")
	do {
		let ready = try await discovery.wakeAndWaitUntilReady(host, timeout: timeout)
		print("\(ready.name) is ready at \(ready.address).")
	} catch {
		fail(describe(error))
	}
	discovery.stop()
}

@MainActor
func runList() {
	let store = HostStore(directory: storeDir)
	print("Store: \(store.fileURL.path)")
	if let error = store.lastError { print("warning: \(error)") }
	print("Account: \(store.account == nil ? "not set" : "set" + (store.account?.onlineID.map { " (\($0))" } ?? ""))")
	for h in store.hosts {
		print("  \(h.nickname)  id=\(h.id)  \(h.isPS5 ? "PS5" : "PS4")  target=\(h.target)  last=\(h.lastKnownAddress ?? "-")")
	}
	if store.hosts.isEmpty { print("  (no paired consoles)") }
}

switch command {
case "discover":
	await runDiscover(seconds: rest.first.flatMap(Double.init) ?? 5)
case "register":
	guard rest.count >= 3 else { fail("register <ip> <account-id-base64> <pin> [console-pin]") }
	// Allow the PIN to be given as two words ("1234 5678").
	var pinWords = Array(rest[2...])
	var consolePin: String?
	if pinWords.count >= 2, pinWords.joined().count > 8, let last = pinWords.last, last.count == 4, pinWords.dropLast().joined().count == 8 {
		consolePin = pinWords.removeLast()
	}
	await runRegister(ip: rest[0], accountText: rest[1], pin: pinWords.joined(separator: " "), consolePin: consolePin)
case "wake":
	guard let id = rest.first else { fail("wake <host-id>") }
	let wait = !rest.contains("--no-wait")
	let timeout = rest.dropFirst().compactMap(Double.init).first ?? 60
	await runWake(id: id, wait: wait, timeout: timeout)
case "list":
	runList()
case "psn-login-url":
	print(PSNAuth.authorizeURL().absoluteString)
	print("Sign in, then copy the full address of the page that says \"redirect\" and run:")
	print("  ps-pairing-harness psn-account '<that address>'")
case "psn-account":
	guard let text = rest.first else { fail("psn-account <redirect-url>") }
	do {
		let code = try PSNAuth.authorizationCode(fromPastedText: text)
		let account = try await PSNAuth.fetchAccount(authorizationCode: code)
		let store = HostStore(directory: storeDir)
		store.setAccount(account)
		print("Account ID: \(account.accountIDBase64)" + (account.onlineID.map { "  (\($0))" } ?? ""))
		print("Saved to \(store.fileURL.path)")
	} catch {
		fail(describe(error))
	}
case "render-ui":
	await renderUI(to: URL(fileURLWithPath: rest.first ?? "pairing-ui"), storeDir: storeDir)
case "selftest":
	exit(await runSelfTest(storeDir: storeDir, network: rest.first == "net") ? 0 : 1)
default:
	print(usage)
	exit(2)
}
