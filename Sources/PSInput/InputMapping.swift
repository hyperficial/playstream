import Foundation
import PSContracts

// Pure conversion helpers between the GameController framework's conventions and the protocol's
// ControllerState conventions (which mirror chiaki-ng / SDL). No framework objects in here, so
// everything is unit-checkable from the harness.

// MARK: - Sticks, triggers, touchpad

public enum InputMapping {
	/// GameController stick/axis value -1...1 -> protocol Int16 (-32768...32767), sign preserved.
	public static func stick(_ v: Float) -> Int16 {
		if v.isNaN { return 0 }
		let c = max(-1, min(1, v))
		return c < 0 ? Int16((c * 32768).rounded()) : Int16((c * 32767).rounded())
	}

	/// GameController y axes are positive UP; the protocol (SDL) is positive DOWN. Invert here.
	public static func stickY(_ gcY: Float) -> Int16 { stick(-gcY) }

	/// Analog trigger 0...1 -> 0...255.
	public static func trigger(_ v: Float) -> UInt8 {
		if v.isNaN { return 0 }
		return UInt8((max(0, min(1, v)) * 255).rounded())
	}

	public static let touchpadMaxX: Float = 1919
	public static let touchpadMaxY: Float = 1078

	/// GameController touchpad directional-pad values (-1...1, y positive UP) -> DualSense touchpad space
	/// (x 0...1919, y 0...1078, origin top-left). Same mapping SDL's MFi backend feeds chiaki:
	/// nx = (1 + x) / 2, ny = 1 - (1 + y) / 2.
	public static func touchpadPoint(x: Float, y: Float) -> (x: UInt16, y: UInt16) {
		let nx = max(0, min(1, (1 + x) * 0.5))
		let ny = max(0, min(1, 1 - (1 + y) * 0.5))
		return (UInt16((nx * touchpadMaxX).rounded()), UInt16((ny * touchpadMaxY).rounded()))
	}

	/// GameController gives no "finger down" flag for the DualSense touchpad: a finger is down iff the
	/// pad is not exactly (0, 0) (this is what SDL's MFi backend does too). Released = (0, 0).
	public static func isFingerDown(x: Float, y: Float) -> Bool { x != 0 || y != 0 }
}

// MARK: - Touch id allocation (port of chiaki_controller_state_start/stop_touch)

public struct TouchTracker {
	public private(set) var touchIdNext: UInt8 = 0
	public private(set) var slot0: ControllerTouch = .none
	public private(set) var slot1: ControllerTouch = .none
	/// physical finger (0 primary, 1 secondary) -> protocol slot index
	private var fingerSlot: [Int?] = [nil, nil]

	public init() {}

	public mutating func reset() {
		self = TouchTracker()
	}

	private func slot(_ i: Int) -> ControllerTouch { i == 0 ? slot0 : slot1 }
	private mutating func setSlot(_ i: Int, _ t: ControllerTouch) { if i == 0 { slot0 = t } else { slot1 = t } }

	/// Feed the state of one physical finger. Starts a touch (new id) on a down edge, moves it while down, ends it on up.
	public mutating func update(finger: Int, down: Bool, x: UInt16, y: UInt16) {
		guard finger >= 0, finger < 2 else { return }
		if down {
			if let s = fingerSlot[finger] {
				setSlot(s, ControllerTouch(x: x, y: y, id: slot(s).id))
			} else if let free = [0, 1].first(where: { slot($0).id < 0 }) {
				let id = Int8(touchIdNext)
				touchIdNext = (touchIdNext &+ 1) & 0x7f
				setSlot(free, ControllerTouch(x: x, y: y, id: id))
				fingerSlot[finger] = free
			}
			// else: both slots busy, ignore this finger (same as chiaki)
		} else if let s = fingerSlot[finger] {
			setSlot(s, .none)
			fingerSlot[finger] = nil
		}
	}

	public func apply(to state: inout ControllerState) {
		state.touchIdNext = touchIdNext
		state.touch0 = slot0
		state.touch1 = slot1
	}
}

