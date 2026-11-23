import Darwin
import Foundation
import PSContracts
import PSCore

/// Headless checks of the debugging tools. Each check prints one line; the process exit code
/// says whether all of them held.
final class SelfTest {
	private var passed = 0
	private var failures: [String] = []
	private let scratch: URL
	private let appSources: URL?
	private var section = ""

	init(scratch: URL, appSources: URL?) {
		self.scratch = scratch
		self.appSources = appSources
	}

	private func begin(_ name: String) {
		section = name
		print("\n== \(name)")
	}

	private func expect(_ condition: @autoclosure () -> Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
		if condition() {
			passed += 1
			print("  ok    \(what)")
		} else {
			let extra = detail()
			failures.append("\(section): \(what)" + (extra.isEmpty ? "" : " [\(extra)]"))
			print("  FAIL  \(what)" + (extra.isEmpty ? "" : "  [\(extra)]"))
		}
	}

	private func info(_ text: String) { print("        \(text)") }

	private func directory(_ name: String) -> URL {
		let url = scratch.appendingPathComponent(name, isDirectory: true)
		try? FileManager.default.removeItem(at: url)
		try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url
	}

	func run() -> Bool {
		testProtocol()
		testSettings()
		testHitchDetector()
		testActivityAndIdle()
		testResumePolicy()
		testRelauncher()
		testStorage()
		testCaptureWriter()
		testFlightRecorder()
		testFlightRecorderCost()
		testControlChannel()
		print("\n\(passed) checks passed, \(failures.count) failed")
		for failure in failures { print("  FAILED: \(failure)") }
		return failures.isEmpty
	}

	// MARK: - Protocol

	private struct Reflected {
		enum Mode: String { case fast, slow }
		enum Plain { case one, two }
		var count = 3
		var ratio = 0.5
		var missing: Double?
		var present: Double? = 2.25
		var mode = Mode.slow
		var plain = Plain.two
		var values: [Float] = [1.5, 2.5]
		var nested = Nested()
		var notANumber = Double.nan
		struct Nested { var flag = true; var name = "n" }
	}

