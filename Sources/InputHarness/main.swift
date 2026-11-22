import AppKit
import Combine
import Foundation
import GameController
import PSContracts
import PSInput

// ps-input-harness: exercises PSInput without the app.
//
//   ps-input-harness                       self-tests, then list controllers and watch for 20 s
//   ps-input-harness --selftest            self-tests only
//   ps-input-harness --seconds N           watch time
//   ps-input-harness --motion              also print gyro/accel/orientation (verify axis signs live)
//   ps-input-harness --rumble              after connect, 0.5 s rumble (strong then weak) then silence
//   ps-input-harness --trigger             weapon effect on both adaptive triggers for 3 s, then off
//   ps-input-harness --haptics             feed a synthetic 3 kHz haptics burst through the PCM->rumble path
//   ps-input-harness --window              show a small window, route its key events through the keyboard fallback
//   ps-input-harness --background          receive controller input while not frontmost
//   ps-input-harness --accessory           use the accessory activation policy instead of regular

let args = Array(CommandLine.arguments.dropFirst())
func flag(_ n: String) -> Bool { args.contains("--" + n) }
func value(_ n: String) -> String? { args.firstIndex(of: "--" + n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

// MARK: - Self tests (pure parts)

var failures = 0
var checks = 0
func check(_ cond: @autoclosure () -> Bool, _ what: String, line: Int = #line) {
	checks += 1
	if !cond() { failures += 1; print("FAIL (line \(line)): \(what)") }
}
func near(_ a: Float, _ b: Float, _ tol: Float = 0.01) -> Bool { abs(a - b) <= tol }

func selfTests() {
	// Sticks: full range both directions, y inverted (GC up-positive -> protocol down-positive).
	check(InputMapping.stick(1) == 32767, "stick +1")
	check(InputMapping.stick(-1) == -32768, "stick -1")
	check(InputMapping.stick(0) == 0, "stick 0")
	check(InputMapping.stick(2) == 32767 && InputMapping.stick(-2) == -32768, "stick clamps")
	check(InputMapping.stick(.nan) == 0, "stick nan")
	check(InputMapping.stickY(1) == -32768, "stickY: GC up (+1) is protocol -32768 (up)")
	check(InputMapping.stickY(-1) == 32767, "stickY: GC down (-1) is protocol +32767 (down)")
	check(InputMapping.stickY(0) == 0, "stickY 0")
	check(abs(Int(InputMapping.stick(0.5)) - 16384) <= 1, "stick 0.5")
	// Triggers
	check(InputMapping.trigger(0) == 0, "trigger 0")
	check(InputMapping.trigger(1) == 255, "trigger 1")
	check(InputMapping.trigger(0.5) == 128, "trigger 0.5")
	check(InputMapping.trigger(-1) == 0 && InputMapping.trigger(3) == 255, "trigger clamps")
	// Touchpad mapping (GC: x right, y UP, -1...1  ->  1920x1079 pad, origin top-left)
	var p = InputMapping.touchpadPoint(x: -1, y: 1)
	check(p.x == 0 && p.y == 0, "touchpad top-left")
	p = InputMapping.touchpadPoint(x: 1, y: -1)
	check(p.x == 1919 && p.y == 1078, "touchpad bottom-right \(p)")
	p = InputMapping.touchpadPoint(x: 0.5, y: 0.5)
	check(p.x == 1439 && p.y == 270, "touchpad (0.5,0.5) -> upper right \(p)")
	check(!InputMapping.isFingerDown(x: 0, y: 0) && InputMapping.isFingerDown(x: 0, y: 0.01), "finger down heuristic")

	// Touch id allocation
	var t = TouchTracker()
	t.update(finger: 0, down: true, x: 100, y: 200)
	check(t.slot0 == ControllerTouch(x: 100, y: 200, id: 0) && t.slot1.id == -1 && t.touchIdNext == 1, "touch: first finger id 0")
	t.update(finger: 1, down: true, x: 300, y: 400)
	check(t.slot1 == ControllerTouch(x: 300, y: 400, id: 1) && t.touchIdNext == 2, "touch: second finger id 1")
	t.update(finger: 0, down: true, x: 110, y: 210)
	check(t.slot0 == ControllerTouch(x: 110, y: 210, id: 0) && t.touchIdNext == 2, "touch: move keeps id")
	t.update(finger: 0, down: false, x: 0, y: 0)
	check(t.slot0.id == -1 && t.slot1.id == 1, "touch: lift finger 0 only")
	t.update(finger: 0, down: true, x: 5, y: 6)
	check(t.slot0.id == 2 && t.slot1.id == 1, "touch: new touch gets a new id (2), not a reused one")
	t.update(finger: 1, down: false, x: 0, y: 0)
	t.update(finger: 0, down: false, x: 0, y: 0)
	check(t.slot0.id == -1 && t.slot1.id == -1, "touch: all up")
	var wrap = TouchTracker()
	var lastId: Int8 = -1
	for _ in 0..<130 {
		wrap.update(finger: 0, down: true, x: 1, y: 1)
		lastId = wrap.slot0.id
		wrap.update(finger: 0, down: false, x: 0, y: 0)
	}
	check(lastId == 1 && wrap.touchIdNext == 2, "touch: ids wrap at 128 (got \(lastId), next \(wrap.touchIdNext))")
	var st = ControllerState()
	t.update(finger: 1, down: true, x: 7, y: 8)
	t.apply(to: &st)
	check(st.touch0.id >= 0 && st.touchIdNext == t.touchIdNext, "touch apply")

	// Trigger effect decoding (byte layouts as produced by dualsensectl's encoders)
	check(TriggerEffect.decode(type: 0x05, params: [UInt8](repeating: 0, count: 10)) == .off, "trigger off 0x05")
	check(TriggerEffect.decode(type: 0x00, params: []) == .off, "trigger off 0x00")
	// feedback: position 3, strength 5 -> zones 3...9, value 4 in each 3-bit field
	var bits: UInt32 = 0
	for i in 3..<10 { bits |= UInt32(4) << UInt32(3 * i) }
	let mask: UInt16 = (0..<10).filter { $0 >= 3 }.reduce(0) { $0 | (1 << UInt16($1)) }
	let fb: [UInt8] = [UInt8(mask & 0xff), UInt8(mask >> 8), UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff), 0, 0, 0, 0]
	let fbe = TriggerEffect.decode(type: 0x21, params: fb)
	check(fbe == .feedback(strengths: [0, 0, 0, 5, 5, 5, 5, 5, 5, 5]), "feedback decode \(fbe)")
	if case .feedback(let r) = fbe.gcRendering {
		check(r.count == 10 && r[2] == 0 && near(r[3], 5.0 / 8), "feedback GC rendering")
	} else { check(false, "feedback renders as feedback") }
	// weapon: start 2, end 5, strength 7
	let we = TriggerEffect.decode(type: 0x25, params: [0x24, 0, 6, 0, 0, 0, 0, 0, 0, 0])
	check(we == .weapon(startZone: 2, endZone: 5, strength: 7), "weapon decode \(we)")
	if case .weapon(let s, let e, let st) = we.gcRendering { check(near(s, 2.0 / 9) && near(e, 5.0 / 9) && near(st, 7.0 / 8), "weapon GC rendering") }
	else { check(false, "weapon renders as weapon") }
	check(TriggerEffect.decode(type: 0x25, params: [0, 0, 6, 0, 0, 0, 0, 0, 0, 0]) == .off, "weapon with empty mask is off")
	// vibration: position 4, amplitude 8, frequency 30
	var vb: UInt32 = 0
	for i in 4..<10 { vb |= UInt32(7) << UInt32(3 * i) }
	let vm: UInt16 = 0x3f0
	let ve = TriggerEffect.decode(type: 0x26, params: [UInt8(vm & 0xff), UInt8(vm >> 8), UInt8(vb & 0xff), UInt8((vb >> 8) & 0xff), UInt8((vb >> 16) & 0xff), UInt8((vb >> 24) & 0xff), 0, 0, 30, 0])
	check(ve == .vibration(amplitudes: [0, 0, 0, 0, 8, 8, 8, 8, 8, 8], frequency: 30), "vibration decode \(ve)")
	check(TriggerEffect.decode(type: 0x26, params: [UInt8(vm & 0xff), UInt8(vm >> 8), UInt8(vb & 0xff), UInt8((vb >> 8) & 0xff), UInt8((vb >> 16) & 0xff), UInt8((vb >> 24) & 0xff), 0, 0, 0, 0]) == .off, "vibration frequency 0 is off")
	// bow: start 1, end 6, strength 3, snap 5 -> p2 = 2 | 4<<3
	check(TriggerEffect.decode(type: 0x22, params: [0x42, 0, 2 | (4 << 3), 0, 0, 0, 0, 0, 0, 0]) == .bow(startZone: 1, endZone: 6, strength: 3, snap: 5), "bow decode")
	check(TriggerEffect.decode(type: 0x23, params: [0x21, 0, 3 | (1 << 3), 9, 0, 0, 0, 0, 0, 0]) == .galloping(startZone: 0, endZone: 5, firstFoot: 1, secondFoot: 3, frequency: 9), "galloping decode")
	check(TriggerEffect.decode(type: 0x27, params: [0x0e, 0x00, 6 | (2 << 3), 40, 12, 0, 0, 0, 0, 0]) == .machine(startZone: 1, endZone: 3, ampA: 6, ampB: 2, frequency: 40, period: 12), "machine decode")
	check(TriggerEffect.decode(type: 0x01, params: [1, 2, 3]) == .unsupported(type: 0x01) && TriggerEffect.decode(type: 0x01, params: []).gcRendering == .off, "legacy mode falls back to off")
	check(TriggerEffect.decode(type: 0x23, params: [0x21, 0, 0, 9, 0, 0, 0, 0, 0, 0]).gcRendering == .off, "galloping renders off")
	check(TriggerEffect.decode(type: 0x25, params: [0x24, 0]).gcRendering != .off, "short param array is zero padded")

	// Keyboard
	var ks = KeyboardMapping.state(pressed: [124, 36, 53])
	check(ks.buttons == [.dpadRight, .cross, .circle], "keyboard buttons \(ks.buttons)")
	ks = KeyboardMapping.state(pressed: [13])   // W = left stick up = protocol -y
	check(ks.leftY == -32768 && ks.leftX == 0, "keyboard W = stick up (negative y)")
	ks = KeyboardMapping.state(pressed: [1, 2])   // S + D
	check(ks.leftX > 22000 && ks.leftX < 23500 && ks.leftY == ks.leftX, "keyboard diagonal normalised \(ks.leftX),\(ks.leftY)")
	ks = KeyboardMapping.state(pressed: [19, 20, 50, 17])
	check(ks.l2 == 255 && ks.r2 == 255 && ks.buttons == [.ps, .touchpad], "keyboard triggers, PS, touchpad")
	check(KeyboardMapping.state(pressed: []) == ControllerState(), "keyboard idle == idle")

	// Merge
	var a = ControllerState(); a.buttons = .cross; a.leftX = -20000; a.l2 = 10
	var b = ControllerState(); b.buttons = .circle; b.leftX = 5000; b.l2 = 200
	let m = StateMerge.merged(pad: a, keyboard: b)
	check(m.buttons == [.cross, .circle] && m.leftX == -20000 && m.l2 == 200, "merge")

	// Rumble mixing: explicit always wins, haptics only when explicit is silent
	var mx = RumbleMixer()
	check(mx.output == (0, 0), "mixer idle")
	mx.hapticsLeft = 0.8; mx.hapticsRight = 0.4
	check(mx.output == (0, 0), "mixer: haptics off -> nothing")
	mx.hapticsEnabled = true
	check(near(mx.output.left, 0.8) && near(mx.output.right, 0.4), "mixer: haptics on")
	mx.explicitLeft = 255
	check(near(mx.output.left, 1) && mx.output.right == 0, "mixer: explicit wins entirely (no sum)")
	mx.explicitLeft = 0
	check(near(mx.output.left, 0.8), "mixer: back to haptics when explicit stops")

	// Haptics envelope
	let loud = [Int16](repeating: 16384, count: 60)   // 30 stereo frames at half scale
	let lv = loud.withUnsafeBufferPointer { HapticsEnvelope.levels(pcm: $0, frameCount: 30) }
	check(near(lv.left, 1) && near(lv.right, 1), "envelope half scale -> 1.0 (chiaki x2)")
	let quiet = [Int16](repeating: 0, count: 60)
	check(quiet.withUnsafeBufferPointer { HapticsEnvelope.levels(pcm: $0, frameCount: 30) } == (0, 0), "envelope silence")
	var mixed = [Int16](); for _ in 0..<30 { mixed += [-8192, 0] }
	let lm = mixed.withUnsafeBufferPointer { HapticsEnvelope.levels(pcm: $0, frameCount: 30) }
	check(near(lm.left, 0.5) && lm.right == 0, "envelope per channel, magnitude of negatives")

	// Motion axis remap + orientation
	let conv = MotionAxisMapping.convert(gcRotationRate: (1, 2, 3), gcAcceleration: (0.1, -1, 0.2))
	check(conv.gyro == SIMD3<Float>(1, 3, -2), "gyro remap (x, z, -y) \(conv.gyro)")
	check(near(conv.accel.x, -0.1) && near(conv.accel.y, 1) && near(conv.accel.z, -0.2), "accel remap negates; flat (0,-1,0) -> (0,1,0) \(conv.accel)")
	var trk = OrientationTracker()
	var t0 = 100.0
	for _ in 0..<300 { trk.update(gyro: .zero, accel: SIMD3(0, 1, 0), time: t0); t0 += 0.004 }
	var os = ControllerState()
	trk.apply(to: &os)
	check(near(os.orientW, 1, 0.02) && near(os.orientX, 0, 0.02) && near(os.orientY, 0, 0.02) && near(os.orientZ, 0, 0.02), "orientation at rest is identity (\(os.orientX),\(os.orientY),\(os.orientZ),\(os.orientW))")
	check(near(os.accelY, 1) && os.gyroX == 0, "rest accel/gyro passed through")
	// 3 rad/s about the vertical (SDL y) axis for 0.3 s -> ~0.9 rad (slow rates are damped by chiaki's fuzz filter, which we port faithfully) of rotation
	for _ in 0..<75 { trk.update(gyro: SIMD3(0, 3, 0), accel: SIMD3(0, 1, 0), time: t0); t0 += 0.004 }
	trk.apply(to: &os)
	// (angle taken from the y component: chiaki's fuzz filter makes w sluggish for small rotations)
	let angle = 2 * asin(min(1, abs(os.orientY)))
	check(near(angle, 0.9, 0.06), "3 rad/s for 0.3 s integrates to ~0.9 rad (got \(angle); q=\(os.orientX),\(os.orientY),\(os.orientZ),\(os.orientW))")
	check(abs(os.orientX) < 0.05 && abs(os.orientZ) < 0.05, "rotation is about the y axis")
	trk.resetReference(time: t0)
	trk.apply(to: &os)
	check(near(os.orientW, 1, 0.02) && near(os.accelY, 1, 0.001), "motion reset gives identity")

	// Keyboard + mixer plumbing through the real queue (no controller needed)
	final class Rx: ControllerStateReceiver {
		var states: [ControllerState] = []
		let l = NSLock()
		func controllerStateDidChange(_ s: ControllerState) { l.lock(); states.append(s); l.unlock() }
		var last: ControllerState? { l.lock(); defer { l.unlock() }; return states.last }
	}
	let input = ControllerInput()
	let rx = Rx()
	input.start()
	input.receiver = rx
	input.setKey(36, down: true)
	input.setKey(126, down: true)
	input.setKey(13, down: true)
	usleep(100_000)
	check(rx.last?.buttons == [.cross, .dpadUp] && rx.last?.leftY == -32768, "ControllerInput keyboard path \(String(describing: rx.last))")
	input.setKey(36, down: false)
	input.releaseAllKeys()
	usleep(100_000)
	check(rx.last == ControllerState.idle, "keys released -> idle state pushed")
	input.keyboardEnabled = false
	input.setKey(36, down: true)
	usleep(100_000)
	check(rx.last == ControllerState.idle, "keyboard disabled -> nothing")
	input.setKey(36, down: false)
	// NSEvent path (what installKeyboardMonitor feeds)
	input.keyboardEnabled = true
	func key(_ type: NSEvent.EventType, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
		NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
	}
	check(input.handleKeyEvent(key(.keyDown, 36)), "NSEvent Return consumed")
	check(input.handleKeyEvent(key(.keyDown, 36)), "NSEvent repeat consumed")
	usleep(100_000)
	check(rx.last?.buttons == .cross, "NSEvent Return -> cross")
	check(input.handleKeyEvent(key(.keyUp, 36)), "NSEvent Return up consumed")
	usleep(100_000)
	check(rx.last == ControllerState.idle, "NSEvent key up releases")
	check(!input.handleKeyEvent(key(.keyDown, 40 + 100)), "unmapped key passes through")
	check(!input.handleKeyEvent(key(.keyDown, 36, .command)), "Cmd+Return passes through")
	check(!input.handleKeyEvent(key(.keyUp, 36)), "stray key up passes through")
	input.stop()
	input.stop()
	check(true, "stop twice")
}

selfTests()
print("self-tests: \(checks - failures)/\(checks) passed")
if failures > 0 { exit(1) }
if flag("selftest") { exit(0) }

// MARK: - Live part

func describe(_ s: ControllerState, motion: Bool) -> String {
	var parts: [String] = []
	let names: [(ControllerButtons, String)] = [
		(.cross, "X"), (.circle, "O"), (.square, "Sq"), (.triangle, "Tr"), (.dpadLeft, "←"), (.dpadRight, "→"), (.dpadUp, "↑"), (.dpadDown, "↓"),
		(.l1, "L1"), (.r1, "R1"), (.l3, "L3"), (.r3, "R3"), (.options, "OPT"), (.share, "CRE"), (.touchpad, "TPad"), (.ps, "PS"),
	]
	let b = names.filter { s.buttons.contains($0.0) }.map { $0.1 }
	parts.append("btn[\(b.joined(separator: " "))]")
	if s.l2 != 0 || s.r2 != 0 { parts.append("L2=\(s.l2) R2=\(s.r2)") }
	if s.leftX != 0 || s.leftY != 0 { parts.append("LS(\(s.leftX),\(s.leftY))") }
	if s.rightX != 0 || s.rightY != 0 { parts.append("RS(\(s.rightX),\(s.rightY))") }
	for (i, t) in [s.touch0, s.touch1].enumerated() where t.id >= 0 { parts.append("T\(i)#\(t.id)(\(t.x),\(t.y))") }
	if motion {
		parts.append(String(format: "gyro(%.2f %.2f %.2f) acc(%.2f %.2f %.2f) q(%.2f %.2f %.2f %.2f)",
							s.gyroX, s.gyroY, s.gyroZ, s.accelX, s.accelY, s.accelZ, s.orientX, s.orientY, s.orientZ, s.orientW))
	}
	return parts.joined(separator: " ")
}

final class Printer: ControllerStateReceiver {
	let motion: Bool
	var lastLine = ""
	var lastMotionPrint = Date.distantPast
	var count = 0
	let lock = NSLock()
	init(motion: Bool) { self.motion = motion }
	func controllerStateDidChange(_ s: ControllerState) {
		lock.lock(); defer { lock.unlock() }
		count += 1
		let line = describe(s, motion: false)
		if line != lastLine {
			lastLine = line
			print("[state] " + describe(s, motion: motion))
		} else if motion, Date().timeIntervalSince(lastMotionPrint) > 0.25 {
			lastMotionPrint = Date()
			print("[motion] " + describe(s, motion: true))
		}
	}
}

let seconds = Double(value("seconds") ?? "20") ?? 20
let app = NSApplication.shared
app.setActivationPolicy(flag("accessory") ? .accessory : .regular)

var window: NSWindow?
let input = ControllerInput()
input.allowBackgroundInput = flag("background")
let printer = Printer(motion: flag("motion"))

var bag = Set<AnyCancellable>()
input.$controllers.sink { list in
	print("[controllers] " + (list.isEmpty ? "none" : list.map { "#\($0.id) \($0.name) [\($0.kind.rawValue)\($0.hasMotion ? ", motion" : "")\($0.batteryLevel.map { ", battery \(Int($0 * 100))%" } ?? "")]" }.joined(separator: "; ")))
}.store(in: &bag)
input.$activeControllerID.sink { print("[active] \($0.map(String.init) ?? "none")") }.store(in: &bag)
input.$homeButtonStatus.sink { if !$0.isEmpty { print("[home button] \($0)") } }.store(in: &bag)

if flag("window") {
	let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 120), styleMask: [.titled, .closable], backing: .buffered, defer: false)
	w.title = "PlayStream input harness"
	let label = NSTextField(labelWithString: "Keys: arrows/Return/Esc/Q/E/1-6/O/P/T/`/WASD/IJKL")
	label.frame = NSRect(x: 12, y: 40, width: 396, height: 40)
	w.contentView?.addSubview(label)
	w.makeKeyAndOrderFront(nil)
	window = w
	input.installKeyboardMonitor()
}
app.finishLaunching()
app.activate()

