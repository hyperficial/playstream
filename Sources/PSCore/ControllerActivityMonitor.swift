import Darwin
import Foundation
import os
import PSContracts

/// Watches the controller snapshots on their way to the session and remembers when the player
/// last did something, without changing what is sent.
///
/// Use it as the input module's receiver and point `downstream` at the session:
///
///     monitor.downstream = session
///     input.receiver = monitor        // weak in the input module: keep the monitor alive yourself
///
/// "Idle" means every control is at rest (no button held, triggers released, sticks centred,
/// no finger on the touchpad) and has been for a while. Motion sensor values are ignored: they
/// change constantly while the controller is merely being held.
public final class ControllerActivityMonitor: ControllerStateReceiver, @unchecked Sendable {
	public weak var downstream: ControllerStateReceiver?

	/// Stick deflection below this fraction of full scale counts as centred (worn sticks drift).
	public static let stickDeadzone: Int = 8192 // 25 %
	/// Trigger travel below this counts as released (0...255).
	public static let triggerDeadzone: UInt8 = 24

	private struct State {
		var atRest = true
		/// When the controls last were not at rest, or last changed.
		var lastActivityNs: UInt64
		var snapshots = 0
	}

	private let state: OSAllocatedUnfairLock<State>

	public init() {
		state = OSAllocatedUnfairLock(initialState: State(lastActivityNs: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)))
	}

	public func controllerStateDidChange(_ controllerState: ControllerState) {
		// Forward first: watching must not add anything to the input path.
		downstream?.controllerStateDidChange(controllerState)
		let atRest = Self.isAtRest(controllerState)
		let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
		state.withLock { s in
			s.snapshots += 1
			// Leaving rest, staying active and returning to rest are all activity; only a
			// snapshot that is at rest after one that was at rest (sensor noise) is not.
			if !atRest || !s.atRest { s.lastActivityNs = now }
			s.atRest = atRest
		}
	}

	/// Seconds since the player last touched a control. 0 while anything is held.
	public var idleSeconds: Double {
		let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
		return state.withLock { s in
			guard s.atRest, now > s.lastActivityNs else { return 0 }
			return Double(now - s.lastActivityNs) / 1e9
		}
	}

	/// Controller snapshots seen so far.
	public var snapshotCount: Int { state.withLock { $0.snapshots } }

	/// Declares the player active right now (e.g. a key press handled outside the controller path).
	public func noteActivity() {
		let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
		state.withLock { $0.lastActivityNs = now }
	}

	public static func isAtRest(_ s: ControllerState) -> Bool {
		guard s.buttons.isEmpty, s.l2 < triggerDeadzone, s.r2 < triggerDeadzone else { return false }
		guard s.touch0.id < 0, s.touch1.id < 0 else { return false }
		for axis in [s.leftX, s.leftY, s.rightX, s.rightY] where abs(Int(axis)) > stickDeadzone { return false }
		return true
	}
}
