import CPSBridge
import Foundation
import PSContracts

/// Everything needed to open one Remote Play session.
public struct SessionConfiguration: Sendable {
	public var host: RegisteredHost
	/// IP address or hostname to connect to.
	public var address: String
	public var account: PSNAccount
	public var profile: StreamProfile
	/// Ask for DualSense haptics and adaptive triggers (PS5 only).
	public var enableDualSense: Bool
	/// Packet loss ceiling reported to the console's congestion control (0...1).
	public var packetLossMax: Double
	/// On unrecoverable packet loss, freeze until a fresh keyframe arrives instead of letting the
	/// core carry on from an older reference frame. Cleaner picture, but every loss becomes a
	/// visible stall, so it is off by default (as in the reference client).
	public var requestKeyframeOnFECFailure: Bool
	/// Experimental. The handshake has a start-bitrate field the core normally leaves at zero.
	/// `.off` keeps that; the other two send the profile's bitrate in one of the two possible
	/// byte orders (which one the console expects is unknown, as is whether it has any effect).
	public var startBitrateHint: StartBitrateHint = .off

	public enum StartBitrateHint: Int, Sendable, CaseIterable {
		case off = 0
		case variantA = 1 // big endian
		case variantB = 2 // little endian
	}

	public init(host: RegisteredHost, address: String, account: PSNAccount, profile: StreamProfile = .ps5Max, enableDualSense: Bool = true, packetLossMax: Double = 0.05, requestKeyframeOnFECFailure: Bool = false) {
		self.host = host
		self.address = address
		self.account = account
		self.profile = profile
		self.enableDualSense = enableDualSense
		self.packetLossMax = packetLossMax
		self.requestKeyframeOnFECFailure = requestKeyframeOnFECFailure
	}
}

/// Things the UI needs to react to. Delivered on the main queue.
public enum SessionEvent: Sendable, Equatable {
	/// The stream is up; video and audio follow.
	case connected
	/// The console wants its login PIN. Answer with `StreamSession.setLoginPIN`.
	case loginPINRequested(incorrect: Bool)
	case nicknameReceived(String)
	/// The console is showing something it refuses to stream (e.g. protected video).
	case cantDisplay(Bool)
	case keyboardOpened
	case keyboardTextChanged(String)
	case keyboardClosed
	/// The session is over. No further callbacks follow.
	case ended(reason: String, isError: Bool)
}

public struct SessionStats: Sendable, Equatable {
	/// Video bitrate actually received, bit/s.
	public var measuredBitrate: Double = 0
	/// 0...1
	public var packetLoss: Double = 0
	public var rttMilliseconds: Double = 0
	public var mtuIn: Int = 0
	public var mtuOut: Int = 0
	/// Bitrate the console is currently aiming for, bit/s (0 until its first report). It starts
	/// near the requested ceiling and drops when loss is reported to it.
	public var consoleTargetBitrate: Double = 0
	/// Round trip and loss as the console itself measures them, updated live.
	public var consoleRTT: Double = 0
	public var consoleLoss: UInt64 = 0
	public var consoleReports: UInt64 = 0
	/// How often we reported a corrupt frame to the console, and asked it for a keyframe.
	public var corruptReportsSent: UInt64 = 0
	public var keyframeRequestsSent: UInt64 = 0
	public init() {}
}

public enum SessionError: Error, LocalizedError {
	case invalidConfiguration(String)
	case core(code: Int32, message: String)
	case alreadyStarted

	public var errorDescription: String? {
		switch self {
		case .invalidConfiguration(let why): return "Invalid session configuration: \(why)"
		case .core(_, let message): return "Remote Play core error: \(message)"
		case .alreadyStarted: return "The session was already started."
		}
	}
}

/// One Remote Play session. Create, set the sinks, `start()`, and `stop()` when done.
/// A session object is single-use.
public final class StreamSession: ControllerStateReceiver, KeyframeRequesting {
	public let configuration: SessionConfiguration

	// Set these before `start()`. They are read from the core's network threads afterwards.
	public var videoSink: VideoStreamSink?
	public var audioSink: AudioStreamSink?
	public var hapticsSink: HapticsStreamSink?
	public var feedbackSink: ControllerFeedbackSink?

	/// Called on the main queue.
	public var onEvent: ((SessionEvent) -> Void)?

	/// Called on a network thread whenever frames were lost before the one just delivered.
	/// Set before `start()`. Must return immediately.
	public var onVideoLoss: ((_ framesLost: Int) -> Void)?

	private var handle: OpaquePointer?
	private let lock = NSLock()
	private var audioChannels = 2
	private var ended = false

	public init(configuration: SessionConfiguration) {
		self.configuration = configuration
	}

	deinit {
		// `start()` retains self for the core; that retain is only dropped after the core is
		// torn down, so by the time we get here the handle is already gone.
		assert(handle == nil)
	}

	// MARK: Lifecycle