// MARK: - Motion (ALL axis / sign / unit conversion lives here)

/// One axis remap: output[i] = sign[i] * input[source[i]].
public struct AxisRemap: Equatable {
	public var source: [Int]
	public var sign: [Float]
	public init(source: [Int], sign: [Float]) {
		self.source = source
		self.sign = sign
	}
	public func apply(_ v: (Double, Double, Double)) -> SIMD3<Float> {
		let a = [Float(v.0), Float(v.1), Float(v.2)]
		return SIMD3<Float>(sign[0] * a[source[0]], sign[1] * a[source[1]], sign[2] * a[source[2]])
	}
}

/// =====================================================================================
/// MOTION AXIS CONVENTIONS: the one place to fix signs if live testing shows an axis is flipped.
///
/// Derivation (not verified on hardware): chiaki-ng gets motion from SDL, whose standard frame is
/// +X right, +Y up, +Z toward the player, gyro in rad/s (right-hand), accel in m/s^2 with a
/// controller lying flat reading +Y. chiaki divides accel by 9.80665 to get g and passes gyro through.
/// SDL's own GameController-framework backend (SDL_mfijoystick.m) converts GCMotion into that frame as
///     gyro  = (rate.x,   rate.z,  -rate.y)
///     accel = (-acc.x,  -acc.y,  -acc.z) * 9.80665      (acc = GCMotion.acceleration, in g)
/// We reuse exactly that, so GC -> SDL -> chiaki conventions chain correctly.
/// If, live, an axis of motion control feels inverted, flip the matching sign below.
/// =====================================================================================
public enum MotionAxisMapping {
	/// GCMotion.rotationRate (rad/s) -> protocol gyro (rad/s).
	public static var gyro = AxisRemap(source: [0, 2, 1], sign: [1, 1, -1])
	/// GCMotion.acceleration (g) -> protocol accel (g).
	public static var accel = AxisRemap(source: [0, 1, 2], sign: [-1, -1, -1])

	public static func convert(gcRotationRate: (Double, Double, Double), gcAcceleration: (Double, Double, Double))
		-> (gyro: SIMD3<Float>, accel: SIMD3<Float>) {
		(gyro.apply(gcRotationRate), accel.apply(gcAcceleration))
	}
}

// MARK: - Orientation (port of chiaki lib/src/orientation.c: Madgwick IMU filter + tracker)

public struct MadgwickOrientation {
	// Quaternion in Madgwick's frame (w, x, y, z).
	public var w: Float, x: Float, y: Float, z: Float

	public init() {
		// 90 deg rotation around x for Madgwick
		x = Float(0.7071067811865475)
		y = 0
		z = 0
		w = Float(0.7071067811865476)
	}

	static let orientFuzz: Float = 0.0007
	static let fuzzPrevWeight: Float = 0.75
	static let fuzzPrevWeight2x: Float = 0.6

