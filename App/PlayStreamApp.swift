import PSCore
import SwiftUI

@main
struct PlayStreamApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var model = AppModel()

	var body: some Scene {
		Window("PlayStream", id: "main") {
			RootView(model: model)
				.onAppear { appDelegate.model = model }
		}
		.defaultSize(width: 1280, height: 760)
		.commands {
			CommandGroup(replacing: .newItem) {}
		}
	}
}

struct RootView: View {
	@ObservedObject var model: AppModel

	/// The window is showing (or about to show) a stream rather than the console list.
	private var presenting: Bool { model.stream != nil || model.reconnectStatus != nil }

	var body: some View {
		Group {
			if let stream = model.stream {
				StreamView(
					controller: stream, settings: model.settings, input: model.input,
					notice: model.pendingRelaunch.map { "Restarting to update when you pause for \(Int($0.idleSeconds.rounded())) s" },
					onDisconnect: { model.disconnect() }
				)
				.frame(minWidth: 640, minHeight: 360)
			} else if let status = model.reconnectStatus {
				ReconnectingView(status: status, onCancel: { model.cancelConnect() })
					.frame(minWidth: 640, minHeight: 360)
			} else {
				HomeView(model: model, discovery: model.discovery, store: model.store)
			}
		}
		.onChange(of: presenting) { _, isPresenting in
			syncFullScreen(presenting: isPresenting)
		}
		.task {
			// The window exists now: pick up the session of the previous run, if there is one.
			model.resumeIfNeeded()
		}
	}

	/// Enters full screen when a stream starts (if the setting, or the state a resumed session
	/// was left in, says so) and leaves it when the app goes back to the console list. Retries
	/// briefly when the window is not there yet, which happens when a session is resumed right
	/// at launch.
	private func syncFullScreen(presenting: Bool, attempt: Int = 0) {
		guard let window = AppModel.streamWindow else {
			guard attempt < 20 else { return }
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
				guard presenting == self.presenting else { return }
				syncFullScreen(presenting: presenting, attempt: attempt + 1)
			}
			return
		}
		let isFullScreen = window.styleMask.contains(.fullScreen)
		if presenting {
			let wanted = model.fullScreenOverride ?? model.settings.startFullscreen
			model.fullScreenOverride = nil
			if wanted, !isFullScreen { window.toggleFullScreen(nil) }
		} else if isFullScreen {
			window.toggleFullScreen(nil)
		}
	}
}

/// Shown while the app gets a session back by itself: at launch after a restart, on
/// `psctl reconnect`, and between attempts while the console still holds the old session.
struct ReconnectingView: View {
	let status: AppModel.ReconnectStatus
	let onCancel: () -> Void

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()
			VStack(spacing: 14) {
				ProgressView().controlSize(.large)
				Text(status.message).font(.title3)
				Button("Cancel", action: onCancel)
					.keyboardShortcut(.cancelAction)
			}
			.padding(28)
			.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		}
		.navigationTitle(status.consoleName)
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	var model: AppModel?
	private var terminating = false

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	/// Quitting in the middle of a session: close it properly first (see
	/// `AppModel.prepareForTermination`). Takes a moment, never more than a few seconds.
	func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
		MainActor.assumeIsolated {
			guard let model, model.needsGracefulTermination, !terminating else { return .terminateNow }
			terminating = true
			Task { @MainActor in
				await model.prepareForTermination()
				sender.reply(toApplicationShouldTerminate: true)
			}
			return .terminateLater
		}
	}

	func applicationWillTerminate(_ notification: Notification) {
		MainActor.assumeIsolated { model?.shutdown() }
	}
}
