import AppKit
import PSContracts
import SwiftUI
import WebKit

/// Sheet that obtains the 8 byte PSN account id, either by signing in to Sony (embedded web
/// view, or the system browser with a pasted redirect URL as chiaki-ng does on macOS) or by
/// typing the base64 id.
///
/// ```swift
/// .sheet(isPresented: $showAccount) { PSNAccountSheet(store: store) }
/// ```
public struct PSNAccountSheet: View {
	private let onComplete: (PSNAccount) -> Void
	private let onCancel: () -> Void
	@Environment(\.dismiss) private var dismiss
	@StateObject private var model = PSNAccountModel()

	/// Saves the account into `store` and dismisses.
	public init(store: HostStore, onComplete: @escaping (PSNAccount) -> Void = { _ in }, onCancel: @escaping () -> Void = {}) {
		self.onComplete = { account in
			store.setAccount(account)
			onComplete(account)
		}
		self.onCancel = onCancel
	}

	/// Hands the account to `onComplete` (nothing is saved) and dismisses.
	public init(onComplete: @escaping (PSNAccount) -> Void, onCancel: @escaping () -> Void = {}) {
		self.onComplete = onComplete
		self.onCancel = onCancel
	}

	public var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			Group {
				switch model.mode {
				case .signIn: signInPane
				case .browser: browserPane
				case .manual: manualPane
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			Divider()
			footer
		}
		.frame(minWidth: 520, idealWidth: 560, minHeight: model.mode == .signIn ? 680 : 360)
		.onChange(of: model.result) { _, account in
			guard let account else { return }
			onComplete(account)
			dismiss()
		}
	}

