import Foundation
import PSContracts
import Security

/// Sony's own OAuth flow for the PS Remote Play client, mirroring vendor/chiaki-ng
/// (gui/include/psnaccountid.h, gui/src/psnaccountid.cpp, gui/src/qmlbackend.cpp `psnLoginUrl`).
///
/// Only Sony endpoints are contacted. Tokens, the authorization code and the account id are
/// never logged.
public enum PSNAuth {
	/// Client credentials of the official PS Remote Play Windows client (as used by chiaki-ng).
	public static let clientID = "ba495a24-818c-472b-b12d-ff231c1b5745"
	static let clientSecret = "mvaiZkRsAsI1IBkY"

	public static let redirectURI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
	public static let authorizeEndpoint = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/authorize"
	public static let tokenEndpoint = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
	public static let scope = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"

	/// Prefix of the client device uid (chiaki `DUID_PREFIX`).
	static let duidPrefix = "0000000700410080"

	/// A fresh client device uid: the prefix followed by 16 random bytes as lowercase hex
	/// (chiaki `chiaki_holepunch_generate_client_device_uid`), 48 characters.
	public static func makeDeviceUID() -> String {
		var bytes = [UInt8](repeating: 0, count: 16)
		if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
			for i in bytes.indices { bytes[i] = UInt8.random(in: 0 ... 255) }
		}
		return duidPrefix + bytes.map { String(format: "%02x", $0) }.joined()
	}

	/// The raw (unencoded) login URL string exactly as chiaki-ng builds it, before Qt's URL encoding.
	static func rawAuthorizeURLString(deviceUID: String) -> String {
		"\(authorizeEndpoint)?service_entity=urn:service-entity:psn&response_type=code&client_id=\(clientID)&redirect_uri=\(redirectURI)&scope=\(scope)&request_locale=en_US&ui=pr&service_logo=ps&layout_type=popup&smcid=remoteplay&prompt=always&PlatformPrivacyWs1=minimal&duid=\(deviceUID)&"
	}

	/// The login page URL (spaces in the scope are percent encoded, as QUrl does).
	public static func authorizeURL(deviceUID: String = makeDeviceUID()) -> URL {
		let raw = rawAuthorizeURLString(deviceUID: deviceUID)
		let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
		return URL(string: encoded)!
	}

	/// True if `url` is Sony's redirect page (chiaki `checkPsnRedirectURL`: prefix match).
	public static func isRedirect(_ url: URL) -> Bool {
		url.absoluteString.hasPrefix(redirectURI)
	}

	/// Extracts the authorization code from the redirect URL (or a pasted copy of it).
	public static func authorizationCode(fromRedirect url: URL) throws -> String {
		guard isRedirect(url) else { throw PSNAuthError.notRedirectURL }
		let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
		if let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty {
			return code
		}
		if let error = items.first(where: { $0.name == "error" })?.value {
			let description = items.first(where: { $0.name == "error_description" })?.value
			throw PSNAuthError.loginRejected(error: error, description: description)
		}
		throw PSNAuthError.missingCode
	}

	/// Same as `authorizationCode(fromRedirect:)` for text the user pasted from a browser.
	public static func authorizationCode(fromPastedText text: String) throws -> String {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let url = URL(string: trimmed) else { throw PSNAuthError.notRedirectURL }
		return try authorizationCode(fromRedirect: url)
	}

	// MARK: Account id encoding

	/// The account id is Sony's numeric `user_id` as 8 bytes little endian
	/// (scripts/psn-account-id.py: `user_id.to_bytes(8, "little")`).
	public static func accountID(fromUserID userID: UInt64) -> Data {
		withUnsafeBytes(of: userID.littleEndian) { Data($0) }
	}

	public static func accountID(fromUserIDString string: String) throws -> Data {
		guard let value = UInt64(string.trimmingCharacters(in: .whitespaces)) else {
			throw PSNAuthError.invalidUserID
		}
		return accountID(fromUserID: value)
	}

	public static func userID(fromAccountID data: Data) -> UInt64? {
		guard data.count == 8 else { return nil }
		return data.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << (8 * UInt64($1.offset))) }
	}

	/// Parses what a user types as their account id: the base64 form other Remote Play clients
	/// show (padding optional, surrounding whitespace ignored), or the decimal user id if the
	/// text is all digits.
	public static func parseAccountID(_ text: String) throws -> Data {
		let trimmed = text.filter { !$0.isWhitespace }
		guard !trimmed.isEmpty else { throw PSNAuthError.invalidAccountID }
		if trimmed.allSatisfy(\.isASCIIDigit) {
			return try accountID(fromUserIDString: trimmed)
		}
		var b64 = trimmed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while b64.count % 4 != 0 { b64.append("=") }
		guard let data = Data(base64Encoded: b64), data.count == 8 else {
			throw PSNAuthError.invalidAccountID
		}
		return data
	}

	// MARK: Network

	/// Exchanges the authorization code for an access token and reads the account id from
	/// Sony's token info endpoint, exactly like chiaki-ng's `PSNAccountID`.
	public static func fetchAccount(authorizationCode code: String, session: URLSession? = nil) async throws -> PSNAccount {
		let session = session ?? URLSession(configuration: ephemeralConfiguration)

		// 1. Token. chiaki-ng sends this body verbatim (unencoded scope, trailing '&').
		var tokenRequest = URLRequest(url: URL(string: tokenEndpoint)!)
		tokenRequest.httpMethod = "POST"
		tokenRequest.setValue(basicAuthHeader, forHTTPHeaderField: "Authorization")
		tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
		tokenRequest.httpBody = Data(tokenRequestBody(code: code).utf8)
		let tokenJSON = try await performJSON(tokenRequest, session: session, step: "token")
		guard let accessToken = tokenJSON["access_token"] as? String, !accessToken.isEmpty else {
			throw PSNAuthError.unexpectedResponse(step: "token")
		}

		// 2. Token info: GET <token endpoint>/<access token>, same basic auth.
		let escapedToken = accessToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? accessToken
		var infoRequest = URLRequest(url: URL(string: "\(tokenEndpoint)/\(escapedToken)")!)
		infoRequest.httpMethod = "GET"
		infoRequest.setValue(basicAuthHeader, forHTTPHeaderField: "Authorization")
		infoRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		let infoJSON = try await performJSON(infoRequest, session: session, step: "account info")

		let userIDString: String
		if let s = infoJSON["user_id"] as? String {
			userIDString = s
		} else if let n = infoJSON["user_id"] as? NSNumber {
			userIDString = n.stringValue
		} else {
			throw PSNAuthError.unexpectedResponse(step: "account info")
		}
		let accountID = try accountID(fromUserIDString: userIDString)
		let onlineID = (infoJSON["online_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
		return PSNAccount(accountID: accountID, onlineID: onlineID)
	}

	/// The form body of the token request (exposed for verification).
	public static func tokenRequestBody(code: String) -> String {
		let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
		let encodedCode = code.addingPercentEncoding(withAllowedCharacters: safe) ?? code
		return "grant_type=authorization_code&code=\(encodedCode)&scope=\(scope)&redirect_uri=\(redirectURI)&"
	}

	static var basicAuthHeader: String {
		"Basic " + Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
	}

	static var ephemeralConfiguration: URLSessionConfiguration {
		let config = URLSessionConfiguration.ephemeral
		config.timeoutIntervalForRequest = 10 // chiaki-ng: kRequestTimeoutMs
		config.httpCookieStorage = nil
		config.urlCache = nil
		return config
	}

	private static func performJSON(_ request: URLRequest, session: URLSession, step: String) async throws -> [String: Any] {
		let data: Data
		let response: URLResponse
		do {
			(data, response) = try await session.data(for: request)
		} catch let error as URLError {
			throw PSNAuthError.network(step: step, underlying: error.localizedDescription)
		}
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
		guard status == 200, let json else {
			// Sony's error bodies are {"error": "...", "error_description": "..."}; they carry no secrets.
			let code = json?["error"] as? String
			let description = json?["error_description"] as? String
			throw PSNAuthError.httpError(step: step, status: status, error: code, description: description)
		}
		return json
	}
}

public enum PSNAuthError: LocalizedError, Equatable {
	case notRedirectURL
	case missingCode
	case loginRejected(error: String, description: String?)
	case invalidUserID
	case invalidAccountID
	case network(step: String, underlying: String)
	case httpError(step: String, status: Int, error: String?, description: String?)
	case unexpectedResponse(step: String)

	public var errorDescription: String? {
		switch self {
		case .notRedirectURL:
			return "That is not Sony's redirect URL. It must start with \(PSNAuth.redirectURI)"
		case .missingCode:
			return "The redirect URL does not contain a login code."
		case let .loginRejected(error, description):
			return "Sony refused the login (\(description ?? error))."
		case .invalidUserID:
			return "Sony returned an account number that could not be read."
		case .invalidAccountID:
			return "That is not a valid account ID. It should be 12 characters of base64 ending in \"=\", for example \"AbCdEfGhIjk=\"."
		case let .network(step, underlying):
			return "Could not reach Sony (\(step)): \(underlying)"
		case let .httpError(step, status, error, description):
			let detail = description ?? error ?? "HTTP \(status)"
			return "Sony rejected the \(step) request: \(detail)"
		case let .unexpectedResponse(step):
			return "Sony's \(step) response was missing expected fields."
		}
	}

	public var recoverySuggestion: String? {
		switch self {
		case .notRedirectURL, .missingCode:
			return "After signing in, copy the full address of the page that says \"redirect\" and paste it here."
		case .httpError(_, let status, let error, _) where status == 400 || error == "invalid_grant":
			return "Login codes are single use and expire quickly. Sign in again."
		case .network:
			return "Check the Mac's internet connection and try again."
		default:
			return "Sign in again, or enter the account ID manually."
		}
	}
}

extension Character {
	var isASCIIDigit: Bool { isASCII && isNumber }
}
