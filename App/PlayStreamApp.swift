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

	var body: some View {
		Group {
			if let stream = model.stream {
				StreamView(controller: stream, settings: model.settings, input: model.input, onDisconnect: { model.disconnect() })
					.frame(minWidth: 640, minHeight: 360)
			} else {
				HomeView(model: model, discovery: model.discovery, store: model.store)
			}
		}
		.onChange(of: model.stream == nil) { _, isHome in
			guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) ?? NSApp.keyWindow else { return }
			let isFullScreen = window.styleMask.contains(.fullScreen)
			if !isHome, model.settings.startFullscreen, !isFullScreen {
				window.toggleFullScreen(nil)
			} else if isHome, isFullScreen {
				window.toggleFullScreen(nil)
			}
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	var model: AppModel?

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

	func applicationWillTerminate(_ notification: Notification) {
		MainActor.assumeIsolated { model?.shutdown() }
	}
}
