import Foundation
import PSContracts
import PSCore

/// The app's end of the control channel: the socket server, the command router, and the hooks
/// that let commands reach the running app. Everything a command needs from the app is fetched
/// with a short hop to the main actor; the server itself, the file work of the commands and the
/// waiting all happen elsewhere, so a command never holds the main thread or a stream thread.
///
/// On by default; the "debug.controlChannel" setting turns it off.
@MainActor
final class DebugControl {
	let storage = DebugStorage()
	private let router: ControlRouter
	private let server: ControlServer
	private var announcedFailure = false

	init(model: AppModel) {
		let router = ControlRouter(defaults: .standard, storage: storage)
		self.router = router
		server = ControlServer { request in await router.handle(request) }

		var hooks = ControlRouter.Hooks()
		hooks.status = { [weak model] in
			await MainActor.run { model?.statusJSON() ?? [:] }
		}
		hooks.stats = { [weak model] in
			await MainActor.run { model?.statsJSON() ?? [:] }
		}
		hooks.sessionActive = { [weak model] in
			await MainActor.run { model?.stream != nil }
		}
		hooks.videoDebug = { [weak model] in
			await MainActor.run { model?.stream?.videoDebug }
		}
		hooks.flightRecorder = { [weak model] in
			await MainActor.run { model?.flightRecorder }
		}
		hooks.applySettings = { [weak model] write in
			// Store and apply in one step on the main thread, like the settings panel does. The
			// change notification the store posts is handled a moment later and then finds
			// everything already applied, so what is reported here is the complete effect.
			try await MainActor.run {
				let keys = try write()
				return model?.settingsChangedByControlChannel(keys) ?? []
			}
		}
		hooks.record = { [weak model] action in
			guard let stream = await MainActor.run(body: { model?.stream }) else { throw ControlError("no session is running") }
			return try await stream.record(action)
		}
		hooks.reconnect = { [weak model] allowWake in
			try await MainActor.run {
				guard let model else { throw ControlError("the app is shutting down") }
				return try model.reconnect(allowWake: allowWake)
			}
		}
		hooks.disconnect = { [weak model] in
			try await MainActor.run {
				guard let model else { throw ControlError("the app is shutting down") }
				guard model.stream != nil || model.connectingHostID != nil else { throw ControlError("no session is running") }
				CoreLog.note("Disconnect requested via control channel")
				model.disconnect()
				return ["disconnected": true]
			}
		}
		hooks.relaunch = { [weak model] request in
			try await MainActor.run {
				guard let model else { throw ControlError("the app is shutting down") }
				return try model.requestRelaunch(request)
			}
		}
		router.hooks = hooks

		// Old captures and traces are trimmed at launch, off the main thread.
		let storage = self.storage
		let limit = Int64(SettingsCatalog.int("debug.maxDiskMegabytes", in: .standard)) * 1024 * 1024
		DispatchQueue.global(qos: .utility).async {
			let result = storage.cleanup(maxBytes: limit)
			if result.removedItems > 0 {
				CoreLog.note("Debug directory: removed \(result.removedItems) old items (\(result.freedBytes / 1_048_576) MiB), \(result.remainingBytes / 1_048_576) MiB left")
			}
		}
	}

	var isRunning: Bool { server.isRunning }

	/// Starts or stops the server to match the setting. Returns a description when that changed
	/// something.
	@discardableResult
	func setEnabled(_ enabled: Bool) -> String? {
		if enabled, !server.isRunning {
			do {
				try server.start()
				announcedFailure = false
				CoreLog.note("Control channel listening at \(server.socketURL.path)")
				return "control channel on"
			} catch {
				// Say it once, not every time the settings are applied.
				if !announcedFailure { CoreLog.note("Control channel could not start: \(error.localizedDescription)") }
				announcedFailure = true
				return nil
			}
		}
		if !enabled, server.isRunning {
			server.stop()
			CoreLog.note("Control channel closed (turned off in the settings)")
			return "control channel off"
		}
		return nil
	}

	/// Closes the socket (quit, or handing over to a new instance).
	func stop() {
		server.stop()
	}
}
