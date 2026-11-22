import AppKit
import Combine
import Foundation
import GameController
import PSContracts

// MARK: - Public model

public struct ControllerInfo: Identifiable, Equatable, Sendable {
	public enum Kind: String, Sendable { case dualSense, dualShock, other }
	/// Stable for as long as the controller stays connected (assigned on connect).
	public let id: Int
	public var name: String
	public var kind: Kind
	public var hasMotion: Bool
	public var hasTouchpad: Bool
	public var hasAdaptiveTriggers: Bool
	/// 0...1 or nil when unknown.
	public var batteryLevel: Float?
	public var isDualSense: Bool { kind == .dualSense }
}

final class Locked<T> {
	private var v: T
	private let l = NSLock()
	init(_ v: T) { self.v = v }
	var value: T {
		get { l.lock(); defer { l.unlock() }; return v }
		set { l.lock(); v = newValue; l.unlock() }
	}
}

// MARK: - ControllerInput

/// Maps the active GameController-framework controller (plus an optional keyboard fallback) to
/// `ControllerState`, and renders the console's feedback (rumble, adaptive triggers, light bar, player
/// index, haptics-as-rumble) back onto it.
///
/// Threading: all mutable state lives on one private serial queue; GameController handlers are run on it
/// (`handlerQueue`). `@Published` properties are updated on the main thread. The `ControllerFeedbackSink` /
/// `HapticsStreamSink` methods may be called from any thread and return immediately.
public final class ControllerInput: ObservableObject, ControllerFeedbackSink, HapticsStreamSink {

	// MARK: UI-facing (main thread)

	/// Connected controllers that have an extended gamepad profile, DualSense first.
	@Published public private(set) var controllers: [ControllerInfo] = []
	@Published public private(set) var activeControllerID: Int?
	/// Human readable summary of the macOS 27 controller Home button settings (empty if not readable).
	@Published public private(set) var homeButtonStatus: String = ""
	/// Keyboard fallback on/off (effective only while `receiver != nil`). Default on.
	@Published public var keyboardEnabled: Bool = true {
		didSet { let v = keyboardEnabled; queue.async { [self] in kbEnabled = v; pushState() } }
	}

	public var activeController: ControllerInfo? { controllers.first { $0.id == activeControllerID } }

	// MARK: Configuration

	/// Where controller snapshots go. Set it when a session starts, nil it when it ends.
	public weak var receiver: ControllerStateReceiver? {
		didSet { queue.async { [self] in receiverChanged() } }
	}

	/// Approximate the 3 kHz DualSense haptics PCM stream by driving the rumble motors with its envelope.
	/// Explicit rumble events always take priority while they are non-zero.
	public var hapticsToRumbleEnabled: Bool {
		get { hapticsEnabled.value }
		set { hapticsEnabled.value = newValue; queue.async { [self] in mixer.hapticsEnabled = newValue; if !newValue { mixer.hapticsLeft = 0; mixer.hapticsRight = 0 }; applyRumble() } }
	}
	/// Gain for the haptics-derived rumble (1 = chiaki-ng "normal").
	public var hapticsRumbleGain: Float {
		get { hapticsGain.value }
		set { hapticsGain.value = max(0, newValue) }
	}
	/// Gain for explicit rumble events (clamped to 0...1 after scaling).
	public var rumbleGain: Float {
		get { rumbleGainValue.value }
		set { rumbleGainValue.value = max(0, newValue); queue.async { [self] in applyRumble() } }
	}
	/// Read motion sensors while a receiver is set (costs controller battery / Bluetooth bandwidth).
	public var motionEnabled: Bool {
		get { motionOn.value }
		set { motionOn.value = newValue; queue.async { [self] in updateMotionActivation() } }
	}
	/// Receive controller input while the app is not frontmost (default false).
	public var allowBackgroundInput: Bool {
		get { backgroundInput.value }
		set { backgroundInput.value = newValue; GCController.shouldMonitorBackgroundEvents = newValue }
	}

