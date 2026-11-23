import Foundation

// No-click restart: what the app remembers about the running session so the next launch can
// pick it up again, and the rules for when it should and should not.

/// The session to return to. Written while a session is streaming, kept across a quit or a
/// relaunch, removed when the session is ended on purpose.
public struct ResumeRecord: Codable, Equatable, Sendable {
	public enum Reason: String, Codable, Sendable {
		/// A session was streaming and the app never said goodbye (crash, force quit, kill).
		case streaming
		/// The app was quit while the session was streaming.
		case quit
		/// The app was told to relaunch (a new build is being swapped in).
		case relaunch
	}

	public var hostID: String
	public var hostName: String
	public var reason: Reason
	/// Last time the record was confirmed (heartbeat while streaming, or the quit / relaunch).
	public var updatedAt: Date
	/// The stream window was in full screen.
	public var wasFullScreen: Bool
	/// When the old session was told to stop, if it was. The console needs a few seconds after
	/// that before it accepts a new session.
	public var sessionEndedAt: Date?
	/// Build that wrote the record (for the log only).
	public var build: String?

	public init(hostID: String, hostName: String, reason: Reason, updatedAt: Date = Date(), wasFullScreen: Bool, sessionEndedAt: Date? = nil, build: String? = nil) {
		self.hostID = hostID
		self.hostName = hostName
		self.reason = reason
		self.updatedAt = updatedAt
		self.wasFullScreen = wasFullScreen
		self.sessionEndedAt = sessionEndedAt
		self.build = build
	}
}

/// Keeps the resume record in a small JSON file. Tiny synchronous file I/O.
public final class ResumeStore: @unchecked Sendable {
	public let fileURL: URL
	private let lock = NSLock()

	public static var defaultURL: URL {
		let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
			?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
		return base.appendingPathComponent("PlayStream/resume.json")
	}

	public init(fileURL: URL = ResumeStore.defaultURL) {
		self.fileURL = fileURL
	}

	public func load() -> ResumeRecord? {
		lock.lock()
		defer { lock.unlock() }
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return try? decoder.decode(ResumeRecord.self, from: data)
	}

	public func save(_ record: ResumeRecord) {
		lock.lock()
		defer { lock.unlock() }
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		encoder.outputFormatting = [.sortedKeys]
		guard let data = try? encoder.encode(record) else { return }
		try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
		try? data.write(to: fileURL, options: .atomic)
		try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
	}

	public func clear() {
		lock.lock()
		defer { lock.unlock() }
		try? FileManager.default.removeItem(at: fileURL)
	}
}

public enum ResumePolicy {
	public enum Decision: Equatable, Sendable {
		/// Reconnect to the record's console, after waiting `delay` seconds first.
		case resume(ResumeRecord, delay: TimeInterval)
		/// Stay on the home screen. `reason` goes into the log; `tellUser` says whether the
		/// owner should see it (something they expected did not happen).
		case skip(reason: String, tellUser: Bool)
	}

	/// The console needs this long after a session was stopped before it takes a new one. The
	/// log shows "Remote Play already in use" for reconnects within a second or two.
	public static let settleSeconds: TimeInterval = 3

	/// A session handed over by the relaunch command is resumed if the new instance comes up
	/// within this time, whatever the resume window setting says.
	public static let relaunchWindowSeconds: TimeInterval = 300

	/// Decides at launch whether to reconnect.
	///
	/// - Parameters:
	///   - record: what the previous run left behind, if anything.
	///   - enabled: the "reconnect at launch" setting (for sessions left by a quit or a crash).
	///   - windowSeconds: how old the record may be. A quit followed by a launch much later
	///     means the owner was done playing, not that the app was being restarted.
	///   - hasAccount: a PSN account is set up (a session cannot start without one).
	///   - hostIsRegistered: the console is still paired.
	///   - suppressed: the owner asked not to resume (Option held at launch).
	public static func decide(record: ResumeRecord?, enabled: Bool, now: Date = Date(), windowSeconds: TimeInterval, hasAccount: Bool, hostIsRegistered: Bool, suppressed: Bool = false) -> Decision {
		guard let record else { return .skip(reason: "no session to resume", tellUser: false) }
		guard !suppressed else { return .skip(reason: "Option was held at launch", tellUser: false) }
		// A relaunch asked for the session back in so many words. The setting and the window
		// are about what a plain quit or a crash should lead to ("restarting" versus "done for
		// today"); they do not turn the relaunch command's own promise off.
		let handedOver = record.reason == .relaunch
		guard enabled || handedOver else { return .skip(reason: "reconnect at launch is turned off", tellUser: false) }
		let age = now.timeIntervalSince(record.updatedAt)
		let window = handedOver ? max(windowSeconds, relaunchWindowSeconds) : windowSeconds
		guard age <= window else {
			return .skip(reason: "the last session (\(record.hostName)) ended \(Int(age)) s ago, longer than the \(Int(window)) s resume window", tellUser: false)
		}
		guard age > -60 else { return .skip(reason: "the saved session is dated in the future", tellUser: false) }
		guard hostIsRegistered else {
			return .skip(reason: "\(record.hostName) is no longer paired with this Mac", tellUser: true)
		}
		guard hasAccount else {
			return .skip(reason: "no PSN account is set up, so the session with \(record.hostName) cannot be resumed", tellUser: true)
		}
		var delay: TimeInterval = 0
		if let ended = record.sessionEndedAt {
			delay = min(settleSeconds, max(0, settleSeconds - now.timeIntervalSince(ended)))
		} else if record.reason == .streaming {
			// The previous run died without closing its session; the console may still hold it.
			delay = min(settleSeconds, max(0, settleSeconds - age))
		}
		return .resume(record, delay: delay)
	}
}

/// How to react when a new session is refused or dies right away.
public enum ReconnectPolicy {
	/// Waits between attempts while the console still reports the previous session, seconds.
	public static let busyBackoff: [TimeInterval] = [2, 3, 4, 6, 8, 10]

	/// The console refused the session because the previous one has not been released yet.
	/// Clears by itself within a few seconds.
	public static func isConsoleBusy(_ reason: String) -> Bool {
		// The core's text for this is "Remote Play on Console is already in use" (the console's
		// own wording, logged next to it, is "Remote is already in use"). An address that is
		// "already in use" on this Mac is a different problem and is not retried.
		let text = reason.lowercased()
		return text.contains("already in use") && text.contains("remote")
	}

	/// Seconds to wait before attempt number `attempt + 1` (attempts count from 1), or nil when
	/// it is time to give up.
	public static func delay(afterBusyAttempt attempt: Int) -> TimeInterval? {
		guard attempt >= 1, attempt <= busyBackoff.count else { return nil }
		return busyBackoff[attempt - 1]
	}
}
