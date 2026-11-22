import CoreHaptics
import Foundation
import GameController

/// One vibration motor driven through a CHHapticEngine on a single GameController haptic locality.
/// A looping infinite-duration continuous event is started on demand and its intensity is changed with
/// dynamic parameters; it is stopped (not just set to 0) when the level drops to zero so an idle controller
/// does not keep a haptic player alive.
final class HapticMotor {
	private let engine: CHHapticEngine
	private let sharpness: Float
	private var player: CHHapticAdvancedPatternPlayer?
	private var level: Float = 0
	private let lock = NSLock()

	init?(controller: GCController, locality: GCHapticsLocality, sharpness: Float) {
		guard let engine = controller.haptics?.createEngine(withLocality: locality) else { return nil }
		self.engine = engine
		self.sharpness = sharpness
		engine.isAutoShutdownEnabled = true
		engine.stoppedHandler = { [weak self] _ in
			guard let self else { return }
			self.lock.lock(); self.player = nil; self.level = 0; self.lock.unlock()
		}
		engine.resetHandler = { [weak self] in
			guard let self else { return }
			self.lock.lock(); self.player = nil; self.level = 0; self.lock.unlock()
			try? self.engine.start()
		}
	}

	/// intensity 0...1
	func set(_ v: Float) {
		let v = max(0, min(1, v))
		lock.lock(); defer { lock.unlock() }
		if abs(v - level) < 0.008 && (v > 0) == (level > 0) { return }
		if v < 0.004 {
			if let p = player { try? p.stop(atTime: CHHapticTimeImmediate) }
			player = nil
			level = 0
			return
		}
		do {
			if let p = player {
				try p.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)], atTime: CHHapticTimeImmediate)
			} else {
				try engine.start()
				let event = CHHapticEvent(eventType: .hapticContinuous,
										  parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
													   CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)],
										  relativeTime: 0, duration: TimeInterval(GCHapticDurationInfinite))
				let pattern = try CHHapticPattern(events: [event],
												  parameters: [CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: v, relativeTime: 0)])
				let p = try engine.makeAdvancedPlayer(with: pattern)
				try p.start(atTime: CHHapticTimeImmediate)
				player = p
			}
			level = v
		} catch {
			player = nil
			level = 0
		}
	}

	func shutdown() {
		lock.lock()
		if let p = player { try? p.stop(atTime: CHHapticTimeImmediate) }
		player = nil
		level = 0
		lock.unlock()
		engine.stop(completionHandler: nil)
	}
}

/// Strong (left) / weak (right) rumble for one controller. Uses the left/right handle actuators when the
/// controller exposes them, else a single default-locality motor driven by the stronger of the two.
final class HapticRumble {
	private var left: HapticMotor?
	private var right: HapticMotor?
	private var single: HapticMotor?
	let hasSeparateMotors: Bool

	init?(controller: GCController) {
		guard let haptics = controller.haptics else { return nil }
		let locs = haptics.supportedLocalities
		if locs.contains(.leftHandle), locs.contains(.rightHandle) {
			// Left = low frequency / strong -> low sharpness; right = high frequency / weak -> high sharpness.
			left = HapticMotor(controller: controller, locality: .leftHandle, sharpness: 0.15)
			right = HapticMotor(controller: controller, locality: .rightHandle, sharpness: 0.9)
		}
		if left != nil && right != nil {
			hasSeparateMotors = true
		} else {
			left = nil; right = nil
			single = HapticMotor(controller: controller, locality: .default, sharpness: 0.5)
			hasSeparateMotors = false
			if single == nil { return nil }
		}
	}

	func set(left l: Float, right r: Float) {
		if hasSeparateMotors {
			left?.set(l)
			right?.set(r)
		} else {
			single?.set(max(l, r))
		}
	}

	func shutdown() {
		left?.shutdown(); right?.shutdown(); single?.shutdown()
		left = nil; right = nil; single = nil
	}
}
