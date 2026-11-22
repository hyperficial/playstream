import Foundation
import PSContracts

/// Keyboard fallback mapping. Uses macOS virtual key codes (physical key positions, layout independent).
///
///   Arrow keys          d-pad
///   Return / keypad Enter   cross          Escape / Delete(Backspace)   circle
///   Q                   square             E                            triangle
///   1  2  3  4          L1  L2  R2  R1     5 / 6                        L3 / R3
///   O                   options            P                            create (share)
///   T                   touchpad click     ` (grave) or H               PS button
///   W A S D             left stick         I J K L                      right stick
public enum KeyboardMapping {
	public static let buttonKeys: [UInt16: ControllerButtons] = [
		36: .cross, 76: .cross,
		53: .circle, 51: .circle,
		12: .square,
		14: .triangle,
		123: .dpadLeft, 124: .dpadRight, 126: .dpadUp, 125: .dpadDown,
		18: .l1, 21: .r1,
		23: .l3, 22: .r3,
		31: .options,
		35: .share,
		17: .touchpad,
		50: .ps, 4: .ps,
	]
	/// L2 / R2 (analog triggers pressed fully).
	public static let l2Key: UInt16 = 19
	public static let r2Key: UInt16 = 20

	// Left stick W A S D, right stick I J K L (up, left, down, right).
	public static let leftStick: (up: UInt16, left: UInt16, down: UInt16, right: UInt16) = (13, 0, 1, 2)
	public static let rightStick: (up: UInt16, left: UInt16, down: UInt16, right: UInt16) = (34, 38, 40, 37)

	public static func isMapped(_ keyCode: UInt16) -> Bool {
		if buttonKeys[keyCode] != nil || keyCode == l2Key || keyCode == r2Key { return true }
		for k in [leftStick, rightStick] where [k.up, k.left, k.down, k.right].contains(keyCode) { return true }
		return false
	}

	/// ControllerState produced by a set of held keys.
	public static func state(pressed: Set<UInt16>) -> ControllerState {
		var s = ControllerState()
		for k in pressed {
			if let b = buttonKeys[k] { s.buttons.insert(b) }
		}
		if pressed.contains(l2Key) { s.l2 = 255 }
		if pressed.contains(r2Key) { s.r2 = 255 }
		func axis(_ k: (up: UInt16, left: UInt16, down: UInt16, right: UInt16)) -> (Int16, Int16) {
			var x = 0, y = 0
			if pressed.contains(k.left) { x -= 1 }
			if pressed.contains(k.right) { x += 1 }
			if pressed.contains(k.up) { y -= 1 }      // protocol: positive y is DOWN
			if pressed.contains(k.down) { y += 1 }
			let scale: Float = (x != 0 && y != 0) ? 0.70710678 : 1
			return (InputMapping.stick(Float(x) * scale), InputMapping.stick(Float(y) * scale))
		}
		(s.leftX, s.leftY) = axis(leftStick)
		(s.rightX, s.rightY) = axis(rightStick)
		return s
	}
}