	public mutating func update(gx: Float, gy: Float, gz: Float, ax axIn: Float, ay ayIn: Float, az azIn: Float, beta: Float, dt: Float) {
		var ax = axIn, ay = ayIn, az = azIn
		let q0 = w, q1 = x, q2 = y, q3 = z
		var qDot1 = 0.5 * (-q1 * gx - q2 * gy - q3 * gz)
		var qDot2 = 0.5 * (q0 * gx + q2 * gz - q3 * gy)
		var qDot3 = 0.5 * (q0 * gy - q1 * gz + q3 * gx)
		var qDot4 = 0.5 * (q0 * gz + q1 * gy - q2 * gx)

		if !(ax == 0 && ay == 0 && az == 0) {
			var recip = 1 / (ax * ax + ay * ay + az * az).squareRoot()
			ax *= recip; ay *= recip; az *= recip
			let _2q0 = 2 * q0, _2q1 = 2 * q1, _2q2 = 2 * q2, _2q3 = 2 * q3
			let _4q0 = 4 * q0, _4q1 = 4 * q1, _4q2 = 4 * q2
			let _8q1 = 8 * q1, _8q2 = 8 * q2
			let q0q0 = q0 * q0, q1q1 = q1 * q1, q2q2 = q2 * q2, q3q3 = q3 * q3
			var s0 = _4q0 * q2q2 + _2q2 * ax + _4q0 * q1q1 - _2q1 * ay
			var s1 = _4q1 * q3q3 - _2q3 * ax + 4 * q0q0 * q1 - _2q0 * ay - _4q1 + _8q1 * q1q1 + _8q1 * q2q2 + _4q1 * az
			var s2 = 4 * q0q0 * q2 + _2q0 * ax + _4q2 * q3q3 - _2q3 * ay - _4q2 + _8q2 * q1q1 + _8q2 * q2q2 + _4q2 * az
			var s3 = 4 * q1q1 * q3 - _2q1 * ax + 4 * q2q2 * q3 - _2q2 * ay
			recip = s0 * s0 + s1 * s1 + s2 * s2 + s3 * s3
			if recip > 0.000001 {
				recip = 1 / recip.squareRoot()
				s0 *= recip; s1 *= recip; s2 *= recip; s3 *= recip
				qDot1 -= beta * s0
				qDot2 -= beta * s1
				qDot3 -= beta * s2
				qDot4 -= beta * s3
			}
		}

		var n0 = q0 + qDot1 * dt
		var n1 = q1 + qDot2 * dt
		var n2 = q2 + qDot3 * dt
		var n3 = q3 + qDot4 * dt
		let r = 1 / (n0 * n0 + n1 * n1 + n2 * n2 + n3 * n3).squareRoot()
		n0 *= r; n1 *= r; n2 *= r; n3 *= r

		Self.fuzz(n0, &w)
		Self.fuzz(n1, &x)
		Self.fuzz(n2, &y)
		Self.fuzz(n3, &z)
	}

	private static func fuzz(_ cur: Float, _ prev: inout Float) {
		let f = orientFuzz
		if cur < prev + f / 2 && cur > prev - f / 2 { return }
		if cur < prev + f && cur > prev - f { prev = fuzzPrevWeight * prev + (1 - fuzzPrevWeight) * cur; return }
		if cur < prev + f * 2 && cur > prev - f * 2 { prev = fuzzPrevWeight2x * prev + (1 - fuzzPrevWeight2x) * cur; return }
		prev = cur
	}
}

/// Port of ChiakiOrientationTracker + ChiakiAccelNewZero. Fed with motion already converted to the
/// protocol/SDL convention (see MotionAxisMapping); produces gyro/accel/orientation for ControllerState.
public struct OrientationTracker {
	static let warmupSamples: UInt64 = 30
	static let betaWarmup: Float = 20
	static let betaDefault: Float = 0.05

	public private(set) var gyro = SIMD3<Float>(0, 0, 0)
	public private(set) var accel = SIMD3<Float>(0, 1, 0)
	public private(set) var orient = MadgwickOrientation()
	private var lastTime: Double = 0
	private var sampleIndex: UInt64 = 0
	/// Offset subtracted from accel (set by `resetReference`), like chiaki's accel_zero.
	private var accelZero = SIMD3<Float>(0, 0, 0)
	/// Last raw (un-zeroed) accel and gyro, for resetReference.
	public private(set) var realAccel = SIMD3<Float>(0, 1, 0)

	public init() {}

	/// - Parameter time: monotonic seconds.
	public mutating func update(gyro g: SIMD3<Float>, accel a: SIMD3<Float>, time: Double) {
		realAccel = a
		gyro = g
		accel = a - accelZero
		sampleIndex += 1
		if sampleIndex <= 1 {
			lastTime = time
			return
		}
		let dt = Float(time - lastTime)
		lastTime = time
		guard dt > 0, dt < 0.5 else { return }
		orient.update(gx: g.x, gy: g.y, gz: g.z, ax: accel.x, ay: accel.y, az: accel.z,
					  beta: sampleIndex < Self.warmupSamples ? Self.betaWarmup : Self.betaDefault, dt: dt)
	}