	private var header: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("PlayStation Network Account").font(.title2.bold())
			Text("Remote Play pairs this Mac with your PSN account. Use the same account that is signed in on the PS5.")
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Picker("Method", selection: $model.mode) {
				Text("Sign In").tag(PSNAccountModel.Mode.signIn)
				Text("Sign In with Browser").tag(PSNAccountModel.Mode.browser)
				Text("Enter Account ID").tag(PSNAccountModel.Mode.manual)
			}
			.pickerStyle(.segmented)
			.labelsHidden()
		}
		.padding(20)
	}

	private var footer: some View {
		HStack {
			if let error = model.error {
				Label {
					VStack(alignment: .leading, spacing: 2) {
						Text(error.message).fontWeight(.medium)
						if let hint = error.hint { Text(hint).foregroundStyle(.secondary) }
					}
					.fixedSize(horizontal: false, vertical: true)
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
				}
				.font(.callout)
			} else if model.isWorking {
				ProgressView().controlSize(.small)
				Text("Getting your account ID from Sony…").foregroundStyle(.secondary)
			}
			Spacer()
			Button("Cancel") {
				model.cancel()
				onCancel()
				dismiss()
			}
			.keyboardShortcut(.cancelAction)
			if model.mode == .browser {
				Button("Get Account ID") { model.submitPastedRedirect() }
					.keyboardShortcut(.defaultAction)
					.disabled(model.pastedRedirect.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
			} else if model.mode == .manual {
				Button("Save") { model.submitManual() }
					.keyboardShortcut(.defaultAction)
					.disabled(model.manualAccountID.isEmpty)
			}
		}
		.padding(16)
	}

	// MARK: Panes

	private var signInPane: some View {
		VStack(spacing: 0) {
			HStack(spacing: 8) {
				if model.webProgress < 1 {
					ProgressView(value: model.webProgress).progressViewStyle(.linear).frame(maxWidth: 200)
				}
				Spacer()
				Button("Start Over", systemImage: "arrow.clockwise") { model.restartWebLogin() }
					.help("Reload Sony's sign-in page and forget anything entered so far")
			}
			.padding(.horizontal, 16)
			.padding(.vertical, 8)
			if model.isWorking {
				VStack(spacing: 12) {
					ProgressView()
					Text("Signed in. Getting your account ID…").foregroundStyle(.secondary)
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				PSNLoginWebView(url: model.loginURL, reloadToken: model.webReloadToken, progress: $model.webProgress) { url in
					model.handleRedirect(url)
				}
			}
		}
	}

	private var browserPane: some View {
		Form {
			Section {
				Text("1. Open Sony's sign-in page in your browser and sign in.")
				HStack {
					Button("Open Sign-In Page") { model.openInBrowser() }
					Button("Copy Link") { model.copyLoginLink() }
				}
				Text("2. When the page shows \"redirect\", click the address bar (⌘L), copy the full address (⌘C) and paste it below.")
					.fixedSize(horizontal: false, vertical: true)
				TextField("Redirect address", text: $model.pastedRedirect, prompt: Text("https://remoteplay.dl.playstation.net/remoteplay/redirect?code=…"))
					.textFieldStyle(.roundedBorder)
					.onSubmit { model.submitPastedRedirect() }
			}
		}
		.formStyle(.grouped)
	}

	private var manualPane: some View {
		ManualAccountPane(model: model)
	}
}

private struct ManualAccountPane: View {
	@ObservedObject var model: PSNAccountModel
	@FocusState private var focused: Bool

	var body: some View {
		Form {
			Section {
				TextField("Account ID", text: $model.manualAccountID, prompt: Text("e.g. AbCdEfGhIjk="))
					.font(.body.monospaced())
					.focused($focused)
					.onSubmit { model.submitManual() }
			} footer: {
				Text("The base64 account ID shown by other Remote Play clients (12 characters, usually ending in \"=\"). A numeric PSN user ID also works. This is not your username / online ID.")
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.formStyle(.grouped)
		.onAppear { focused = true }
	}
}

// MARK: - Model

@MainActor
final class PSNAccountModel: ObservableObject {
	enum Mode: Hashable { case signIn, browser, manual }

	struct DisplayError: Equatable {
		var message: String
		var hint: String?
		init(_ error: Error) {
			message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
			hint = (error as? LocalizedError)?.recoverySuggestion
		}
	}

	@Published var mode: Mode = .signIn { didSet { if mode != oldValue { error = nil } } }
	@Published var result: PSNAccount?
	@Published var error: DisplayError?
	@Published var isWorking = false
	@Published var webProgress: Double = 0
	@Published var webReloadToken = 0
	@Published var pastedRedirect = ""
	@Published var manualAccountID = ""

	/// One device uid per sheet, shared by the embedded and the browser login (as chiaki-ng).
	private(set) var loginURL = PSNAuth.authorizeURL()
	private var exchangeTask: Task<Void, Never>?
	private var codeInFlight: String?

	func handleRedirect(_ url: URL) {
		do {
			let code = try PSNAuth.authorizationCode(fromRedirect: url)
			exchange(code: code)
		} catch {
			self.error = DisplayError(error)
		}
	}

	func submitPastedRedirect() {
		do {
			let code = try PSNAuth.authorizationCode(fromPastedText: pastedRedirect)
			exchange(code: code)
		} catch {
			self.error = DisplayError(error)
		}
	}

	func submitManual() {
		do {
			let id = try PSNAuth.parseAccountID(manualAccountID)
			result = PSNAccount(accountID: id)
		} catch {
			self.error = DisplayError(error)
		}
	}

	func restartWebLogin() {
		cancel()
		error = nil
		loginURL = PSNAuth.authorizeURL()
		webReloadToken += 1
	}

	func openInBrowser() {
		NSWorkspace.shared.open(loginURL)
	}

	func copyLoginLink() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(loginURL.absoluteString, forType: .string)
	}

	func cancel() {
		exchangeTask?.cancel()
		exchangeTask = nil
		codeInFlight = nil
		isWorking = false
	}

	private func exchange(code: String) {
		// Navigation callbacks can report the same redirect more than once; a code is single use.
		guard codeInFlight != code else { return }
		exchangeTask?.cancel()
		codeInFlight = code
		error = nil
		isWorking = true
		exchangeTask = Task { [weak self] in
			do {
				let account = try await PSNAuth.fetchAccount(authorizationCode: code)
				guard !Task.isCancelled else { return }
				self?.isWorking = false
				self?.result = account
			} catch {
				guard !Task.isCancelled else { return }
				self?.isWorking = false
				self?.codeInFlight = nil
				self?.error = DisplayError(error)
			}
		}
	}
}

// MARK: - Web view

/// Sony's login page in a WKWebView. Navigations to the redirect page are cancelled and
/// reported (chiaki-ng: `onNavigationRequested` + `checkPsnRedirectURL`). Uses a
/// non-persistent data store: no cookies or tokens are kept after the sheet closes.
struct PSNLoginWebView: NSViewRepresentable {
	let url: URL
	let reloadToken: Int
	@Binding var progress: Double
	let onRedirect: (URL) -> Void

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> WKWebView {
		let config = WKWebViewConfiguration()
		config.websiteDataStore = .nonPersistent()
		// Present as Safari rather than an anonymous embedded view (chiaki-ng likewise rewrites
		// its user agent to a current browser).
		config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
		let webView = WKWebView(frame: .zero, configuration: config)
		webView.navigationDelegate = context.coordinator
		webView.uiDelegate = context.coordinator
		webView.allowsBackForwardNavigationGestures = true
		context.coordinator.observe(webView)
		context.coordinator.loadedToken = reloadToken
		webView.load(URLRequest(url: url))
		return webView
	}

	func updateNSView(_ webView: WKWebView, context: Context) {
		context.coordinator.parent = self
		if context.coordinator.loadedToken != reloadToken {
			context.coordinator.loadedToken = reloadToken
			let store = webView.configuration.websiteDataStore
			store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
				webView.load(URLRequest(url: url))
			}
		}
	}

	static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
		webView.stopLoading()
		coordinator.progressObservation = nil
	}

	@MainActor
	final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
		var parent: PSNLoginWebView
		var loadedToken = 0
		var progressObservation: NSKeyValueObservation?
		private var reported = Set<String>()

		init(_ parent: PSNLoginWebView) { self.parent = parent }

		func observe(_ webView: WKWebView) {
			progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
				let value = view.estimatedProgress
				Task { @MainActor in self?.parent.progress = value }
			}
		}

		private func intercept(_ url: URL?) -> Bool {
			guard let url, PSNAuth.isRedirect(url) else { return false }
			if reported.insert(url.absoluteString).inserted {
				parent.onRedirect(url)
			}
			return true
		}

		func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
			decisionHandler(intercept(navigationAction.request.url) ? .cancel : .allow)
		}

		func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
			if intercept(webView.url) { webView.stopLoading() }
		}

		func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
			let failingURL = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
			_ = intercept(failingURL)
		}

		// Sony's page may try to open a popup; keep everything in this view.
		func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
			if !intercept(navigationAction.request.url) {
				webView.load(navigationAction.request)
			}
			return nil
		}
	}
}