	// MARK: Internals (queue-confined unless noted)

	private let queue = DispatchQueue(label: "playstream.input", qos: .userInteractive)
	private let hapticsEnabled = Locked(false)
	private let hapticsGain = Locked<Float>(1)
	private let rumbleGainValue = Locked<Float>(1)
	private let motionOn = Locked(true)
	private let backgroundInput = Locked(false)
	private let hapticsThrottle = Locked<(last: UInt64, l: Float, r: Float)>((0, 0, 0))
	private let lastHapticsPacket = Locked<UInt64>(0)

	private struct Entry {
		let id: Int
		let controller: GCController
		var info: ControllerInfo
	}
	private var entries: [Int: Entry] = [:]
	private var nextID = 1
	private var activeID: Int?
	private var manualSelection = false
	private var running = false
	private var observers: [NSObjectProtocol] = []
	private lazy var notificationQueue: OperationQueue = {
		let q = OperationQueue()
		q.underlyingQueue = queue
		return q
	}()

	private var padState = ControllerState()
	private var touchTracker = TouchTracker()
	private var orientation = OrientationTracker()
	private var lastSent: ControllerState?
	private var lastPushTime: Double = 0
	private var kbEnabled = true
	private var pressedKeys: Set<UInt16> = []

	private var mixer = RumbleMixer()
	private var rumbleDriver: HapticRumble?
	private var triggerLeft: (type: UInt8, params: [UInt8])?
	private var triggerRight: (type: UInt8, params: [UInt8])?
	private var appliedTriggers: (TriggerEffect?, TriggerEffect?) = (nil, nil)
	private var led: (UInt8, UInt8, UInt8)?
	private var playerIndex: UInt8?
	private var hapticsTimer: DispatchSourceTimer?

	// main-thread only
	private var keyMonitor: Any?
	private var resignObserver: NSObjectProtocol?
	private var swallowedKeys: Set<UInt16> = []

	public init() {}

	deinit {
		let drv = rumbleDriver
		drv?.shutdown()
	}

	// MARK: - Lifecycle