	/// The game asked to reset the motion reference: current pose becomes "level" (accel (0,1,0)), orientation restarts.
	public mutating func resetReference(time: Double) {
		let g = gyro
		let r = realAccel
		accelZero = SIMD3<Float>(r.x, r.y - 1, r.z)
		orient = MadgwickOrientation()
		sampleIndex = 0
		update(gyro: g, accel: r, time: time)
	}

	public func apply(to state: inout ControllerState) {
		state.gyroX = gyro.x; state.gyroY = gyro.y; state.gyroZ = gyro.z
		state.accelX = accel.x; state.accelY = accel.y; state.accelZ = accel.z
		// -90 deg rotation around x from Madgwick (chiaki_orientation_tracker_apply_to_controller_state)
		let c = Float(0.7071067811865476)   // cos(-pi/4)
		let s = Float(-0.7071067811865475)  // sin(-pi/4)
		state.orientW = c * orient.w - s * orient.x
		state.orientX = c * orient.x + s * orient.w
		state.orientY = c * orient.y - s * orient.z
		state.orientZ = c * orient.z + s * orient.y
	}
}

// MARK: - Merging pad + keyboard

public enum StateMerge {
	/// Union of controller and keyboard state: buttons OR, triggers max, sticks largest magnitude.
	/// Touch and motion come from the controller only.
	public static func merged(pad: ControllerState, keyboard k: ControllerState) -> ControllerState {
		var o = pad
		o.buttons.formUnion(k.buttons)
		o.l2 = max(pad.l2, k.l2)
		o.r2 = max(pad.r2, k.r2)
		o.leftX = maxAbs(pad.leftX, k.leftX)
		o.leftY = maxAbs(pad.leftY, k.leftY)
		o.rightX = maxAbs(pad.rightX, k.rightX)
		o.rightY = maxAbs(pad.rightY, k.rightY)
		return o
	}
	private static func maxAbs(_ a: Int16, _ b: Int16) -> Int16 {
		Int32(a).magnitude >= Int32(b).magnitude ? a : b
	}
}

// MARK: - Rumble mixing (explicit console rumble vs haptics-derived rumble)

public struct RumbleMixer {
	public var explicitLeft: UInt8 = 0
	public var explicitRight: UInt8 = 0
	public var hapticsLeft: Float = 0
	public var hapticsRight: Float = 0
	public var hapticsEnabled = false
	public init() {}

	/// Motor intensities 0...1 (left = strong/low-frequency, right = weak/high-frequency).
	/// Explicit rumble events always win: while either explicit motor is non-zero the haptics-derived
	/// approximation is ignored completely (no summing, no fighting).
	public var output: (left: Float, right: Float) {
		if explicitLeft != 0 || explicitRight != 0 {
			return (Float(explicitLeft) / 255, Float(explicitRight) / 255)
		}
		if hapticsEnabled {
			return (max(0, min(1, hapticsLeft)), max(0, min(1, hapticsRight)))
		}
		return (0, 0)
	}
}

public enum HapticsEnvelope {
	/// Mean absolute amplitude per channel of an interleaved stereo Int16 buffer, scaled like chiaki-ng's
	/// rumble approximation (mean|x| * 2, so 1.0 = half scale average), clamped to 0...1.
	public static func levels(pcm: UnsafeBufferPointer<Int16>, frameCount: Int) -> (left: Float, right: Float) {
		let frames = min(frameCount, pcm.count / 2)
		guard frames > 0 else { return (0, 0) }
		var l: UInt64 = 0, r: UInt64 = 0
		for i in 0..<frames {
			l += UInt64(Int32(pcm[2 * i]).magnitude)
			r += UInt64(Int32(pcm[2 * i + 1]).magnitude)
		}
		let n = Float(frames) * 32768
		return (min(1, Float(l) * 2 / n), min(1, Float(r) * 2 / n))
	}
}
