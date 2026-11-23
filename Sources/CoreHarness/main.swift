import Darwin
import Foundation
import PSCore

// ps-core-harness: the debugging tools without the app.
//
//   ps-core-harness selftest [--scratch <dir>] [--app-sources <dir>]
//       Runs the headless checks: control protocol, settings catalog, hitch notes, controller
//       activity, resume policy, relaunch helper, debug directory, PSCAP1 writer, flight
//       recorder (and its cost on the stream thread), and the control channel end to end against
//       a synthetic session. Exit code 0 when everything held.
//
//   ps-core-harness serve --root <dir> [options]
//       Runs a headless host with a synthetic stream until interrupted, so `scripts/psctl
//       --socket <dir>/control.sock ...` can be tried against it. Everything it writes stays in
//       <dir>; it never touches the real app's socket, log, settings or debug files.
//         --fps <n>                 frame rate of the synthetic stream (default 60)
//         --bitrate-mbps <n>        its bitrate (default 15)
//         --stall-every <frames>    every n-th frame arrives late (a network stall)
//         --stall-ms <ms>           by this much (default 120)
//         --busy-seconds <s>        the fake player holds a button this long after start
//         --busy-attempts <n>       the console refuses the first n connections ("already in use")
//         --no-session              do not start a session at launch
//         --fresh                   forget the settings and resume record of an earlier run
//         --relaunch-launcher <cmd> command the relaunch helper runs with the bundle path
//                                   appended (repeat the option for each word); without it
//                                   `relaunch` is a dry run
//         --seconds <s>             exit by itself after this long

setvbuf(stdout, nil, _IOLBF, 0)

var arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.isEmpty ? "help" : arguments.removeFirst()

func value(_ name: String) -> String? {
	guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
	return arguments[index + 1]
}

func values(_ name: String) -> [String] {
	var out: [String] = []
	var index = 0
	while index + 1 < arguments.count {
		if arguments[index] == name {
			out.append(arguments[index + 1])
			index += 2
		} else {
			index += 1
		}
	}
	return out
}

func flag(_ name: String) -> Bool { arguments.contains(name) }

switch mode {
case "selftest":
	let scratch = value("--scratch").map { URL(fileURLWithPath: $0) }
		?? FileManager.default.temporaryDirectory.appendingPathComponent("ps-core-harness-\(getpid())", isDirectory: true)
	try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
	// Unix socket paths are short; keep the scratch directory shallow.
	let appSources = value("--app-sources").map { URL(fileURLWithPath: $0) }
		?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("App")
	CoreLog.install(ownCoreCallback: false, directory: scratch.appendingPathComponent("logs", isDirectory: true))
	// The app ignores SIGPIPE; here it stays armed so that a connection the server writes to
	// after the client has gone fails the run loudly if the socket-level protection ever breaks.
	ControlServer.ignoresSIGPIPE = false
	signal(SIGPIPE) { _ in
		FileHandle.standardError.write(Data("FAIL: SIGPIPE raised (a write to a closed connection was not protected)\n".utf8))
		_exit(99)
	}
	print("ps-core-harness selftest, scratch directory \(scratch.path)")
	let ok = SelfTest(scratch: scratch, appSources: FileManager.default.fileExists(atPath: appSources.path) ? appSources : nil).run()
	if value("--scratch") == nil { try? FileManager.default.removeItem(at: scratch) }
	exit(ok ? 0 : 1)

case "serve":
	guard let rootPath = value("--root") else {
		print("serve needs --root <dir>")
		exit(2)
	}
	let root = URL(fileURLWithPath: rootPath)
	var options = HeadlessHost.Options()
	if let v = value("--fps").flatMap(Double.init) { options.fps = v }
	if let v = value("--bitrate-mbps").flatMap(Double.init) { options.bitrateMbps = v }
	if let v = value("--stall-every").flatMap(Int.init) { options.stallEvery = v }
	if let v = value("--stall-ms").flatMap(Double.init) { options.stallMs = v }
	if let v = value("--busy-seconds").flatMap(Double.init) { options.busySeconds = v }
	if let v = value("--busy-attempts").flatMap(Int.init) { options.busyAttempts = v }
	options.relaunchLauncher = values("--relaunch-launcher")
	options.startSession = !flag("--no-session")

	try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	CoreLog.install(ownCoreCallback: false, directory: root.appendingPathComponent("logs", isDirectory: true))
	let host: HeadlessHost
	do {
		host = try HeadlessHost(root: root, options: options)
		if flag("--fresh") {
			host.removeDefaults()
			host.resumeStore.clear()
		}
		try host.start()
	} catch {
		print("could not start: \(error)")
		exit(1)
	}
	print("ps-core-harness serving, pid \(getpid())")
	print("  socket  \(host.socketURL.path)")
	print("  log     \(CoreLog.fileURL.path)")
	print("  debug   \(host.storage.root.path)")
	print("try: scripts/psctl --socket \(host.socketURL.path) status")

	// Leave nothing behind on Ctrl-C or kill.
	var sources: [DispatchSourceSignal] = []
	for sig in [SIGINT, SIGTERM] {
		signal(sig, SIG_IGN)
		let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
		source.setEventHandler {
			host.shutdown()
			print("ps-core-harness stopped")
			exit(0)
		}
		source.resume()
		sources.append(source)
	}
	if let seconds = value("--seconds").flatMap(Double.init) {
		DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
			host.shutdown()
			print("ps-core-harness stopped after \(seconds) s")
			exit(0)
		}
	}
	dispatchMain()

default:
	print("""
	usage:
	  ps-core-harness selftest [--scratch <dir>] [--app-sources <dir>]
	  ps-core-harness serve --root <dir> [--fps n] [--bitrate-mbps n] [--stall-every frames] [--stall-ms ms]
	                        [--busy-seconds s] [--busy-attempts n] [--no-session] [--fresh]
	                        [--relaunch-launcher word ...] [--seconds s]
	""")
	exit(mode == "help" || mode == "--help" ? 0 : 2)
}