	public func start() throws {
		lock.lock()
		defer { lock.unlock() }
		guard handle == nil, !ended else { throw SessionError.alreadyStarted }

		let cfg = configuration
		guard cfg.host.registKey.count == 16 else { throw SessionError.invalidConfiguration("regist key must be 16 bytes") }
		guard cfg.host.rpKey.count == 16 else { throw SessionError.invalidConfiguration("rp key must be 16 bytes") }
		guard cfg.account.accountID.count == 8 else { throw SessionError.invalidConfiguration("PSN account id must be 8 bytes") }

		var config = PSSessionConfig()
		config.ps5 = cfg.host.isPS5
		withUnsafeMutableBytes(of: &config.regist_key) { $0.copyBytes(from: cfg.host.registKey) }
		withUnsafeMutableBytes(of: &config.rp_key) { $0.copyBytes(from: cfg.host.rpKey) }
		withUnsafeMutableBytes(of: &config.psn_account_id) { $0.copyBytes(from: cfg.account.accountID) }
		config.width = UInt32(cfg.profile.width)
		config.height = UInt32(cfg.profile.height)
		config.max_fps = UInt32(cfg.profile.fps)
		config.bitrate_kbps = UInt32(cfg.profile.bitrateKbps)
		config.codec = Int32(cfg.profile.codec.rawValue)
		config.enable_dualsense = cfg.enableDualSense
		config.enable_keyboard = false
		config.auto_downgrade = true
		config.packet_loss_max = cfg.packetLossMax
		config.enable_idr_on_fec_failure = cfg.requestKeyframeOnFECFailure
		if cfg.startBitrateHint != .off {
			config.start_bitrate_kbps = UInt32(cfg.profile.bitrateKbps)
			config.start_bitrate_little_endian = cfg.startBitrateHint == .variantB
		}

		// The core holds an unretained pointer to self; the matching retain is taken below once
		// creation succeeded and released in `teardown` after the core has stopped calling us.
		var callbacks = PSSessionCallbacks()
		callbacks.user = Unmanaged.passUnretained(self).toOpaque()
		callbacks.event = { event, user in
			guard let event, let user else { return }
			Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue().handle(event: event.pointee)
		}
		callbacks.video = { buf, size, framesLost, recovered, user in
			guard let buf, let user else { return true }
			let session = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			if framesLost > 0 { session.onVideoLoss?(Int(framesLost)) }
			guard let sink = session.videoSink else { return true }
			return sink.videoStreamDidReceive(accessUnit: UnsafeRawBufferPointer(start: buf, count: size), framesLost: Int(framesLost), frameRecovered: recovered)
		}
		callbacks.audio_config = { channels, rate, user in
			guard let user else { return }
			let session = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			session.audioChannels = Int(channels)
			session.audioSink?.audioStreamDidConfigure(channels: Int(channels), sampleRate: Int(rate))
		}
		callbacks.audio_frame = { pcm, samples, user in
			guard let pcm, let user else { return }
			let session = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			guard let sink = session.audioSink else { return }
			sink.audioStreamDidReceive(pcm: UnsafeBufferPointer(start: pcm, count: samples * session.audioChannels), frameCount: samples)
		}
		callbacks.haptics_frame = { pcm, samples, user in
			guard let pcm, let user else { return }
			let session = Unmanaged<StreamSession>.fromOpaque(user).takeUnretainedValue()
			session.hapticsSink?.hapticsStreamDidReceive(pcm: UnsafeBufferPointer(start: pcm, count: samples * 2), frameCount: samples)
		}

		var err: Int32 = 0
		let created: OpaquePointer? = cfg.address.withCString { host in
			config.host = host
			return ps_session_create(&config, &callbacks, &err)
		}
		guard let created else {
			throw SessionError.core(code: err, message: String(cString: ps_error_string(err)))
		}

		videoSink?.videoStreamWillStart(profile: cfg.profile)

		_ = Unmanaged.passRetained(self)
		handle = created
		let startErr = ps_session_start(created)
		if startErr != 0 {
			handle = nil
			ended = true
			ps_session_destroy(created)
			Unmanaged.passUnretained(self).release()
			videoSink?.videoStreamDidStop()
			throw SessionError.core(code: startErr, message: String(cString: ps_error_string(startErr)))
		}
	}

	/// Ends the session. The `.ended` event follows on the main queue. Safe to call repeatedly.
	public func stop() {
		withHandle { _ = ps_session_stop($0) }
	}

	/// Called once the core reported the session over. Joins and frees the core off the
	/// calling (core) thread, then tells the sinks and drops the retain taken in `start()`.
	private func teardown(reason: String, isError: Bool) {
		lock.lock()
		let h = handle
		let alreadyEnded = ended
		ended = true
		lock.unlock()
		guard let h, !alreadyEnded else { return }

		DispatchQueue.global(qos: .userInitiated).async {
			ps_session_destroy(h) // joins the session thread: no callbacks after this returns
			self.lock.lock()
			self.handle = nil
			self.lock.unlock()
			self.videoSink?.videoStreamDidStop()
			self.audioSink?.audioStreamDidStop()
			DispatchQueue.main.async {
				self.onEvent?(.ended(reason: reason, isError: isError))
				Unmanaged.passUnretained(self).release()
			}
		}
	}

	// MARK: Commands

