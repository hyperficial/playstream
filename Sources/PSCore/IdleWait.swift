import Foundation

/// Waits for the player to stop touching the controller, so something disruptive (swapping in
/// a new build) can happen in a pause instead of in the middle of the action.
///
/// Polls an idle-time source a few times a second on the queue it is given and reports exactly
/// once: the controller has been idle for the required time, the wait timed out, or it was
/// cancelled.
public final class IdleWait: @unchecked Sendable {
	public enum Outcome: Equatable, Sendable {
		case idle(waitedSeconds: Double)
		case timedOut
		case cancelled
	}

	public let requiredIdleSeconds: Double
	public let timeoutSeconds: Double
	public let startedAt = Date()

	private let queue: DispatchQueue
	private let idleSeconds: () -> Double
	private var completion: ((Outcome) -> Void)?
	private var timer: DispatchSourceTimer?
	private let lock = NSLock()

	/// - Parameters:
	///   - idleSeconds: how long the controls have been at rest (`ControllerActivityMonitor.idleSeconds`).
	///   - queue: where polling happens and `completion` is called.
	public init(requiredIdleSeconds: Double, timeoutSeconds: Double, pollInterval: Double = 0.25, queue: DispatchQueue, idleSeconds: @escaping () -> Double, completion: @escaping (Outcome) -> Void) {
		self.requiredIdleSeconds = requiredIdleSeconds
		self.timeoutSeconds = timeoutSeconds
		self.queue = queue
		self.idleSeconds = idleSeconds
		self.completion = completion

		let timer = DispatchSource.makeTimerSource(queue: queue)
		timer.schedule(deadline: .now(), repeating: pollInterval, leeway: .milliseconds(20))
		timer.setEventHandler { [weak self] in self?.poll() }
		self.timer = timer
		timer.resume()
	}

	deinit { timer?.cancel() }

	/// Seconds until the wait gives up.
	public var remainingSeconds: Double { max(0, timeoutSeconds - Date().timeIntervalSince(startedAt)) }

	public var isPending: Bool {
		lock.lock()
		defer { lock.unlock() }
		return completion != nil
	}

	public func cancel() { finish(.cancelled) }

	private func poll() {
		let waited = Date().timeIntervalSince(startedAt)
		if idleSeconds() >= requiredIdleSeconds {
			finish(.idle(waitedSeconds: waited))
		} else if waited >= timeoutSeconds {
			finish(.timedOut)
		}
	}

	private func finish(_ outcome: Outcome) {
		lock.lock()
		let completion = self.completion
		self.completion = nil
		let timer = self.timer
		self.timer = nil
		lock.unlock()
		timer?.cancel()
		guard let completion else { return }
		queue.async { completion(outcome) }
	}
}
