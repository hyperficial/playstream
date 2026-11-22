import AppKit
import PSContracts
import PSPairing
import SwiftUI
import WebKit

/// Renders the pairing UI offscreen to PNGs (for checking layout without the app shell).
@MainActor
func renderUI(to directory: URL, storeDir: URL?) async {
	_ = NSApplication.shared
	NSApp.setActivationPolicy(.prohibited)
	try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

	let store = HostStore(directory: storeDir)
	let discovery = DiscoveryService()
	discovery.start()
	_ = await discovery.waitForHost(timeout: 3) { _ in true }

	func snapshot<V: View>(_ view: V, size: CGSize, name: String, settle: Double = 1.0) async {
		let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
		let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
		host.frame = CGRect(origin: .zero, size: size)
		window.contentView = host
		window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
		window.orderBack(nil)
		try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
		host.layoutSubtreeIfNeeded()
		guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
		host.cacheDisplay(in: host.bounds, to: rep)
		let url = directory.appendingPathComponent("\(name).png")
		try? rep.representation(using: .png, properties: [:])?.write(to: url)
		print("wrote \(url.path)")
		window.orderOut(nil)
	}

	await snapshot(PairingSheet(discovery: discovery, store: store), size: CGSize(width: 520, height: 640), name: "pairing-sheet")
	await snapshot(PSNAccountSheet(store: store), size: CGSize(width: 560, height: 720), name: "account-sheet-signin", settle: 4)
	discovery.stop()

	// Sony's login page in a WKWebView configured like PSNLoginWebView.
	let config = WKWebViewConfiguration()
	config.websiteDataStore = .nonPersistent()
	config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
	let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 520, height: 640), configuration: config)
	let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
	window.contentView = web
	window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
	window.orderBack(nil)
	web.load(URLRequest(url: PSNAuth.authorizeURL()))
	for _ in 0 ..< 60 {
		try? await Task.sleep(nanoseconds: 250_000_000)
		if !web.isLoading, web.url?.host == "my.account.sony.com" { break }
	}
	try? await Task.sleep(nanoseconds: 10_000_000_000) // let the sign-in SPA render
	let host = web.url.map { "\($0.host ?? "")\($0.path)" } ?? "nil"
	print("web view landed on: \(host), title: \(web.title ?? "")")
	let probe = "JSON.stringify({ready: document.readyState, scripts: document.scripts.length, html: document.documentElement.outerHTML.length, hidden: document.hidden, inputs: Array.from(document.querySelectorAll('input')).map(i => i.type + ':' + (i.name || i.id)).slice(0, 6), text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 160)})"
	if let result = try? await web.evaluateJavaScript(probe) as? String { print("page: \(result)") }
	if let image = try? await web.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
	   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
		let url = directory.appendingPathComponent("sony-login.png")
		try? png.write(to: url)
		print("wrote \(url.path)")
	}
	window.orderOut(nil)
}
