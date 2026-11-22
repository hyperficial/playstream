import PSCore
import SwiftUI

@main
struct PlayStreamApp: App {
	init() {
		CoreLog.install()
	}

	var body: some Scene {
		WindowGroup {
			Text("PlayStream")
				.frame(minWidth: 960, minHeight: 540)
		}
	}
}