	/// Start tracking controllers. Call once at app launch (so the controller list is live) or per session.
	public func start() {
		queue.sync {
			guard !running else { return }
			running = true
			GCController.shouldMonitorBackgroundEvents = backgroundInput.value
			let nc = NotificationCenter.default
			observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: notificationQueue) { [weak self] n in
				if let c = n.object as? GCController { self?.add(c) }
			})
			observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: notificationQueue) { [weak self] n in
				if let c = n.object as? GCController { self?.remove(c) }
			})
			for c in GCController.controllers() { add(c) }
			startHapticsTimer()
		}
		refreshHomeButtonStatus()
	}

	/// Silence motors, reset triggers, stop observing, release every framework object. Safe to call twice.
	public func stop() {
		DispatchQueue.main.async { [self] in removeKeyboardMonitor() }
		queue.sync {
			silenceLocked()
			deactivateLocked()
			for o in observers { NotificationCenter.default.removeObserver(o) }
			observers.removeAll()
			for e in entries.values { detach(e.controller) }
			entries.removeAll()
			hapticsTimer?.cancel()
			hapticsTimer = nil
			rumbleDriver?.shutdown()
			rumbleDriver = nil
			pressedKeys.removeAll()
			mixer = RumbleMixer()
			mixer.hapticsEnabled = hapticsEnabled.value
			triggerLeft = nil; triggerRight = nil; led = nil; playerIndex = nil
			padState = ControllerState()
			lastSent = nil
			running = false
		}
		publish()
	}

	/// Silence rumble and reset adaptive triggers on the active controller without releasing anything
	/// (call when a session ends).
	public func silenceFeedback() {
		queue.sync { silenceLocked() }
	}

	private func silenceLocked() {
		mixer.explicitLeft = 0; mixer.explicitRight = 0
		mixer.hapticsLeft = 0; mixer.hapticsRight = 0
		rumbleDriver?.set(left: 0, right: 0)
		triggerLeft = nil; triggerRight = nil
		appliedTriggers = (nil, nil)
		if let pad = activePad() as? GCDualSenseGamepad {
			pad.leftTrigger.setModeOff()
			pad.rightTrigger.setModeOff()
		}
	}

	// MARK: - Controller management

	/// Make `id` the active controller (nil = go back to automatic: DualSense first, and any controller you
	/// press takes over). Ignored for unknown ids.
	public func selectController(id: Int?) {
		queue.async { [self] in
			if let id {
				guard entries[id] != nil else { return }
				manualSelection = true
				activateLocked(id)
			} else {
				manualSelection = false
				if let best = bestID(), best != activeID { activateLocked(best) }
			}
		}
	}

	private func kind(of c: GCController) -> ControllerInfo.Kind {
		if c.extendedGamepad is GCDualSenseGamepad { return .dualSense }
		if c.extendedGamepad is GCDualShockGamepad { return .dualShock }
		return .other
	}

	private func add(_ c: GCController) {
		guard running, c.extendedGamepad != nil else { return }
		if entries.values.contains(where: { $0.controller === c }) { return }
		let id = nextID; nextID += 1
		let k = kind(of: c)
		let info = ControllerInfo(
			id: id,
			name: c.vendorName ?? c.productCategory,
			kind: k,
			hasMotion: c.motion != nil,
			hasTouchpad: k != .other,
			hasAdaptiveTriggers: k == .dualSense,
			batteryLevel: c.battery.map { $0.batteryLevel })
		entries[id] = Entry(id: id, controller: c, info: info)
		c.handlerQueue = queue
		// Ask the system not to run its own gesture on any button (Home/PS, Create, Options, ...), so
		// they reach us. The system is free to ignore this (see Home button notes).
		for (_, b) in c.physicalInputProfile.buttons { b.preferredSystemGestureState = .disabled }
		c.extendedGamepad?.valueChangedHandler = { [weak self] gamepad, _ in
			self?.gamepadChanged(id: id, gamepad)
		}
		publish()
		if activeID == nil || (!manualSelection && bestID() != activeID) {
			if let best = bestID() { activateLocked(best) }
		}
		DispatchQueue.main.async { [self] in refreshHomeButtonStatus() }
	}

	private func remove(_ c: GCController) {
		guard let e = entries.values.first(where: { $0.controller === c }) else { return }
		let wasActive = e.id == activeID
		if wasActive { deactivateLocked() }
		detach(c)
		entries[e.id] = nil
		if wasActive {
			// Active controller vanished mid-game: tell the console everything is released, then move on.
			padState = ControllerState()
			touchTracker.reset()
			pushState(force: true)
			manualSelection = false
			if let next = bestID() { activateLocked(next) }
		}
		publish()
	}

	private func detach(_ c: GCController) {
		c.extendedGamepad?.valueChangedHandler = nil
		c.motion?.valueChangedHandler = nil
		if c.motion?.sensorsRequireManualActivation == true { c.motion?.sensorsActive = false }
	}

	private func bestID() -> Int? {
		func rank(_ k: ControllerInfo.Kind) -> Int { k == .dualSense ? 0 : (k == .dualShock ? 1 : 2) }
		return entries.values.min { (rank($0.info.kind), $0.id) < (rank($1.info.kind), $1.id) }?.id
	}

	private func activePad() -> GCExtendedGamepad? {
		guard let id = activeID else { return nil }
		return entries[id]?.controller.extendedGamepad
	}

	private func activateLocked(_ id: Int) {
		guard entries[id] != nil, id != activeID else { return }
		deactivateLocked()
		activeID = id
		padState = ControllerState()
		touchTracker.reset()
		orientation = OrientationTracker()
		appliedTriggers = (nil, nil)
		if let pad = activePad() { padState = readPad(pad) }
		updateMotionActivation()
		applyLEDAndPlayer()
		applyTriggers()
		applyRumble()
		pushState(force: true)
		publish()
	}

	/// Silence and release the current active controller (does not touch `activeID` publishing).
	private func deactivateLocked() {
		guard let id = activeID else { return }
		if let e = entries[id] {
			rumbleDriver?.set(left: 0, right: 0)
			if let pad = e.controller.extendedGamepad as? GCDualSenseGamepad {
				pad.leftTrigger.setModeOff()
				pad.rightTrigger.setModeOff()
			}
			e.controller.motion?.valueChangedHandler = nil
			if e.controller.motion?.sensorsRequireManualActivation == true { e.controller.motion?.sensorsActive = false }
		}
		rumbleDriver?.shutdown()
		rumbleDriver = nil
		activeID = nil
	}

	private func publish() {
		let infos = entries.values.sorted { a, b in
			let ra = a.info.kind == .dualSense ? 0 : 1, rb = b.info.kind == .dualSense ? 0 : 1
			return (ra, a.id) < (rb, b.id)
		}.map { e -> ControllerInfo in
			var i = e.info
			i.batteryLevel = e.controller.battery.map { $0.batteryLevel }
			return i
		}
		let active = activeID
		DispatchQueue.main.async { [self] in
			if controllers != infos { controllers = infos }
			if activeControllerID != active { activeControllerID = active }
		}
	}

	// MARK: - State mapping

	private func gamepadChanged(id: Int, _ gamepad: GCExtendedGamepad) {
		if id == activeID {
			padState = readPad(gamepad)
			pushState()
		} else if !manualSelection, entries[id] != nil {
			// Several controllers connected: whichever one the player actually presses becomes active.
			var probe = ControllerState()
			readSticksAndButtons(gamepad, into: &probe)
			if Self.isMeaningful(probe) { activateLocked(id) }
		}
	}

	static func isMeaningful(_ s: ControllerState) -> Bool {
		!s.buttons.isEmpty || s.l2 > 128 || s.r2 > 128
			|| [s.leftX, s.leftY, s.rightX, s.rightY].contains { $0.magnitude > 16384 }
	}

	private func readSticksAndButtons(_ g: GCExtendedGamepad, into s: inout ControllerState) {
		var b: ControllerButtons = []
		func set(_ pressed: Bool?, _ flag: ControllerButtons) { if pressed == true { b.insert(flag) } }
		set(g.buttonA.isPressed, .cross)
		set(g.buttonB.isPressed, .circle)
		set(g.buttonX.isPressed, .square)
		set(g.buttonY.isPressed, .triangle)
		set(g.dpad.left.isPressed, .dpadLeft)
		set(g.dpad.right.isPressed, .dpadRight)
		set(g.dpad.up.isPressed, .dpadUp)
		set(g.dpad.down.isPressed, .dpadDown)
		set(g.leftShoulder.isPressed, .l1)
		set(g.rightShoulder.isPressed, .r1)
		set(g.leftThumbstickButton?.isPressed, .l3)
		set(g.rightThumbstickButton?.isPressed, .r3)
		set(g.buttonMenu.isPressed, .options)       // Options on DualSense
		set(g.buttonOptions?.isPressed, .share)     // Create on DualSense
		set(g.buttonHome?.isPressed, .ps)           // PS button
		if let ds = g as? GCDualSenseGamepad { set(ds.touchpadButton.isPressed, .touchpad) }
		else if let d4 = g as? GCDualShockGamepad { set(d4.touchpadButton.isPressed, .touchpad) }
		s.buttons = b
		s.l2 = InputMapping.trigger(g.leftTrigger.value)
		s.r2 = InputMapping.trigger(g.rightTrigger.value)
		s.leftX = InputMapping.stick(g.leftThumbstick.xAxis.value)
		s.leftY = InputMapping.stickY(g.leftThumbstick.yAxis.value)
		s.rightX = InputMapping.stick(g.rightThumbstick.xAxis.value)
		s.rightY = InputMapping.stickY(g.rightThumbstick.yAxis.value)
	}

	/// Full controller-derived state (buttons, sticks, triggers, touch) merged with the latest motion.
	private func readPad(_ g: GCExtendedGamepad) -> ControllerState {
		var s = ControllerState()
		readSticksAndButtons(g, into: &s)
		let pads: (GCControllerDirectionPad, GCControllerDirectionPad)?
		if let ds = g as? GCDualSenseGamepad { pads = (ds.touchpadPrimary, ds.touchpadSecondary) }
		else if let d4 = g as? GCDualShockGamepad { pads = (d4.touchpadPrimary, d4.touchpadSecondary) }
		else { pads = nil }
		if let (p, q) = pads {
			for (i, pad) in [p, q].enumerated() {
				let x = pad.xAxis.value, y = pad.yAxis.value
				let pt = InputMapping.touchpadPoint(x: x, y: y)
				touchTracker.update(finger: i, down: InputMapping.isFingerDown(x: x, y: y), x: pt.x, y: pt.y)
			}
		}
		touchTracker.apply(to: &s)
		orientation.apply(to: &s)
		return s
	}

	private func receiverChanged() {
		updateMotionActivation()
		pushState(force: true)
	}

	private func keyboardEffective() -> Bool { kbEnabled && receiver != nil }

	private func pushState(force: Bool = false) {
		let kb = keyboardEffective() ? KeyboardMapping.state(pressed: pressedKeys) : ControllerState()
		let s = StateMerge.merged(pad: padState, keyboard: kb)
		if !force, s == lastSent { return }
		lastSent = s
		lastPushTime = ProcessInfo.processInfo.systemUptime
		receiver?.controllerStateDidChange(s)
	}

	// MARK: - Motion

	private func updateMotionActivation() {
		guard let id = activeID, let c = entries[id]?.controller, let motion = c.motion else { return }
		let want = motionOn.value && receiver != nil && running
		if want {
			motion.valueChangedHandler = { [weak self] m in self?.motionUpdated(id: id, m) }
			if motion.sensorsRequireManualActivation { motion.sensorsActive = true }
		} else {
			motion.valueChangedHandler = nil
			if motion.sensorsRequireManualActivation { motion.sensorsActive = false }
		}
	}

	private func motionUpdated(id: Int, _ m: GCMotion) {
		guard id == activeID else { return }
		let r = m.rotationRate, a = m.acceleration
		let conv = MotionAxisMapping.convert(gcRotationRate: (r.x, r.y, r.z), gcAcceleration: (a.x, a.y, a.z))
		let now = ProcessInfo.processInfo.systemUptime
		orientation.update(gyro: conv.gyro, accel: conv.accel, time: now)
		orientation.apply(to: &padState)
		// Motion arrives at the sensor rate; coalesce pushes (the core rate-limits sending anyway).
		if now - lastPushTime >= 0.008 { pushState() }
	}

	public func controllerFeedbackMotionReset() {
		queue.async { [self] in
			orientation.resetReference(time: ProcessInfo.processInfo.systemUptime)
			orientation.apply(to: &padState)
			pushState()
		}
	}

	// MARK: - Keyboard fallback

	/// Install an app-wide local NSEvent monitor (main thread). It sees key events before the responder chain, so
	/// no first-responder handling is needed. Keys are ignored (passed through) while a text field is being
	/// edited, while Command/Control is held, or while `keyboardEnabled == false` / no receiver is set.
	public func installKeyboardMonitor() {
		assert(Thread.isMainThread)
		guard keyMonitor == nil else { return }
		keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
			guard let self else { return e }
			return self.handleKeyEvent(e) ? nil : e
		}
		resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
			self?.releaseAllKeys()
		}
	}

	public func removeKeyboardMonitor() {
		if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
		if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
		releaseAllKeys()
	}

	/// Feed a key event yourself instead of using the monitor (e.g. from an NSView's keyDown/keyUp).
	/// Returns true if the event was consumed and should not be processed further.
	@discardableResult
	public func handleKeyEvent(_ event: NSEvent) -> Bool {
		guard event.type == .keyDown || event.type == .keyUp else { return false }
		let code = event.keyCode
		if event.type == .keyUp {
			guard swallowedKeys.remove(code) != nil else { return false }
			setKey(code, down: false)
			return true
		}
		guard KeyboardMapping.isMapped(code), keyboardEnabled, receiver != nil else { return false }
		if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
		if NSApp?.keyWindow?.firstResponder is NSText { return false }
		if swallowedKeys.contains(code) { return true }   // auto-repeat
		swallowedKeys.insert(code)
		setKey(code, down: true)
		return true
	}

	/// Lowest-level entry point: a mapped key went down/up.
	public func setKey(_ keyCode: UInt16, down: Bool) {
		queue.async { [self] in
			if down { pressedKeys.insert(keyCode) } else { pressedKeys.remove(keyCode) }
			pushState()
		}
	}

	public func releaseAllKeys() {
		swallowedKeys.removeAll()
		queue.async { [self] in
			guard !pressedKeys.isEmpty else { return }
			pressedKeys.removeAll()
			pushState()
		}
	}

	// MARK: - Feedback (network threads)

	public func controllerFeedbackRumble(left: UInt8, right: UInt8) {
		queue.async { [self] in
			mixer.explicitLeft = left
			mixer.explicitRight = right
			applyRumble()
		}
	}

	public func controllerFeedbackTriggerEffects(typeLeft: UInt8, paramsLeft: [UInt8], typeRight: UInt8, paramsRight: [UInt8]) {
		queue.async { [self] in
			triggerLeft = (typeLeft, paramsLeft)
			triggerRight = (typeRight, paramsRight)
			applyTriggers()
		}
	}

	public func controllerFeedbackLED(red: UInt8, green: UInt8, blue: UInt8) {
		queue.async { [self] in
			led = (red, green, blue)
			applyLEDAndPlayer()
		}
	}

	public func controllerFeedbackPlayerIndex(_ index: UInt8) {
		queue.async { [self] in
			playerIndex = index
			applyLEDAndPlayer()
		}
	}

	private func applyRumble() {
		let out = mixer.output
		let g = rumbleGainValue.value
		// Gain only scales explicit rumble; haptics have their own gain applied at the envelope.
		let explicit = mixer.explicitLeft != 0 || mixer.explicitRight != 0
		let l = explicit ? min(1, out.left * g) : out.left
		let r = explicit ? min(1, out.right * g) : out.right
		if l == 0 && r == 0 {
			rumbleDriver?.set(left: 0, right: 0)
			return
		}
		guard let id = activeID, let c = entries[id]?.controller else { return }
		if rumbleDriver == nil { rumbleDriver = HapticRumble(controller: c) }
		rumbleDriver?.set(left: l, right: r)
	}

	private func applyTriggers() {
		guard let pad = activePad() as? GCDualSenseGamepad else { return }
		let l = triggerLeft.map { TriggerEffect.decode(type: $0.type, params: $0.params) } ?? .off
		let r = triggerRight.map { TriggerEffect.decode(type: $0.type, params: $0.params) } ?? .off
		if appliedTriggers.0 != l { l.apply(to: pad.leftTrigger); appliedTriggers.0 = l }
		if appliedTriggers.1 != r { r.apply(to: pad.rightTrigger); appliedTriggers.1 = r }
	}

	private func applyLEDAndPlayer() {
		guard let id = activeID, let c = entries[id]?.controller else { return }
		if let (r, g, b) = led, let light = c.light {
			light.color = GCColor(red: Float(r) / 255, green: Float(g) / 255, blue: Float(b) / 255)
		}
		if let p = playerIndex {
			c.playerIndex = GCControllerPlayerIndex(rawValue: Int(p)) ?? .indexUnset
		}
	}

	// MARK: - Haptics PCM -> rumble approximation

	public func hapticsStreamDidReceive(pcm: UnsafeBufferPointer<Int16>, frameCount: Int) {
		guard hapticsEnabled.value else { return }
		var lv = HapticsEnvelope.levels(pcm: pcm, frameCount: frameCount)
		let g = hapticsGain.value
		lv.left = min(1, lv.left * g)
		lv.right = min(1, lv.right * g)
		let now = DispatchTime.now().uptimeNanoseconds
		lastHapticsPacket.value = now
		// Envelope follower: instant attack, quick release, so short pulses are felt but do not chatter.
		var shouldSend = false
		var send = (Float(0), Float(0))
		var th = hapticsThrottle.value
		th.l = max(lv.left, th.l * 0.6)
		th.r = max(lv.right, th.r * 0.6)
		if th.l < 0.0015 { th.l = 0 }
		if th.r < 0.0015 { th.r = 0 }
		if now &- th.last >= 20_000_000 { th.last = now; shouldSend = true; send = (th.l, th.r) }
		hapticsThrottle.value = th
		guard shouldSend else { return }
		queue.async { [self] in
			guard mixer.hapticsEnabled else { return }
			mixer.hapticsLeft = send.0
			mixer.hapticsRight = send.1
			applyRumble()
		}
	}

	/// Stream stalled or ended: haptics-derived rumble must not stay on.
	private func startHapticsTimer() {
		let t = DispatchSource.makeTimerSource(queue: queue)
		t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
		t.setEventHandler { [weak self] in
			guard let self else { return }
			guard self.mixer.hapticsLeft != 0 || self.mixer.hapticsRight != 0 else { return }
			let age = DispatchTime.now().uptimeNanoseconds &- self.lastHapticsPacket.value
			if age > 100_000_000 {
				self.mixer.hapticsLeft = 0; self.mixer.hapticsRight = 0
				self.hapticsThrottle.value = (0, 0, 0)
				self.applyRumble()
			}
		}
		t.resume()
		hapticsTimer = t
		mixer.hapticsEnabled = hapticsEnabled.value
	}

	// MARK: - Home button settings (macOS 27)

	private func refreshHomeButtonStatus() {
		if #available(macOS 27.0, *) {
			Task { @MainActor [weak self] in
				guard let self else { return }
				let m = GCControllerHomeButtonSettingsManager()
				var parts: [String] = []
				do {
					let s = try m.controllerHomeButtonSystemAction
					let name: String
					switch s.action {
					case .disabled: name = "disabled"
					case .openCurrentApplication: name = "opens the current app"
					case .other: name = "other (user-chosen action)"
					default: name = "unavailable"
					}
					parts.append("long-press system action: \(name)\(s.customized == .user ? " (user-customized)" : "")")
				} catch { parts.append("system action unreadable: \(error.localizedDescription)") }
				do {
					let a = try m.controllerHomeButtonInAppAction
					let name: String
					switch a.action {
					case .disabled: name = "system response disabled"
					case .defer: name = "defers to app (app may take the button)"
					case .systemDefault: name = "system default (app preference ignored)"
					default: name = "unavailable"
					}
					parts.append("in-app action: \(name)\(a.customized == .user ? " (user-customized)" : "")")
				} catch { parts.append("in-app action unreadable: \(error.localizedDescription)") }
				self.homeButtonStatus = parts.joined(separator: "; ")
			}
		}
	}

	/// Opens System Settings at the controller Home button in-app action (macOS 27+). Throws/ignored otherwise.
	public func openHomeButtonSettings() {
		if #available(macOS 27.0, *) {
			Task { @MainActor in
				try? GCControllerHomeButtonSettingsManager().openControllerHomeButtonSettings(for: .customizeInAppAction)
			}
		}
	}
}