input.receiver = printer
input.start()
// give GameController a moment to enumerate already-connected controllers
RunLoop.main.run(until: Date().addingTimeInterval(1.0))
print("[info] GCController.controllers() = \(GCController.controllers().count), app active = \(NSApp.isActive), policy = \(flag("accessory") ? "accessory" : "regular")")
print("[info] watching for \(Int(seconds)) s. Wake a DualSense (press PS) and press buttons. Ctrl-C to quit.")

signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigSrc.setEventHandler { input.stop(); print("[stop] silenced and released"); exit(0) }
sigSrc.resume()

if flag("rumble") {
	DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
		print("[test] rumble strong 220 / weak 0")
		input.controllerFeedbackRumble(left: 220, right: 0)
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
			print("[test] rumble strong 0 / weak 220")
			input.controllerFeedbackRumble(left: 0, right: 220)
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
				input.controllerFeedbackRumble(left: 0, right: 0)
				print("[test] rumble off")
			}
		}
	}
}
if flag("trigger") {
	DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
		// weapon effect, start zone 2, end zone 6, strength 8 (raw encoding: mask, strength-1)
		let mask: UInt16 = (1 << 2) | (1 << 6)
		let params: [UInt8] = [UInt8(mask & 0xff), UInt8(mask >> 8), 7, 0, 0, 0, 0, 0, 0, 0]
		print("[test] weapon trigger effect on both triggers")
		input.controllerFeedbackTriggerEffects(typeLeft: 0x25, paramsLeft: params, typeRight: 0x25, paramsRight: params)
		input.controllerFeedbackLED(red: 0, green: 80, blue: 255)
		DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
			input.controllerFeedbackTriggerEffects(typeLeft: 0x05, paramsLeft: [UInt8](repeating: 0, count: 10), typeRight: 0x05, paramsRight: [UInt8](repeating: 0, count: 10))
			print("[test] triggers off")
		}
	}
}
if flag("haptics") {
	input.hapticsToRumbleEnabled = true
	DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
		print("[test] haptics burst (3 kHz sine, 0.6 s) via PCM -> rumble")
		DispatchQueue.global().async {
			for packet in 0..<60 {
				var pcm = [Int16](repeating: 0, count: 60)
				for f in 0..<30 {
					let ph = Double(packet * 30 + f) / 3000 * 2 * Double.pi * 80
					let v = Int16(sin(ph) * 9000)
					pcm[2 * f] = v; pcm[2 * f + 1] = v
				}
				pcm.withUnsafeBufferPointer { input.hapticsStreamDidReceive(pcm: $0, frameCount: 30) }
				usleep(10_000)
			}
			print("[test] haptics burst done (stream stops; rumble must fall silent by itself)")
		}
	}
}

let end = Date().addingTimeInterval(seconds)
while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

input.stop()
print("[done] pushes seen: \(printer.count). Rumble/triggers silenced, controllers released.")