	private func testProtocol() {
		begin("Control protocol")
		let json = try? ControlRequest.parse(Data(#"{"cmd":"settings","args":["set","stream.upscaler",3,true],"opts":{"when-idle":true,"idle_seconds":"4"}}"#.utf8))
		expect(json?.command == "settings" && json?.args == ["set", "stream.upscaler", "3", "true"], "JSON request: command and arguments (numbers and booleans become text)", "\(String(describing: json?.args))")
		let bare = try? ControlRequest.parse(Data("tune pacer.marginMs 6\n".utf8))
		expect(bare?.command == "tune" && bare?.args == ["pacer.marginMs", "6"], "bare command line request")
		expect((try? ControlRequest.parse(Data("   \n".utf8))) == nil, "empty request is rejected")
		expect((try? ControlRequest.parse(Data("{not json".utf8))) == nil, "broken JSON is rejected")

		let reflected = JSONValue.reflect(Reflected()) as? [String: Any] ?? [:]
		expect(reflected["count"] as? Int == 3 && reflected["ratio"] as? Double == 0.5, "reflection: numbers")
		expect(reflected["missing"] is NSNull && reflected["present"] as? Double == 2.25, "reflection: optionals become the value or null")
		expect(reflected["mode"] as? String == "slow" && reflected["plain"] as? String == "two", "reflection: enums become raw value or case name")
		expect((reflected["values"] as? [Any])?.count == 2 && (reflected["nested"] as? [String: Any])?["flag"] as? Bool == true, "reflection: arrays and nested structs")
		expect(reflected["notANumber"] is NSNull, "reflection: NaN becomes null")
		let encoded = ControlResponse.success(["x": Double.infinity, "when": Date(timeIntervalSince1970: 0), "file": URL(fileURLWithPath: "/tmp/a b")]).encoded()
		let decoded = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
		let result = decoded?["result"] as? [String: Any]
		expect(decoded?["ok"] as? Bool == true && result?["x"] is NSNull && result?["file"] as? String == "/tmp/a b" && (result?["when"] as? String)?.hasPrefix("1970-01-01") == true,
		       "response encoding survives infinity, dates and URLs", String(decoding: encoded, as: UTF8.self))
		expect(encoded.last == 0x0A && encoded.dropLast().firstIndex(of: 0x0A) == nil, "a response is exactly one line")
	}

	// MARK: - Settings

	private func testSettings() {
		begin("Settings catalog")
		let defaults = HarnessDefaults(fileURL: nil)

		expect(Set(SettingsCatalog.all.map(\.key)).count == SettingsCatalog.all.count, "keys are unique")
		expect(SettingsCatalog.int("stream.upscaler", in: defaults) == 0 && SettingsCatalog.bool("debug.controlChannel", in: defaults) && SettingsCatalog.double("stream.bitrateMbps", in: defaults) == 30, "defaults are reported when nothing is stored")
		let before = SettingsCatalog.fingerprint(defaults)

		let named = try? SettingsCatalog.set("upscaler", to: "fsr1", in: defaults)
		expect(named?.descriptor.key == "stream.upscaler" && named?.newValue as? Int == 3 && named?.changed == true, "short key and value name: upscaler fsr1 -> stream.upscaler = 3")
		expect(defaults.object(forKey: "stream.upscaler") as? Int == 3, "stored as an integer, as @AppStorage expects")
		expect(SettingsCatalog.fingerprint(defaults) != before, "fingerprint changes with a setting")
		let same = try? SettingsCatalog.set("stream.upscaler", to: "3", in: defaults)
		expect(same?.changed == false, "setting the same value reports unchanged")

		expect((try? SettingsCatalog.set("stream.bitrateMbps", to: "40", in: defaults))?.newValue as? Double == 40, "double setting")
		expect(defaults.object(forKey: "stream.bitrateMbps") is Double, "stored as a double")
		expect((try? SettingsCatalog.set("stream.framePacing", to: "off", in: defaults))?.newValue as? Bool == false, "bool setting accepts on/off")
		expect((try? SettingsCatalog.set("stream.fps", to: "45", in: defaults)) == nil, "value outside the allowed list is rejected (fps 45)")
		expect((try? SettingsCatalog.set("stream.bitrateMbps", to: "500", in: defaults)) == nil, "value outside the range is rejected (bitrate 500)")
		expect((try? SettingsCatalog.set("stream.framePacing", to: "maybe", in: defaults)) == nil, "non-boolean for a bool is rejected")
		expect((try? SettingsCatalog.set("stream.nope", to: "1", in: defaults)) == nil, "unknown key is rejected")
		do {
			_ = try SettingsCatalog.set("bitrate", to: "1", in: defaults)
			expect(false, "unknown key error suggests close matches")
		} catch {
			expect("\(error)".contains("stream.bitrateMbps"), "unknown key error suggests close matches", "\(error)")
		}
		let reset = try? SettingsCatalog.set("stream.upscaler", to: "default", in: defaults)
		expect(reset?.newValue as? Int == 0 && defaults.object(forKey: "stream.upscaler") == nil, "\"default\" removes the stored value")
		expect(SettingsCatalog.descriptor(for: "stream.bitrateMbps")?.applies == .nextConnection && SettingsCatalog.descriptor(for: "stream.upscaler")?.applies == .live, "live versus next-connection is recorded per setting")
		let listing = SettingsCatalog.listing(defaults)
		expect(listing.count == SettingsCatalog.all.count && listing.allSatisfy { $0["value"] != nil && $0["default"] != nil && $0["applies"] != nil }, "listing has value, default and applies for every setting")

		// The catalog mirrors App/AppSettings.swift; check the two against each other.
		guard let appSources, let source = try? String(contentsOf: appSources.appendingPathComponent("AppSettings.swift"), encoding: .utf8) else {
			info("App/AppSettings.swift not found (run from the repository root or pass --app-sources): consistency check skipped")
			return
		}
		var declared: [String: Double] = [:]
		var unparsed: [String] = []
		for line in source.split(separator: "\n") {
			guard let range = line.range(of: "@AppStorage(\"") else { continue }
			let rest = line[range.upperBound...]
			guard let keyEnd = rest.firstIndex(of: "\""), let equals = rest.lastIndex(of: "=") else { continue }
			let key = String(rest[..<keyEnd])
			let literal = rest[rest.index(after: equals)...].trimmingCharacters(in: .whitespaces)
			let value: Double?
			switch literal {
			case "true": value = 1
			case "false": value = 0
			case ".p1080": value = 1080
			case "VideoCodec.hevcHDR.rawValue": value = 2
			default: value = Double(literal)
			}
			if let value { declared[key] = value } else { unparsed.append("\(key) = \(literal)") }
		}
		expect(declared.count >= 20 && unparsed.isEmpty, "parsed the @AppStorage declarations in App/AppSettings.swift (\(declared.count))", unparsed.joined(separator: "; "))
		let missing = declared.keys.filter { SettingsCatalog.descriptor(for: $0) == nil }.sorted()
		expect(missing.isEmpty, "every app setting is in the catalog", missing.joined(separator: ", "))
		let different = declared.filter { key, value in SettingsCatalog.all.first { $0.key == key }.map { $0.defaultValue != value } ?? false }.keys.sorted()
		expect(different.isEmpty, "catalog defaults equal the app's defaults", different.joined(separator: ", "))
		let appOnly = SettingsCatalog.all.map(\.key).filter { !$0.hasPrefix("debug.") && !$0.hasPrefix("resume.") && declared[$0] == nil }
		expect(appOnly.isEmpty, "every stream/controller/audio setting in the catalog exists in the app", appOnly.joined(separator: ", "))
	}

	// MARK: - Hitch detector

	/// Feeds the detector a synthetic session at four samples a second.
	private struct StatsSimulator {
		var detector = HitchDetector()
		var time = 100.0
		var sample = HitchSample(time: 100)
		var presented: [Float] = []
		var arrivals: [Float] = []
		var lines: [String] = []
		var fps = 60.0
		var quantized = false
		private var seed: UInt64 = 42

		private mutating func noise() -> Float {
			seed = seed &* 6364136223846793005 &+ 1442695040888963407
			return quantized ? 0 : Float(seed >> 40) / Float(1 << 24) * 0.4 - 0.2
		}

		/// Advances a quarter of a second; `edit` may alter what happened in it.
		mutating func tick(longFrameMs: Float? = nil, gapMs: Float? = nil, _ edit: (inout HitchSample) -> Void = { _ in }) {
			time += 0.25
			let frames = Int(fps / 4)
			let interval = Float(1000 / fps)
			for i in 0..<frames {
				presented.append(i == 3 && longFrameMs != nil ? longFrameMs! : interval + noise())
				arrivals.append(i == 5 && gapMs != nil ? gapMs! : interval + noise())
			}
			presented = Array(presented.suffix(240))
			arrivals = Array(arrivals.suffix(240))
			sample.time = time
			sample.framesReceived += frames
			sample.presentedIntervalsMs = presented
			sample.arrivalIntervalsMs = arrivals
			sample.presentedFPS = fps
			sample.streamFPS = fps
			sample.bitrateMbps = 15.8
			sample.rttMs = 6.2
			sample.audioUnderruns = sample.audioUnderruns ?? 0
			sample.audioBufferedMs = 43
			edit(&sample)
			if let line = detector.ingest(sample) { lines.append(line) }
		}

		mutating func run(seconds: Double) {
			for _ in 0..<Int(seconds * 4) { tick() }
		}
	}

	private func testHitchDetector() {
		begin("Hitch notes")
		func fresh(_ previous: [Float], _ current: [Float], _ expected: Int) -> [Float] { Array(HitchDetector.newEntries(previous: previous, current: current, expected: expected)) }
		expect(fresh([1, 2, 3], [1, 2, 3, 4, 5], 2) == [4, 5], "history diff: growing history")
		expect(fresh([1, 2, 3, 4], [3, 4, 5, 6], 2) == [5, 6], "history diff: full history shifted by two")
		expect(fresh([1, 2, 3, 4], [1, 2, 3, 4], 2) == [], "history diff: nothing new")
		expect(fresh([7, 7, 7, 7], [7, 7, 9, 7], 2) == [9, 7], "history diff: repeated values, the expected count picks the shift")
		expect(fresh([1, 2, 3, 4], [9, 8, 7, 6], 1) == [9, 8, 7, 6], "history diff: no overlap means everything is new")
		expect(fresh([], [1, 2], 0) == [1, 2], "history diff: first snapshot")

		var clean = StatsSimulator()
		clean.run(seconds: 30)
		expect(clean.lines.isEmpty, "a clean 60 fps session writes no notes", clean.lines.first ?? "")

		var quantized = StatsSimulator()
		quantized.quantized = true
		quantized.run(seconds: 10)
		quantized.tick(longFrameMs: 50)
		quantized.run(seconds: 2)
		expect(quantized.lines.count == 1 && quantized.lines[0].contains("frame 50.0 ms (x3.0 of 16.7)"), "one long frame in perfectly regular frame times is found exactly once", quantized.lines.joined(separator: " / "))

		var long = StatsSimulator()
		long.run(seconds: 10)
		long.tick(longFrameMs: 83.4)
		expect(long.lines.count == 1 && long.lines[0].hasPrefix("Hitch: frame 83.4 ms"), "long frame time is noted with its length", long.lines.last ?? "none")
		info(long.lines.last ?? "")
		long.run(seconds: 5)
		expect(long.lines.count == 1, "and is not repeated while it stays in the history")

		var doubled = StatsSimulator()
		doubled.run(seconds: 10)
		doubled.tick(longFrameMs: 33.3)
		expect(doubled.lines.isEmpty, "a single doubled frame at 60 fps is below the hitch threshold (factor 2.5)")
		doubled.detector.configuration.longFrameFactor = 1.8
		doubled.tick(longFrameMs: 33.3)
		expect(doubled.lines.count == 1, "the threshold follows debug.hitchFrameFactor")

		var gap = StatsSimulator()
		gap.run(seconds: 10)
		gap.tick(gapMs: 142)
		expect(gap.lines.count == 1 && gap.lines[0].contains("net gap 142 ms"), "network arrival gap is noted", gap.lines.last ?? "none")
		info(gap.lines.last ?? "")

		var audio = StatsSimulator()
		audio.run(seconds: 10)
		audio.tick { $0.audioUnderruns = ($0.audioUnderruns ?? 0) + 1 }
		expect(audio.lines.count == 1 && audio.lines[0].contains("audio underrun +1"), "audio underrun is noted", audio.lines.last ?? "none")

		var late = StatsSimulator()
		late.run(seconds: 10)
		late.tick { $0.framesLate += 1 }
		expect(late.lines.isEmpty, "a single late frame is not a burst")
		late.run(seconds: 2)
		late.tick { $0.framesLate += 2 }
		late.tick { $0.framesLate += 2 }
		expect(late.lines.count == 1 && late.lines[0].contains("late +4"), "several late frames within a second are a burst", late.lines.last ?? "none")

		var mixed = StatsSimulator()
		mixed.run(seconds: 10)
		mixed.tick(longFrameMs: 150, gapMs: 142) {
			$0.framesLostInNetwork += 2
			$0.framesDropped += 1
		}
		expect(mixed.lines.count == 1 && mixed.lines[0].contains("frame 150.0 ms") && mixed.lines[0].contains("net gap 142 ms") && mixed.lines[0].contains("net lost +2") && mixed.lines[0].contains("dropped +1"),
		       "one hitch with several symptoms is one line", mixed.lines.last ?? "none")
		info(mixed.lines.last ?? "")

		var storm = StatsSimulator()
		storm.run(seconds: 10)
		for _ in 0..<240 { storm.tick(longFrameMs: 120) } // a full minute of constant hitching
		let stormLines = storm.lines.count
		expect(stormLines >= 10 && stormLines <= 22, "a minute of constant hitching is rate-limited (\(stormLines) lines for 240 hitches)")
		expect(storm.lines.last?.contains("over ") == true, "held-back hitches are merged into the next line", storm.lines.last ?? "")

		var warmup = StatsSimulator()
		warmup.tick()
		warmup.tick(longFrameMs: 200, gapMs: 300)
		expect(warmup.lines.isEmpty, "nothing is reported while the stream is still starting")

		var stall = StatsSimulator()
		stall.run(seconds: 10)
		let frozen = stall.sample
		for i in 1...8 {
			var s = frozen
			s.time = frozen.time + Double(i) * 0.25
			if let line = stall.detector.ingest(s) { stall.lines.append(line) }
		}
		expect(stall.lines.count == 1 && stall.lines[0].contains("no video for 1.0 s"), "a stream that stops delivering frames is noted once", stall.lines.joined(separator: " / "))
	}

	// MARK: - Controller activity

	private final class StateSink: ControllerStateReceiver {
		var received: [ControllerState] = []
		func controllerStateDidChange(_ state: ControllerState) { received.append(state) }
	}

	private func testActivityAndIdle() {
		begin("Controller activity and idle wait")
		let monitor = ControllerActivityMonitor()
		let sink = StateSink()
		monitor.downstream = sink

		var held = ControllerState()
		held.buttons = [.cross]
		monitor.controllerStateDidChange(held)
		usleep(120_000)
		expect(monitor.idleSeconds == 0, "a held button is activity for as long as it is held")
		monitor.controllerStateDidChange(ControllerState())
		usleep(150_000)
		let afterRelease = monitor.idleSeconds
		expect(afterRelease > 0.1 && afterRelease < 0.5, "idle time counts from the release", "\(afterRelease)")
		var noisy = ControllerState()
		noisy.gyroX = 0.3
		noisy.accelY = 0.98
		noisy.leftX = 900 // stick drift inside the dead zone
		monitor.controllerStateDidChange(noisy)
		expect(monitor.idleSeconds >= afterRelease, "motion sensor noise and stick drift do not count as activity")
		var stick = ControllerState()
		stick.rightY = -20_000
		monitor.controllerStateDidChange(stick)
		expect(monitor.idleSeconds == 0, "a deflected stick is activity")
		var trigger = ControllerState()
		trigger.r2 = 200
		expect(!ControllerActivityMonitor.isAtRest(trigger), "a pulled trigger is activity")
		var touch = ControllerState()
		touch.touch0 = ControllerTouch(x: 10, y: 10, id: 3)
		expect(!ControllerActivityMonitor.isAtRest(touch), "a finger on the touchpad is activity")
		expect(sink.received.count == 4 && sink.received[0] == held && sink.received[3] == stick, "every snapshot is forwarded unchanged to the session")

		// Idle wait: busy for 0.4 s, then at rest.
		let queue = DispatchQueue(label: "selftest.idle")
		let busyUntil = Date().addingTimeInterval(0.4)
		let fake = ControllerActivityMonitor()
		let feeder = Thread {
			while Date() < busyUntil.addingTimeInterval(2) {
				var s = ControllerState()
				if Date() < busyUntil { s.buttons = [.square] }
				fake.controllerStateDidChange(s)
				usleep(20_000)
			}
		}
		feeder.start()
		let done = DispatchSemaphore(value: 0)
		var outcome: IdleWait.Outcome?
		let begun = Date()
		let wait = IdleWait(requiredIdleSeconds: 0.3, timeoutSeconds: 5, pollInterval: 0.05, queue: queue, idleSeconds: { fake.idleSeconds }) {
			outcome = $0
			done.signal()
		}
		_ = done.wait(timeout: .now() + 3)
		let took = Date().timeIntervalSince(begun)
		if case .idle = outcome { expect(took > 0.6 && took < 1.2, "idle wait fires once the controller has been at rest for the required time", "\(took) s") } else { expect(false, "idle wait fires once the controller has been at rest", "\(String(describing: outcome))") }
		expect(!wait.isPending, "and is finished afterwards")

		let never = DispatchSemaphore(value: 0)
		var timedOut: IdleWait.Outcome?
		let second = IdleWait(requiredIdleSeconds: 10, timeoutSeconds: 0.3, pollInterval: 0.05, queue: queue, idleSeconds: { 0 }) {
			timedOut = $0
			never.signal()
		}
		_ = never.wait(timeout: .now() + 2)
		expect(timedOut == .timedOut, "idle wait times out when the player never pauses")
		_ = second

		let cancelled = DispatchSemaphore(value: 0)
		var cancelOutcome: IdleWait.Outcome?
		let third = IdleWait(requiredIdleSeconds: 10, timeoutSeconds: 10, pollInterval: 0.05, queue: queue, idleSeconds: { 0 }) {
			cancelOutcome = $0
			cancelled.signal()
		}
		third.cancel()
		_ = cancelled.wait(timeout: .now() + 2)
		expect(cancelOutcome == .cancelled, "idle wait can be cancelled")
	}

	// MARK: - Resume policy

	private func testResumePolicy() {
		begin("Resume and reconnect policy")
		let now = Date()
		func record(_ reason: ResumeRecord.Reason, age: TimeInterval, endedAgo: TimeInterval? = nil) -> ResumeRecord {
			ResumeRecord(hostID: "AABBCCDDEEFF", hostName: "PS5", reason: reason, updatedAt: now.addingTimeInterval(-age), wasFullScreen: true, sessionEndedAt: endedAgo.map { now.addingTimeInterval(-$0) })
		}
		func decide(_ r: ResumeRecord?, enabled: Bool = true, account: Bool = true, registered: Bool = true, suppressed: Bool = false) -> ResumePolicy.Decision {
			ResumePolicy.decide(record: r, enabled: enabled, now: now, windowSeconds: 900, hasAccount: account, hostIsRegistered: registered, suppressed: suppressed)
		}
		func resumes(_ d: ResumePolicy.Decision) -> Bool { if case .resume = d { return true }; return false }
		func delay(_ d: ResumePolicy.Decision) -> TimeInterval? { if case .resume(_, let delay) = d { return delay }; return nil }
		func tellsUser(_ d: ResumePolicy.Decision) -> Bool? { if case .skip(_, let tell) = d { return tell }; return nil }

		expect(!resumes(decide(nil)), "no record (the session was ended on purpose): stay on the home screen")
		expect(resumes(decide(record(.relaunch, age: 1.2, endedAgo: 1.2))), "relaunch command: resume")
		let wait = delay(decide(record(.relaunch, age: 1.2, endedAgo: 1.2))) ?? -1
		expect(abs(wait - 1.8) < 0.01, "first attempt waits until 3 s after the old session was closed", "\(wait)")
		expect(delay(decide(record(.relaunch, age: 8, endedAgo: 8))) == 0, "no extra wait when the console has had its time")
		expect(resumes(decide(record(.quit, age: 120, endedAgo: 120))), "quit while streaming, reopened two minutes later: resume")
		expect(!resumes(decide(record(.quit, age: 3600, endedAgo: 3600))), "quit while streaming, reopened an hour later: the owner was done, do not resume")
		expect(resumes(decide(record(.streaming, age: 20))), "crash or kill while streaming, reopened right away: resume")
		expect(!resumes(decide(record(.streaming, age: 86_400))), "stale record from a crash long ago: do not resume")
		let noWindow: (ResumeRecord) -> ResumePolicy.Decision = { ResumePolicy.decide(record: $0, enabled: true, now: now, windowSeconds: 0, hasAccount: true, hostIsRegistered: true) }
		expect(resumes(noWindow(record(.relaunch, age: 4, endedAgo: 4))) && !resumes(noWindow(record(.quit, age: 4, endedAgo: 4))), "resume window 0: a quit never resumes, a relaunch command still does")
		expect(!resumes(decide(record(.quit, age: 5, endedAgo: 5), enabled: false)) && !resumes(decide(record(.streaming, age: 5), enabled: false)), "setting off: a quit or a crash does not resume")
		expect(resumes(decide(record(.relaunch, age: 1, endedAgo: 1), enabled: false)), "setting off: the relaunch command still brings its session back")
		expect(!resumes(decide(record(.relaunch, age: 1), suppressed: true)), "Option held at launch: do not resume")
		let noAccount = decide(record(.relaunch, age: 1), account: false)
		expect(!resumes(noAccount) && tellsUser(noAccount) == true, "PSN account missing: do not resume, and tell the owner why")
		let unpaired = decide(record(.relaunch, age: 1), registered: false)
		expect(!resumes(unpaired) && tellsUser(unpaired) == true, "console no longer paired: do not resume, and tell the owner why")

		expect(ReconnectPolicy.isConsoleBusy("Remote Play on Console is already in use"), "\"already in use\" (the reason in the real log) is recognised as console busy")
		expect(!ReconnectPolicy.isConsoleBusy("Stopped") && !ReconnectPolicy.isConsoleBusy("Connection refused") && !ReconnectPolicy.isConsoleBusy("Address already in use"), "other end reasons are not retried as busy")
		let delays = (1...8).map { ReconnectPolicy.delay(afterBusyAttempt: $0) }
		expect(delays.prefix(6).compactMap { $0 } == [2, 3, 4, 6, 8, 10] && delays[6] == nil, "busy retries back off 2, 3, 4, 6, 8, 10 s and then give up", "\(delays)")

		let store = ResumeStore(fileURL: directory("resume").appendingPathComponent("resume.json"))
		let saved = record(.relaunch, age: 0, endedAgo: 0)
		store.save(saved)
		let loaded = store.load()
		expect(loaded?.hostID == saved.hostID && loaded?.reason == .relaunch && loaded?.wasFullScreen == true, "resume record survives a save and load")
		let mode = (try? FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int) ?? 0
		expect(mode == 0o600, "resume record is private (0600)", String(mode, radix: 8))
		store.clear()
		expect(store.load() == nil, "and is gone after clear")
	}

	// MARK: - Relauncher

	private func makeBundle(_ url: URL, identifier: String, executable: Bool = true) {
		let macos = url.appendingPathComponent("Contents/MacOS")
		try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
		let info: [String: Any] = ["CFBundleExecutable": "Fake", "CFBundleIdentifier": identifier, "CFBundleShortVersionString": "9.9", "PSGitCommit": "abc1234", "PSBuildTime": "2026-11-23T02:00:00Z"]
		try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
		if executable {
			FileManager.default.createFile(atPath: macos.appendingPathComponent("Fake").path, contents: Data("#!/bin/sh\nexit 0\n".utf8), attributes: [.posixPermissions: 0o755])
		}
	}

	private func testRelauncher() {
		begin("Relaunch helper")
		let dir = directory("relaunch")
		let newBundle = dir.appendingPathComponent("New Build/PlayStream.app")
		let oldBundle = dir.appendingPathComponent("Old/PlayStream.app")
		makeBundle(newBundle, identifier: "dev.playstream.PlayStream")
		makeBundle(oldBundle, identifier: "dev.playstream.PlayStream")
		let broken = dir.appendingPathComponent("Broken/PlayStream.app")
		makeBundle(broken, identifier: "dev.playstream.PlayStream", executable: false)
		let other = dir.appendingPathComponent("Other.app")
		makeBundle(other, identifier: "com.example.other")

		let good = try? Relauncher.inspectBundle(at: newBundle, expectedIdentifier: "dev.playstream.PlayStream")
		expect(good?.gitCommit == "abc1234" && good?.version == "9.9" && good?.executable.lastPathComponent == "Fake", "a complete bundle is accepted and its build identity read")
		func refused(_ url: URL, _ id: String? = "dev.playstream.PlayStream") -> String? {
			do { _ = try Relauncher.inspectBundle(at: url, expectedIdentifier: id); return nil } catch { return "\(error)" }
		}
		expect(refused(dir.appendingPathComponent("Missing.app")) != nil, "a path that does not exist is refused")
		expect(refused(broken)?.contains("not executable") == true, "a bundle without its executable (build not finished) is refused", refused(broken) ?? "accepted")
		expect(refused(other)?.contains("com.example.other") == true, "a different app is refused", refused(other) ?? "accepted")
		expect(refused(dir) != nil, "a directory that is not an .app is refused")

		// The helper itself, with a launcher that only writes down what it was asked to start.
		let marker = dir.appendingPathComponent("launched.txt")
		let launcher = dir.appendingPathComponent("launcher.sh")
		try? Data("""
		#!/bin/sh
		# Fake launcher: records the bundle; fails for bundles under "Broken".
		case "$1" in *Broken*) exit 1;; esac
		echo "$1" >> "\(marker.path)"
		""".utf8).write(to: launcher)
		let log = dir.appendingPathComponent("relaunch.log")

		func launched() -> [String] {
			((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
		}

		// 1. Waits for the old process, then starts the new bundle (path with a space).
		let old = Process()
		old.executableURL = URL(fileURLWithPath: "/bin/sleep")
		old.arguments = ["0.7"]
		try? old.run()
		var plan = Relauncher.Plan(waitForPID: old.processIdentifier, bundle: newBundle, fallbackBundle: oldBundle, logURL: log)
		plan.launcher = ["/bin/sh", launcher.path]
		plan.verifyAfterSeconds = 0
		let helper = try? Relauncher.spawn(plan)
		expect((helper ?? 0) > 0, "helper process starts")
		usleep(350_000)
		expect(launched().isEmpty, "nothing is launched while the old process is still running")
		old.waitUntilExit()
		usleep(600_000)
		expect(launched() == [newBundle.path], "the new bundle is started once the old process has exited", "\(launched())")

		// 2. The new bundle cannot be launched: fall back to the old one.
		try? FileManager.default.removeItem(at: marker)
		var failing = Relauncher.Plan(waitForPID: 1, bundle: broken, fallbackBundle: oldBundle, logURL: log)
		failing.waitForPID = spawnShortLived()
		failing.launcher = ["/bin/sh", launcher.path]
		failing.verifyAfterSeconds = 0
		_ = try? Relauncher.spawn(failing)
		usleep(900_000)
		expect(launched() == [oldBundle.path], "when the new bundle cannot be launched, the previous one is started instead", "\(launched())")

		// 3. The launcher succeeds but no process from the new bundle is running afterwards.
		try? FileManager.default.removeItem(at: marker)
		var dead = Relauncher.Plan(waitForPID: spawnShortLived(), bundle: newBundle, fallbackBundle: oldBundle, logURL: log)
		dead.launcher = ["/bin/sh", launcher.path]
		dead.verifyAfterSeconds = 0.5
		_ = try? Relauncher.spawn(dead)
		usleep(1_600_000)
		expect(launched() == [newBundle.path, oldBundle.path], "when the new build is not running shortly after launch, the previous one is started", "\(launched())")

		// 4. An old process that refuses to exit is killed so the swap cannot hang.
		try? FileManager.default.removeItem(at: marker)
		let stuck = Process()
		stuck.executableURL = URL(fileURLWithPath: "/bin/sleep")
		stuck.arguments = ["30"]
		try? stuck.run()
		var forced = Relauncher.Plan(waitForPID: stuck.processIdentifier, bundle: newBundle, logURL: log)
		forced.launcher = ["/bin/sh", launcher.path]
		forced.verifyAfterSeconds = 0
		forced.killAfterSeconds = 0.5
		_ = try? Relauncher.spawn(forced)
		usleep(1_800_000)
		expect(!stuck.isRunning && launched() == [newBundle.path], "an old process that will not exit is killed after the time limit and the swap proceeds", "running \(stuck.isRunning), launched \(launched())")
		if stuck.isRunning { stuck.terminate() }
		let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
		expect(logText.contains("falling back to") && logText.contains("killing it"), "the helper writes what it did to its log")
	}

	/// Starts a process that exits almost at once and returns its id (already gone by the time
	/// the helper looks).
	private func spawnShortLived() -> pid_t {
		let p = Process()
		p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
		try? p.run()
		p.waitUntilExit()
		return p.processIdentifier
	}

	// MARK: - Debug storage

	private func testStorage() {
		begin("Debug directory housekeeping")
		let storage = DebugStorage(root: directory("debug"))
		let fm = FileManager.default
		func make(_ area: DebugStorage.Area, _ name: String, kilobytes: Int, ageSeconds: TimeInterval) -> URL {
			let dir = storage.directory(area)
			try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
			let url = dir.appendingPathComponent(name)
			fm.createFile(atPath: url.path, contents: Data(count: kilobytes * 1024))
			try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
			return url
		}
		let oldest = make(.captures, "a.pscap", kilobytes: 400, ageSeconds: 5000)
		let middle = make(.traces, "b.jsonl", kilobytes: 300, ageSeconds: 4000)
		let keep = make(.captures, "c.pscap", kilobytes: 300, ageSeconds: 3000)
		let fresh = make(.captures, "d.pscap", kilobytes: 500, ageSeconds: 5)
		let frames = storage.directory(.frames).appendingPathComponent("frames-old", isDirectory: true)
		try? fm.createDirectory(at: frames, withIntermediateDirectories: true)
		fm.createFile(atPath: frames.appendingPathComponent("p.png").path, contents: Data(count: 200 * 1024))
		try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-4500)], ofItemAtPath: frames.appendingPathComponent("p.png").path)
		try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-4500)], ofItemAtPath: frames.path)

		let usage = storage.usage()
		expect(usage["totalBytes"] as? Int64 == 1700 * 1024, "usage adds up files and picture directories", "\(usage["totalBytes"] ?? "nil")")
		let result = storage.cleanup(maxBytes: 900 * 1024)
		expect(!fm.fileExists(atPath: oldest.path) && !fm.fileExists(atPath: frames.path) && !fm.fileExists(atPath: middle.path), "the oldest items go first, a picture directory as one unit")
		expect(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: fresh.path), "newer items stay once the directory fits")
		expect(result.removedItems == 3 && result.remainingBytes == 800 * 1024, "the result says what was freed", "\(result)")
		let second = storage.cleanup(maxBytes: 100 * 1024, protecting: [keep])
		expect(fm.fileExists(atPath: keep.path) && fm.fileExists(atPath: fresh.path) && second.removedItems == 0, "a protected file and a file still being written (modified seconds ago) are never deleted")
		let named = try? storage.newFile(in: .captures, prefix: "flight", extension: "pscap")
		expect(named?.lastPathComponent.hasPrefix("flight-20") == true && named?.pathExtension == "pscap", "new files are named by time", named?.lastPathComponent ?? "nil")
	}

	// MARK: - Capture file writer

	private func testCaptureWriter() {
		begin("PSCAP1 incremental writer")
		let dir = directory("writer")
		let header = StreamCaptureHeader(profile: .ps5Max, startedAt: Date(timeIntervalSince1970: 1_800_000_000), notes: "{\"a\":1}")
		let records = [
			StreamCaptureRecord(arrivalNanoseconds: 0, framesLost: 0, frameRecovered: false, data: Data(SyntheticStream.makeHeader())),
			StreamCaptureRecord(arrivalNanoseconds: 0, framesLost: 0, frameRecovered: false, data: Data(SyntheticStream.makeFrame(index: 0, keyframe: true, size: 5000))),
			StreamCaptureRecord(arrivalNanoseconds: 16_666_667, framesLost: 3, frameRecovered: true, data: Data(SyntheticStream.makeFrame(index: 1, keyframe: false, size: 1200))),
			StreamCaptureRecord(arrivalNanoseconds: 33_400_000, framesLost: 70_000, frameRecovered: false, data: Data()),
		]
		let reference = dir.appendingPathComponent("reference.pscap")
		let incremental = dir.appendingPathComponent("incremental.pscap")
		do {
			try StreamCaptureFile.write(header: header, records: records, to: reference)
			let writer = try StreamCaptureWriter(url: incremental, header: header)
			for record in records { try writer.append(record) }
			try writer.close()
			let a = try Data(contentsOf: reference)
			let b = try Data(contentsOf: incremental)
			// The header is one line of JSON whose key order is not fixed; everything after it is.
			func body(_ data: Data) -> Data {
				let magicEnd = data.firstIndex(of: 0x0A)!
				let headerEnd = data[(magicEnd + 1)...].firstIndex(of: 0x0A)!
				return data[(headerEnd + 1)...]
			}
			expect(a.prefix(7) == b.prefix(7) && a.count == b.count && body(a) == body(b), "same magic, same length and byte-identical records as StreamCaptureFile.write", "\(a.count) vs \(b.count) bytes")
			expect(writer.recordCount == 4 && writer.bytesWritten == Int64(b.count), "the writer counts records and bytes")
			let read = try StreamCaptureFile.read(from: incremental)
			var clamped = records
			clamped[3].framesLost = 0xFFFF
			expect(read.header == header && read.records == clamped, "StreamCaptureFile.read returns the same header and records")
		} catch {
			expect(false, "PSCAP1 writer round trip", "\(error)")
		}
	}

	// MARK: - Flight recorder

	private final class CountingSink: VideoStreamSink {
		var frames = 0
		var started = 0
		var stopped = 0
		var accept = true
		func videoStreamWillStart(profile: StreamProfile) { started += 1 }
		func videoStreamDidReceive(accessUnit: UnsafeRawBufferPointer, framesLost: Int, frameRecovered: Bool) -> Bool {
			frames += 1
			return accept
		}
		func videoStreamDidStop() { stopped += 1 }
	}

	private func dump(_ tee: StreamCaptureTee, seconds: Double?, to url: URL) -> Result<StreamCaptureTee.CaptureResult, Error> {
		let done = DispatchSemaphore(value: 0)
		var outcome: Result<StreamCaptureTee.CaptureResult, Error> = .failure(ControlError("timeout"))
		tee.dump(lastSeconds: seconds, to: url) {
			outcome = $0
			done.signal()
		}
		_ = done.wait(timeout: .now() + 20)
		return outcome
	}

	private func stopCapture(_ tee: StreamCaptureTee) -> Result<StreamCaptureTee.CaptureResult, Error> {
		let done = DispatchSemaphore(value: 0)
		var outcome: Result<StreamCaptureTee.CaptureResult, Error> = .failure(ControlError("timeout"))
		tee.stopCapture {
			outcome = $0
			done.signal()
		}
		_ = done.wait(timeout: .now() + 20)
		return outcome
	}

	/// What a capture file holds, in the synthetic stream's terms.
	private struct Parsed {
		var header: StreamCaptureHeader
		var records: [StreamCaptureRecord]
		var notes: [String: Any]
		var firstIsStreamHeader: Bool
		var frames: [(index: Int, keyframe: Bool, intact: Bool)]
		var arrivalsOrdered: Bool
	}

	private func parse(_ url: URL) -> Parsed? {
		guard let (header, records) = try? StreamCaptureFile.read(from: url) else { return nil }
		let notes = (try? JSONSerialization.jsonObject(with: Data(header.notes.utf8)) as? [String: Any]) ?? [:]
		let headerBytes = Data(SyntheticStream.makeHeader())
		var ordered = true
		for i in 1..<max(records.count, 1) where records[i].arrivalNanoseconds < records[i - 1].arrivalNanoseconds { ordered = false }
		return Parsed(
			header: header, records: records, notes: notes,
			firstIsStreamHeader: records.first?.data == headerBytes,
			frames: records.compactMap { SyntheticStream.inspectFrame($0.data) }, arrivalsOrdered: ordered)
	}

	private func testFlightRecorder() {
		begin("Flight recorder")
		let dir = directory("flight")
		let source = SyntheticStream(bytesPerFrame: 20_000)
		let sink = CountingSink()
		let tee = StreamCaptureTee(limits: .init(seconds: 60, bytes: 64 << 20))
		tee.downstream = sink
		tee.keyframeRequester = source
		tee.notesProvider = { ["settings": ["stream.upscaler": 3], "build": "selftest"] }
		source.sink = tee

		// 1. A short session: everything is in the window.
		tee.videoStreamWillStart(profile: source.profile)
		source.sendHeader()
		for i in 0..<120 {
			source.sendFrame(framesLost: i == 50 ? 3 : 0, recovered: i == 51)
			usleep(500)
		}
		expect(sink.started == 1 && sink.frames == 121, "every buffer reaches the pipeline (header + 120 frames)", "\(sink.frames)")
		sink.accept = false
		let header = SyntheticStream.makeHeader()
		let verdict = header.withUnsafeBytes { tee.videoStreamDidReceive(accessUnit: $0, framesLost: 0, frameRecovered: false) }
		sink.accept = true
		expect(verdict == false, "the pipeline's verdict on a buffer is passed back to the session")
		let status = tee.status
		expect(status["bufferedRecords"] as? Int == 122 && status["bufferedKeyframes"] as? Int == 1 && status["hasStreamHeader"] as? Bool == true, "status counts what is buffered", "\(status)")

		let first = dir.appendingPathComponent("first.pscap")
		switch dump(tee, seconds: nil, to: first) {
		case .failure(let error):
			expect(false, "dump of the whole window", "\(error)")
		case .success(let result):
			expect(result.startsWithKeyframe && result.hasStreamHeader && result.warnings.isEmpty, "dump reports: starts with header and keyframe, no warnings")
			if let parsed = parse(first) {
				expect(parsed.firstIsStreamHeader, "first record is the stream header")
				expect(parsed.frames.first?.keyframe == true && parsed.frames.first?.index == 0, "second record is the keyframe")
				expect(parsed.frames.map(\.index) == Array(0..<120) && parsed.frames.allSatisfy(\.intact), "all 120 frames follow in order, byte for byte")
				expect(parsed.records[0].arrivalNanoseconds == 0 && parsed.records[1].arrivalNanoseconds == 0 && parsed.arrivalsOrdered, "arrival times start at 0 with the first frame and never go back")
				let span = Double(parsed.records.last!.arrivalNanoseconds) / 1e9
				expect(span > 0.05 && span < 1.0 && abs(span - result.durationSeconds) < 0.002, "arrival times are the real ones (\(String(format: "%.3f", span)) s for 120 frames sent 0.5 ms apart plus send time)")
				expect(parsed.records[51].framesLost == 3 && parsed.records[52].frameRecovered && !parsed.records[51].frameRecovered, "framesLost and frameRecovered are kept per record")
				expect(parsed.header.profile == source.profile, "header carries the stream profile")
				expect((parsed.notes["settings"] as? [String: Any])?["stream.upscaler"] as? Int == 3 && parsed.notes["startsWithKeyframe"] as? Bool == true && parsed.notes["build"] as? String == "selftest", "header notes carry the settings in force", parsed.header.notes)
				expect(abs(parsed.header.startedAt.timeIntervalSinceNow) < 5, "startedAt is the wall-clock time of the first frame")
				expect(result.records == parsed.records.count && result.bytes == Int64((try? Data(contentsOf: first))?.count ?? 0), "the reported record and byte counts match the file")
			} else {
				expect(false, "the dump is a readable PSCAP1 file")
			}
		}

		// 2. Asking for the last moments still starts at the keyframe they depend on.
		let tail = dir.appendingPathComponent("tail.pscap")
		if case .success(let result) = dump(tee, seconds: 0.01, to: tail), let parsed = parse(tail) {
			expect(result.startsWithKeyframe && parsed.frames.first?.index == 0, "a short request reaches back to the keyframe it needs")
		} else {
			expect(false, "dump of the last 10 ms")
		}
		tee.videoStreamDidStop()
		expect(sink.stopped == 1, "the end of the session is forwarded")
		let afterStop = dir.appendingPathComponent("after-stop.pscap")
		if case .success(let result) = dump(tee, seconds: nil, to: afterStop) {
			expect(result.records == 122, "the window can still be written after the session has ended")
		} else {
			expect(false, "dump after the session ended")
		}

		// 3. The keyframe has left the window: say so, ask for one, and the next capture has it.
		let small = StreamCaptureTee(limits: .init(seconds: 0.15, bytes: 16 << 20))
		let big = SyntheticStream(bytesPerFrame: 64 * 1024)
		small.downstream = sink
		small.keyframeRequester = big
		big.sink = small
		small.videoStreamWillStart(profile: big.profile)
		big.sendHeader()
		big.pump(rate: 500, seconds: 0.6) // 32 MB/s: a 2 MiB slab every 62 ms
		let sentBefore = big.framesSent
		let buffered = small.status["bufferedSeconds"] as? Double ?? 0
		expect(buffered > 0.1 && buffered < 0.3, "the window is bounded in time (\(buffered) s kept of 0.6 s sent, limit 0.15 s plus one slab)")
		expect(small.status["bufferedKeyframes"] as? Int == 0, "the session's only keyframe has left the window")
		let requestsBefore = big.keyframeRequests
		let noKey = dir.appendingPathComponent("no-keyframe.pscap")
		if case .success(let result) = dump(small, seconds: nil, to: noKey), let parsed = parse(noKey) {
			expect(!result.startsWithKeyframe && !result.warnings.isEmpty, "the result says the capture does not start with a keyframe")
			expect(parsed.notes["startsWithKeyframe"] as? Bool == false && ((parsed.notes["warnings"] as? [String])?.first ?? "").contains("does not start with a keyframe"), "and so do the header notes", parsed.header.notes)
			expect(parsed.firstIsStreamHeader && parsed.frames.first?.keyframe == false, "the stream header is still first (it is kept for the whole session)")
			expect(big.keyframeRequests == requestsBefore + 1, "a keyframe was requested")
		} else {
			expect(false, "dump without a keyframe in the window")
		}
		big.pump(rate: 500, frames: 40)
		let withKey = dir.appendingPathComponent("with-keyframe.pscap")
		if case .success(let result) = dump(small, seconds: nil, to: withKey), let parsed = parse(withKey) {
			expect(result.startsWithKeyframe && parsed.frames.first?.keyframe == true && parsed.frames.first?.index == sentBefore, "the next capture starts with that keyframe", "first frame \(parsed.frames.first?.index ?? -1), keyframe was frame \(sentBefore)")
			expect(parsed.frames.count == 40 && parsed.frames.allSatisfy(\.intact), "and holds exactly the frames from it on")
		} else {
			expect(false, "dump after the requested keyframe")
		}

		// 4. Bounded by bytes.
		let bounded = StreamCaptureTee(limits: .init(seconds: 600, bytes: 8 << 20))
		bounded.downstream = nil
		big.sink = bounded
		bounded.videoStreamWillStart(profile: big.profile)
		for _ in 0..<700 { big.sendFrame() } // ~45 MB
		let memory = bounded.status["memoryBytes"] as? Int ?? 0
		let held = bounded.status["bufferedBytes"] as? Int ?? 0
		expect(memory <= (8 << 20) + (1 << 20) && held > (5 << 20), "memory stays within the byte limit (\(memory >> 20) MiB held for a 8 MiB limit after 45 MiB of stream)")
		bounded.limits = .off
		expect(bounded.status["memoryBytes"] as? Int == 0, "turning the recorder off releases the memory at once")
		if case .failure(let error) = dump(bounded, seconds: nil, to: dir.appendingPathComponent("off.pscap")) {
			expect("\(error)".contains("off"), "and a dump then explains that it is off", "\(error)")
		} else {
			expect(false, "dump with the recorder off fails")
		}

		// 5. Explicit capture to disk: starts with the keyframe it asked for.
		let live = StreamCaptureTee(limits: .init(seconds: 60, bytes: 64 << 20))
		let stream = SyntheticStream(bytesPerFrame: 20_000)
		live.downstream = sink
		live.keyframeRequester = stream
		live.notesProvider = { ["settings": ["stream.fps": 60]] }
		stream.sink = live
		let explicit = dir.appendingPathComponent("explicit.pscap")
		expect((try? live.startCapture(to: explicit)) == nil, "a capture cannot start without a stream")
		live.videoStreamWillStart(profile: stream.profile)
		stream.sendHeader()
		for _ in 0..<30 { stream.sendFrame() }
		let requests = stream.keyframeRequests
		do {
			try live.startCapture(to: explicit)
			expect(stream.keyframeRequests == requests + 1, "starting a capture requests a keyframe")
			expect((try? live.startCapture(to: explicit)) == nil, "a second capture cannot start while one runs")
			for _ in 0..<50 {
				stream.sendFrame()
				usleep(300)
			}
			if case .success(let result) = stopCapture(live), let parsed = parse(explicit) {
				expect(result.startsWithKeyframe && parsed.firstIsStreamHeader && parsed.frames.first?.keyframe == true && parsed.frames.first?.index == 30, "the file starts with the stream header and the requested keyframe")
				expect(parsed.frames.map(\.index) == Array(30..<80) && parsed.frames.allSatisfy(\.intact) && parsed.arrivalsOrdered, "and holds every frame from then to the stop, in order")
				expect(parsed.notes["kind"] as? String == "explicit capture" && (parsed.notes["settings"] as? [String: Any])?["stream.fps"] as? Int == 60, "with the settings in its notes")
				expect(result.records == 51 && !live.isCapturing, "the stop reports the record count")
			} else {
				expect(false, "explicit capture file")
			}
		} catch {
			expect(false, "explicit capture starts", "\(error)")
		}

		// 6. No keyframe ever arrives: start anyway after the wait, and say so.
		live.keyframeRequester = nil
		live.keyframeWaitSeconds = 0.1
		let late = dir.appendingPathComponent("late.pscap")
		try? live.startCapture(to: late)
		let waitBegan = Date()
		while Date().timeIntervalSince(waitBegan) < 0.3 {
			stream.sendFrame()
			usleep(2000)
		}
		if case .success(let result) = stopCapture(live), let parsed = parse(late) {
			expect(!result.startsWithKeyframe && parsed.notes["startsWithKeyframe"] as? Bool == false && !result.warnings.isEmpty, "without a keyframe the capture starts after the wait and says it has none")
			expect(parsed.frames.first?.index == 80 && parsed.frames.allSatisfy(\.intact), "nothing that arrived while waiting is lost")
		} else {
			expect(false, "capture without keyframe")
		}
		live.keyframeRequester = stream
		live.keyframeWaitSeconds = 2

		// 7. A capture with a duration ends by itself; one cut off by the end of the session is closed.
		let timed = dir.appendingPathComponent("timed.pscap")
		try? live.startCapture(to: timed, maxSeconds: 0.15)
		let timedBegan = Date()
		while Date().timeIntervalSince(timedBegan) < 0.4 {
			stream.sendFrame()
			usleep(1000)
		}
		expect(!live.isCapturing, "a capture with a duration ends by itself")
		let lastDone = DispatchSemaphore(value: 0)
		var last: Result<StreamCaptureTee.CaptureResult, Error>?
		live.lastCaptureResult {
			last = $0
			lastDone.signal()
		}
		_ = lastDone.wait(timeout: .now() + 5)
		if case .success(let result)? = last, let parsed = parse(timed) {
			expect(result.durationSeconds > 0.1 && result.durationSeconds < 0.25 && parsed.frames.first?.keyframe == true, "its file covers the requested time (\(result.durationSeconds) s for 0.15 s)")
		} else {
			expect(false, "timed capture result")
		}
		let cut = dir.appendingPathComponent("cut.pscap")
		try? live.startCapture(to: cut)
		for _ in 0..<10 { stream.sendFrame() }
		live.videoStreamDidStop()
		let cutDone = DispatchSemaphore(value: 0)
		live.lastCaptureResult { _ in cutDone.signal() }
		_ = cutDone.wait(timeout: .now() + 5)
		expect(!live.isCapturing && parse(cut)?.frames.count == 10, "a capture is closed properly when the session ends")

		// 8. Keeping a keyframe in the window on request.
		let armed = StreamCaptureTee(limits: .init(seconds: 60, bytes: 64 << 20))
		let periodic = SyntheticStream(bytesPerFrame: 4000)
		armed.keyframeRequester = periodic
		armed.keyframeIntervalSeconds = 0.5
		periodic.sink = armed
		armed.videoStreamWillStart(profile: periodic.profile)
		periodic.sendHeader()
		periodic.pump(rate: 250, seconds: 1.8)
		let keyframes = armed.status["keyframesSeen"] as? Int ?? 0
		expect(keyframes == 4, "with a keyframe interval set, one is requested whenever none arrived for that long (\(keyframes) keyframes in 1.8 s at 0.5 s)")
		armed.keyframeIntervalSeconds = 0
		let stable = periodic.keyframeRequests
		periodic.pump(rate: 250, seconds: 0.8)
		expect(periodic.keyframeRequests == stable, "and never by default (interval 0)")

		// 9. Dumps, captures and setting changes while the stream thread runs flat out.
		let busy = StreamCaptureTee(limits: .init(seconds: 0.5, bytes: 8 << 20))
		let fast = SyntheticStream(fps: 1000, bytesPerFrame: 8000)
		busy.downstream = sink
		busy.keyframeRequester = fast
		fast.sink = busy
		fast.start()
		var valid = 0
		var attempted = 0
		let group = DispatchGroup()
		let countLock = NSLock()
		for i in 0..<24 {
			group.enter()
			DispatchQueue.global().asyncAfter(deadline: .now() + Double(i) * 0.04) { [self] in
				let url = dir.appendingPathComponent("stress-\(i).pscap")
				if i % 6 == 3 { busy.limits = .init(seconds: 0.3 + Double(i) * 0.01, bytes: (6 + i % 4) << 20) }
				let outcome = dump(busy, seconds: i % 2 == 0 ? 0.2 : nil, to: url)
				countLock.lock()
				attempted += 1
				if case .success = outcome, let parsed = parse(url), parsed.frames.allSatisfy(\.intact), parsed.arrivalsOrdered,
				   zip(parsed.frames, parsed.frames.dropFirst()).allSatisfy({ $1.index == $0.index + 1 }) {
					valid += 1
				}
				countLock.unlock()
				group.leave()
			}
		}
		let stressCapture = dir.appendingPathComponent("stress-capture.pscap")
		usleep(200_000)
		try? busy.startCapture(to: stressCapture)
		_ = group.wait(timeout: .now() + 30)
		let stressResult = stopCapture(busy)
		fast.stop()
		expect(attempted == 24 && valid == 24, "24 dumps taken while a 1000 fps stream is running and limits change are all complete and gap-free (\(valid)/\(attempted))")
		if case .success(let result) = stressResult, let parsed = parse(stressCapture) {
			expect(result.startsWithKeyframe && parsed.frames.allSatisfy(\.intact) && zip(parsed.frames, parsed.frames.dropFirst()).allSatisfy { $1.index == $0.index + 1 },
			       "and so is a disk capture running through it (\(parsed.frames.count) frames)")
		} else {
			expect(false, "disk capture under load", "\(stressResult)")
		}
	}

	private func testFlightRecorderCost() {
		begin("Flight recorder cost on the stream thread")
		let sink = CountingSink()
		let frame = SyntheticStream.makeFrame(index: 7, keyframe: false, size: 62_500) // 30 Mbit/s at 60 fps
		func measure(_ target: VideoStreamSink, count: Int) -> (averageMicros: Double, worstMicros: Double) {
			var worst: UInt64 = 0
			var total: UInt64 = 0
			frame.withUnsafeBytes { bytes in
				for _ in 0..<count {
					let start = DispatchTime.now().uptimeNanoseconds
					_ = target.videoStreamDidReceive(accessUnit: bytes, framesLost: 0, frameRecovered: false)
					let elapsed = DispatchTime.now().uptimeNanoseconds - start
					total += elapsed
					worst = max(worst, elapsed)
				}
			}
			return (Double(total) / Double(count) / 1000, Double(worst) / 1000)
		}
		let tee = StreamCaptureTee(limits: .init(seconds: 60, bytes: 256 << 20))
		tee.downstream = sink
		tee.videoStreamWillStart(profile: .ps5Max)
		_ = measure(tee, count: 500) // warm up
		let direct = measure(sink, count: 20_000)
		let recorded = measure(tee, count: 20_000) // 1.25 GB through a 256 MiB window
		let off = StreamCaptureTee(limits: .off)
		off.downstream = sink
		off.videoStreamWillStart(profile: .ps5Max)
		let disabled = measure(off, count: 20_000)
		info(String(format: "62.5 KB frames: direct to sink %.2f us, through recorder %.2f us (worst %.0f us), recorder off %.2f us", direct.averageMicros, recorded.averageMicros, recorded.worstMicros, disabled.averageMicros))
		expect(recorded.averageMicros - direct.averageMicros < 50, "recording adds less than 50 us per 62.5 KB frame on average (\(String(format: "%.1f", recorded.averageMicros - direct.averageMicros)) us; a 60 fps frame lasts 16667 us)")
		expect(recorded.worstMicros < 5000, "the worst single frame stays far below a frame time (\(String(format: "%.0f", recorded.worstMicros)) us)")
		expect(disabled.averageMicros - direct.averageMicros < 2, "turned off it costs next to nothing (\(String(format: "%.2f", disabled.averageMicros - direct.averageMicros)) us)")
	}

	// MARK: - Control channel end to end

	private func testControlChannel() {
		begin("Control channel (server, router, synthetic session)")
		let root = directory("host")
		var options = HeadlessHost.Options()
		options.fps = 120
		options.bitrateMbps = 8
		options.busySeconds = 1.2
		guard let host = try? HeadlessHost(root: root, options: options) else {
			expect(false, "headless host starts")
			return
		}
		host.removeDefaults()
		defer {
			host.shutdown()
			host.removeDefaults()
		}
		do { try host.start() } catch {
			expect(false, "control server starts", "\(error)")
			return
		}
		let socket = host.socketURL

		func call(_ command: String, _ args: [String] = [], _ opts: [String: Any] = [:], timeout: TimeInterval = 30) -> [String: Any] {
			(try? ControlClient.send(ControlRequest(command: command, args: args, options: opts), to: socket, timeout: timeout)) ?? ["ok": false, "error": "no response"]
		}
		func result(_ response: [String: Any]) -> [String: Any] { response["result"] as? [String: Any] ?? [:] }
		func ok(_ response: [String: Any]) -> Bool { response["ok"] as? Bool == true }
		func error(_ response: [String: Any]) -> String { response["error"] as? String ?? "" }

		var info = stat()
		expect(stat(socket.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK && (info.st_mode & 0o777) == 0o600, "the socket exists and only its owner can open it (mode 0600)", String(info.st_mode & 0o777, radix: 8))
		expect(result(call("ping"))["pong"] as? Bool == true, "ping")
		usleep(600_000) // let the session come up and deliver some frames

		let status = result(call("status"))
		let session = status["session"] as? [String: Any] ?? [:]
		expect(session["running"] as? Bool == true && session["phase"] as? String == "streaming" && (session["console"] as? [String: Any])?["name"] as? String == "Synthetic PS5", "status: session, phase and console")
		expect((session["profile"] as? [String: Any])?["width"] as? Int == 1920 && session["renderer"] as? String == "fake" && (status["uptimeSeconds"] as? Double ?? 0) > 0, "status: profile, renderer and uptime")
		expect((status["app"] as? [String: Any])?["gitCommit"] != nil && status["pid"] as? Int == Int(getpid()) && status["debugStorage"] != nil, "status: build identity, pid and debug directory usage")

		let stats = result(call("stats"))
		let video = stats["video"] as? [String: Any] ?? [:]
		expect((video["framesReceived"] as? Int ?? 0) > 20 && video["optionalNumber"] is NSNull && video["mode"] as? String == "steady" && (video["recentArrivalIntervalsMs"] as? [Any])?.isEmpty == false, "stats: every field of the pipeline's stats structure, by reflection")
		expect((stats["flightRecorder"] as? [String: Any])?["enabled"] as? Bool == true && stats["recorder"] != nil && stats["session"] != nil, "stats: flight recorder, recorder and session sections")

		// Settings
		let all = result(call("settings", ["get"]))["settings"] as? [[String: Any]] ?? []
		expect(all.count == SettingsCatalog.all.count, "settings get lists every setting (\(all.count))")
		expect(result(call("settings", ["get", "bitrate"]))["key"] as? String == nil && result(call("settings", ["get", "bitrateMbps"]))["key"] as? String == "stream.bitrateMbps", "settings get <key> accepts the short name")
		let live = result(call("settings", ["set", "stream.upscaler", "fsr1"]))
		let change = (live["changes"] as? [[String: Any]])?.first ?? [:]
		expect(change["new"] as? Int == 3 && change["note"] as? String == "applied now" && host.defaults.integer(forKey: "stream.upscaler") == 3, "settings set of a live setting: stored, and reported as applied now", "\(live)")
		expect(host.appliedSettings.last == ["stream.upscaler"] && (live["appliedLive"] as? [String])?.isEmpty == false, "the host is told to apply it")
		let next = result(call("settings", ["set", "stream.bitrateMbps", "40"]))
		expect(((next["changes"] as? [[String: Any]])?.first?["note"] as? String ?? "").contains("next connection"), "settings set of a connection setting says it waits for the next connection")
		let bad = call("settings", ["set", "stream.upscalerSharpness", "0.8", "stream.fps", "45"])
		expect(!ok(bad) && error(bad).contains("stream.fps") && host.defaults.object(forKey: "stream.upscalerSharpness") == nil, "an invalid value fails the whole request and changes nothing", error(bad))
		_ = call("settings", ["set", "debug.flightRecorderSeconds", "5", "debug.flightRecorderMegabytes", "32"])
		expect(host.tee.limits == StreamCaptureTee.Limits(seconds: 5, bytes: 32 << 20), "flight recorder limits follow their settings live")
		_ = call("settings", ["set", "debug.flightRecorderSeconds", "default", "debug.flightRecorderMegabytes", "default"])
		expect(host.tee.limits == StreamCaptureTee.Limits(), "and return to the defaults with \"default\"")

		// Tunables
		let tunables = result(call("tunables"))["tunables"] as? [String: Any] ?? [:]
		expect(tunables["pacer.marginMs"] as? Double == 4, "tunables are listed")
		let tuned = result(call("tune", ["pacer.marginMs", "6.5"]))
		expect(tuned["value"] as? Double == 6.5 && tuned["previous"] as? Double == 4 && host.pipeline.debugTunables()["pacer.marginMs"] == 6.5, "tune changes one and reports old and new value")
		expect(error(call("tune", ["pacer.marginMs", "5000"])).contains("outside the accepted range"), "tune: a value out of range is refused with a reason")
		expect(error(call("tune", ["pacer", "1"])).contains("pacer.marginMs"), "tune: an unknown name suggests the close ones")

		// Trace, frames, capture
		let trace = result(call("trace", ["0.3"]))
		let tracePath = trace["path"] as? String ?? ""
		let traceLines = ((try? String(contentsOfFile: tracePath, encoding: .utf8)) ?? "").split(separator: "\n")
		expect(tracePath.hasPrefix(root.path + "/debug/traces/") && (trace["records"] as? Int ?? 0) > 10 && traceLines.count == trace["records"] as? Int, "trace writes a JSON Lines file under debug/traces and returns its path (\(traceLines.count) records)")
		let frames = result(call("frames", ["3"]))
		let files = frames["files"] as? [String] ?? []
		expect(files.count == 3 && files.allSatisfy { FileManager.default.fileExists(atPath: $0) && $0.hasPrefix(root.path + "/debug/frames/") }, "frames returns the picture files once they are written")

		let capture = result(call("capture", ["0.3"]))
		let capturePath = capture["path"] as? String ?? ""
		if let parsed = parse(URL(fileURLWithPath: capturePath)) {
			expect(capturePath.hasPrefix(root.path + "/debug/captures/flight-") && capture["startsWithKeyframe"] as? Bool == true && parsed.firstIsStreamHeader && parsed.frames.first?.keyframe == true, "capture writes a PSCAP1 file starting with header and keyframe and returns its path")
			expect((parsed.notes["settings"] as? [String: Any])?["stream.bitrateMbps"] as? Double == 40, "its notes hold the settings in force (bitrate 40 set above)")
		} else {
			expect(false, "capture returns a readable PSCAP1 file", "\(capture)")
		}
		let started = result(call("capture", ["start"]))
		expect(started["state"] as? String == "capturing" && (result(call("capture", ["status"]))["capture"] as? [String: Any])?["path"] as? String == started["path"] as? String, "capture start begins a disk capture, visible in capture status")
		usleep(300_000)
		let stopped = result(call("capture", ["stop"]))
		if let path = stopped["path"] as? String, let parsed = parse(URL(fileURLWithPath: path)) {
			expect(stopped["startsWithKeyframe"] as? Bool == true && parsed.frames.count > 15 && parsed.frames.allSatisfy(\.intact), "capture stop returns the finished file (\(parsed.frames.count) frames)")
		} else {
			expect(false, "capture stop returns the file", "\(stopped)")
		}
		let again = result(call("capture", ["stop"]))
		expect(again["path"] as? String == stopped["path"] as? String && (again["note"] as? String ?? "").contains("no capture was running"), "capture stop with nothing running reports the last finished file and says so")
		expect(error(call("capture", ["sideways"])).contains("usage"), "capture with a bad argument explains the usage")

		// Log
		let marked = result(call("mark", ["hello", "from", "selftest"]))
		expect(marked["logged"] as? String == "MARK: hello from selftest", "mark writes a line")
		let lines = result(call("log", ["400"]))["lines"] as? [String] ?? []
		expect(lines.contains { $0.hasSuffix("MARK: hello from selftest") } && lines.contains { $0.contains("Tunable pacer.marginMs = 6.5") } && lines.contains { $0.contains("Setting stream.upscaler = 3") }, "log returns the recent lines, including the mark and the changes made above")
		let filtered = result(call("log", ["50"], ["grep": "mark:"]))["lines"] as? [String] ?? []
		expect(filtered.count == 1, "log with grep returns only matching lines", "\(filtered.count)")

		// Recorder, disconnect, reconnect
		expect(result(call("record", ["start"]))["state"] as? String == "recording" && result(call("record", ["stop"]))["state"] as? String == "idle", "record start and stop reach the recorder")
		expect(ok(call("disconnect")) && result(call("status"))["session"].flatMap { ($0 as? [String: Any])?["running"] as? Bool } == false, "disconnect ends the session")
		expect(error(call("tunables")) == "no session is running" && error(call("disconnect")) == "no session is running", "commands that need a session say so when there is none")
		expect(ok(call("reconnect")), "reconnect is accepted")
		usleep(700_000)
		expect((result(call("status"))["session"] as? [String: Any])?["running"] as? Bool == true, "and the session is back")

		// Relaunch
		let bundle = root.appendingPathComponent("Fake.app")
		makeBundle(bundle, identifier: "dev.playstream.PlayStream")
		let refused = call("relaunch", [root.appendingPathComponent("Nope.app").path])
		expect(!ok(refused) && error(refused).contains("no app bundle") && host.sessionRunning, "relaunch with a wrong path is refused and the session keeps running", error(refused))
		let parsedRequest = try? ControlRouter.relaunchRequest(from: ControlRequest(command: "relaunch", args: ["~/x.app"], options: ["whenidle": true, "idleseconds": 3, "timeout": "120", "ontimeout": "relaunch"]))
		expect(parsedRequest?.whenIdle == true && parsedRequest?.idleSeconds == 3 && parsedRequest?.timeoutSeconds == 120 && parsedRequest?.relaunchOnTimeout == true && parsedRequest?.bundlePath?.hasPrefix("/") == true, "relaunch options are parsed (bundle, when idle, idle seconds, timeout, on timeout)")
		expect(result(call("simulate", ["input", "1.5"]))["simulating"] != nil, "(test host) the fake player starts pressing buttons for 1.5 s")
		usleep(150_000)
		let scheduled = result(call("relaunch", [bundle.path], ["when-idle": true, "idle-seconds": 0.5, "timeout": 20]))
		expect(scheduled["waitingForIdle"] as? Bool == true, "relaunch --when-idle is scheduled while the player is busy")
		expect(!(result(call("status"))["pendingRelaunch"] is NSNull) && host.sessionRunning, "it shows as pending in status and the session keeps running meanwhile")
		expect(error(call("relaunch", [bundle.path])).contains("already waiting"), "a second relaunch is refused while one is waiting")
		var waited = 0.0
		while waited < 6, result(call("status"))["lastRelaunch"] is NSNull {
			usleep(200_000)
			waited += 0.2
		}
		let lastRelaunch = result(call("status"))["lastRelaunch"] as? [String: Any] ?? [:]
		expect(lastRelaunch["outcome"] as? String == "dry run" && lastRelaunch["wouldResume"] as? Bool == true && lastRelaunch["bundle"] as? String == bundle.path, "it goes ahead once the controller has been idle (dry run in the test host)", "\(lastRelaunch) after \(waited) s")
		let relaunchLog = result(call("log", ["100"], ["grep": "Relaunch"]))["lines"] as? [String] ?? []
		expect(relaunchLog.contains { $0.contains("controller idle after") }, "the log shows how long it waited", relaunchLog.joined(separator: " / "))
		usleep(600_000)
		_ = call("relaunch", [bundle.path], ["idle-seconds": 100, "timeout": 100])
		expect(ok(call("relaunch", ["cancel"])) && result(call("status"))["pendingRelaunch"] is NSNull, "a waiting relaunch can be cancelled")

		// Errors and abuse
		expect(error(call("frobnicate")).contains("unknown command"), "an unknown command is an error, not a crash")
		let commands = result(call("help"))["commands"] as? [[String: Any]] ?? []
		expect(commands.count == ControlRouter.commands.count, "help lists the commands")
		expect(rawExchange(socket, send: Data("this is {not json\n".utf8)).contains("\"ok\":false") || rawExchange(socket, send: Data("{broken\n".utf8)).contains("\"ok\":false"), "a malformed request gets an error response")
		expect(rawExchange(socket, send: Data("ping\n".utf8)).contains("\"pong\":true"), "a bare text command works (usable with nc -U)")
		_ = rawExchange(socket, send: Data(), closeImmediately: true)
		let huge = rawExchange(socket, send: Data(repeating: 0x41, count: (1 << 20) + 70_000))
		expect(huge.contains("too large") || huge.isEmpty, "an oversized request is cut off")
		// A client that leaves before its answer arrives must not hurt the server (no SIGPIPE).
		_ = rawExchange(socket, send: Data(#"{"cmd":"frames","args":["2"]}"#.utf8 + [0x0A]), closeImmediately: true)
		usleep(300_000)
		expect(result(call("ping"))["pong"] as? Bool == true, "the server survives empty, oversized and abandoned connections")

		let group = DispatchGroup()
		let lock = NSLock()
		var good = 0
		for i in 0..<12 {
			group.enter()
			DispatchQueue.global().async {
				let response = call(i % 2 == 0 ? "stats" : "status")
				lock.lock()
				if ok(response) { good += 1 }
				lock.unlock()
				group.leave()
			}
		}
		_ = group.wait(timeout: .now() + 20)
		expect(good == 12, "12 simultaneous requests are all answered (\(good))")

		// Turning the channel off, restart, takeover
		expect(ok(call("settings", ["set", "debug.controlChannel", "off"])), "the channel can be turned off through itself (the answer still arrives)")
		usleep(700_000)
		expect(!FileManager.default.fileExists(atPath: socket.path) && !host.server.isRunning, "then the socket is gone")
		host.defaults.removeObject(forKey: "debug.controlChannel")
		expect((try? host.server.start()) != nil && result(call("ping"))["pong"] as? Bool == true, "the server can be started again")
		let takeover = ControlServer(socketURL: socket) { _ in .success(["second": true]) }
		expect((try? takeover.start()) != nil && result(call("ping"))["second"] as? Bool == true, "a newer instance takes the socket over")
		host.server.stop()
		expect(FileManager.default.fileExists(atPath: socket.path) && result(call("ping"))["second"] as? Bool == true, "stopping the older instance leaves the newer one's socket alone")
		takeover.stop()
		expect(!FileManager.default.fileExists(atPath: socket.path), "and the socket file is removed when its owner stops")
	}

	/// Sends raw bytes to the socket and returns whatever comes back.
	private func rawExchange(_ socketURL: URL, send payload: Data, closeImmediately: Bool = false) -> String {
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		guard fd >= 0 else { return "" }
		defer { close(fd) }
		var on: Int32 = 1
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
		var tv = timeval(tv_sec: 8, tv_usec: 0)
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketURL.path.utf8) }
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
		}
		guard connected == 0 else { return "" }
		payload.withUnsafeBytes { raw in
			var offset = 0
			while offset < raw.count {
				let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
				if n <= 0 { break }
				offset += n
			}
		}
		if closeImmediately { return "" }
		shutdown(fd, SHUT_WR)
		var out = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while true {
			let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
			if n <= 0 { break }
			out.append(contentsOf: buffer[0..<n])
		}
		return String(decoding: out, as: UTF8.self)
	}
}