	private func withHandle(_ body: (OpaquePointer) -> Void) {
		lock.lock()
		defer { lock.unlock() }
		guard let handle, !ended else { return }
		body(handle)
	}

	public func controllerStateDidChange(_ state: ControllerState) {
		var cs = PSControllerState()
		cs.buttons = state.buttons.rawValue
		cs.l2 = state.l2
		cs.r2 = state.r2
		cs.left_x = state.leftX
		cs.left_y = state.leftY
		cs.right_x = state.rightX
		cs.right_y = state.rightY
		cs.touch_id_next = state.touchIdNext
		cs.touch0.x = state.touch0.x
		cs.touch0.y = state.touch0.y
		cs.touch0.id = state.touch0.id
		cs.touch1.x = state.touch1.x
		cs.touch1.y = state.touch1.y
		cs.touch1.id = state.touch1.id
		cs.gyro_x = state.gyroX
		cs.gyro_y = state.gyroY
		cs.gyro_z = state.gyroZ
		cs.accel_x = state.accelX
		cs.accel_y = state.accelY
		cs.accel_z = state.accelZ
		cs.orient_x = state.orientX
		cs.orient_y = state.orientY
		cs.orient_z = state.orientZ
		cs.orient_w = state.orientW
		withHandle { _ = ps_session_set_controller_state($0, &cs) }
	}

	public func requestKeyframe() {
		withHandle { _ = ps_session_request_idr($0) }
	}

	/// Answer to `.loginPINRequested`.
	public func setLoginPIN(_ pin: String) {
		let digits = pin.filter(\.isNumber)
		withHandle { h in digits.withCString { _ = ps_session_set_login_pin(h, $0) } }
	}

	/// Puts the console into rest mode (the session ends shortly after).
	public func putConsoleToSleep() {
		withHandle { _ = ps_session_goto_bed($0) }
	}

	public func goHome() {
		withHandle { _ = ps_session_go_home($0) }
	}

	public func stats() -> SessionStats {
		var out = SessionStats()
		withHandle { h in
			var raw = PSSessionStats()
			ps_session_get_stats(h, &raw)
			out.measuredBitrate = raw.measured_bitrate
			out.packetLoss = raw.packet_loss
			out.rttMilliseconds = Double(raw.rtt_us) / 1000
			out.mtuIn = Int(raw.mtu_in)
			out.mtuOut = Int(raw.mtu_out)
			out.consoleTargetBitrate = Double(raw.console_target_bitrate)
			out.consoleRTT = raw.console_rtt
			out.consoleLoss = raw.console_loss
			out.consoleReports = raw.console_reports
			out.corruptReportsSent = raw.corrupt_reports_sent
			out.keyframeRequestsSent = raw.idr_requests_sent
		}
		return out
	}

	// MARK: Events (core threads)

	private func emit(_ event: SessionEvent) {
		DispatchQueue.main.async { self.onEvent?(event) }
	}

	private func handle(event: PSEvent) {
		switch event.type {
		case PS_EVENT_CONNECTED:
			emit(.connected)
		case PS_EVENT_LOGIN_PIN_REQUEST:
			emit(.loginPINRequested(incorrect: event.pin_incorrect))
		case PS_EVENT_NICKNAME_RECEIVED:
			if let text = event.text { emit(.nicknameReceived(String(cString: text))) }
		case PS_EVENT_CANT_DISPLAY:
			emit(.cantDisplay(event.cant_display))
		case PS_EVENT_KEYBOARD_OPEN:
			emit(.keyboardOpened)
		case PS_EVENT_KEYBOARD_TEXT_CHANGE:
			if let text = event.text { emit(.keyboardTextChanged(String(cString: text))) }
		case PS_EVENT_KEYBOARD_REMOTE_CLOSE:
			emit(.keyboardClosed)
		case PS_EVENT_QUIT:
			var reason = event.quit_reason_string.map { String(cString: $0) } ?? "Unknown"
			if let detail = event.quit_detail {
				let text = String(cString: detail)
				if !text.isEmpty { reason += " (\(text))" }
			}
			teardown(reason: reason, isError: event.quit_is_error)
		case PS_EVENT_RUMBLE:
			feedbackSink?.controllerFeedbackRumble(left: event.rumble_left, right: event.rumble_right)
		case PS_EVENT_TRIGGER_EFFECTS:
			let left = withUnsafeBytes(of: event.trigger_left) { Array($0) }
			let right = withUnsafeBytes(of: event.trigger_right) { Array($0) }
			feedbackSink?.controllerFeedbackTriggerEffects(typeLeft: event.trigger_type_left, paramsLeft: left, typeRight: event.trigger_type_right, paramsRight: right)
		case PS_EVENT_LED_COLOR:
			feedbackSink?.controllerFeedbackLED(red: event.led.0, green: event.led.1, blue: event.led.2)
		case PS_EVENT_PLAYER_INDEX:
			feedbackSink?.controllerFeedbackPlayerIndex(event.player_index)
		case PS_EVENT_MOTION_RESET:
			feedbackSink?.controllerFeedbackMotionReset()
		default:
			break
		}
	}
}
