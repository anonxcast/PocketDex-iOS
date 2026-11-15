import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Google OAuth (PKCE) for Drive backup/restore — same model as Delta Sync.
/// Client ID is baked into Info.plist (`GOOGLE_OAUTH_CLIENT_ID`); end users never paste it.
@MainActor
final class GoogleDriveAuth: NSObject, ObservableObject {
  static let shared = GoogleDriveAuth()

  private enum Account {
    static let refresh = "google.oauth.refresh"
    static let access = "google.oauth.access"
    static let accessExpiry = "google.oauth.accessExpiry"
    static let email = "google.oauth.email"
  }

  private let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
  private let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
  private let scope = "https://www.googleapis.com/auth/drive.file https://www.googleapis.com/auth/userinfo.email"

  @Published private(set) var isSignedIn = false
  @Published private(set) var email: String?
  @Published var statusMessage: String?

  private var authSession: ASWebAuthenticationSession?
  private var presentation: AuthPresenter?

  /// Baked iOS OAuth client — never shown in Settings.
  var clientID: String {
    (Bundle.main.object(forInfoDictionaryKey: "GOOGLE_OAUTH_CLIENT_ID") as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var reversedClientID: String? {
    let id = clientID
    guard id.hasSuffix(".apps.googleusercontent.com") else { return nil }
    let prefix = String(id.dropLast(".apps.googleusercontent.com".count))
    return "com.googleusercontent.apps.\(prefix)"
  }

  private override init() {
    super.init()
    email = KeychainStore.get(account: Account.email)
    isSignedIn = KeychainStore.get(account: Account.refresh) != nil
    if isSignedIn {
      statusMessage = email.map { "Signed in as \($0)" } ?? "Signed in"
    }
  }

  func signIn() async throws {
    guard !clientID.isEmpty else { throw DriveAuthError.missingClientID }
    guard let scheme = reversedClientID else { throw DriveAuthError.badClientID }
    let redirect = "\(scheme):/oauth2callback"
    let verifier = Self.randomURLSafe(32)
    let challenge = Self.codeChallenge(verifier)
    var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    comps.queryItems = [
      URLQueryItem(name: "client_id", value: clientID),
      URLQueryItem(name: "redirect_uri", value: redirect),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: scope),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
    ]
    guard let authURL = comps.url else { throw DriveAuthError.badURL }

    let callback = try await startAuthSession(url: authURL, callbackScheme: scheme)
    guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "code" })?.value
    else {
      throw DriveAuthError.noCode
    }
    try await exchangeCode(code, verifier: verifier, redirect: redirect)
    try await refreshProfile()
    isSignedIn = true
    statusMessage = email.map { "Signed in as \($0)" } ?? "Signed in"
  }

  func signOut() {
    KeychainStore.delete(account: Account.refresh)
    KeychainStore.delete(account: Account.access)
    KeychainStore.delete(account: Account.accessExpiry)
    KeychainStore.delete(account: Account.email)
    email = nil
    isSignedIn = false
    statusMessage = "Signed out"
  }

  func accessToken() async throws -> String {
    if let token = KeychainStore.get(account: Account.access),
       let expiryStr = KeychainStore.get(account: Account.accessExpiry),
       let expiry = Double(expiryStr),
       Date().timeIntervalSince1970 < expiry - 60 {
      return token
    }
    guard let refresh = KeychainStore.get(account: Account.refresh) else {
      throw DriveAuthError.notSignedIn
    }
    var req = URLRequest(url: tokenURL)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Self.formEncode([
      "client_id": clientID,
      "grant_type": "refresh_token",
      "refresh_token": refresh,
    ]).data(using: .utf8)
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw DriveAuthError.tokenFailed
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    guard let access = json["access_token"] as? String else { throw DriveAuthError.tokenFailed }
    let expiresIn = (json["expires_in"] as? Double) ?? 3600
    KeychainStore.set(access, account: Account.access)
    KeychainStore.set(String(Date().timeIntervalSince1970 + expiresIn), account: Account.accessExpiry)
    return access
  }

  private func exchangeCode(_ code: String, verifier: String, redirect: String) async throws {
    var req = URLRequest(url: tokenURL)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.httpBody = Self.formEncode([
      "client_id": clientID,
      "code": code,
      "code_verifier": verifier,
      "grant_type": "authorization_code",
      "redirect_uri": redirect,
    ]).data(using: .utf8)
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw DriveAuthError.tokenFailed
    }
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    guard let access = json["access_token"] as? String else { throw DriveAuthError.tokenFailed }
    let expiresIn = (json["expires_in"] as? Double) ?? 3600
    KeychainStore.set(access, account: Account.access)
    KeychainStore.set(String(Date().timeIntervalSince1970 + expiresIn), account: Account.accessExpiry)
    if let refresh = json["refresh_token"] as? String {
      KeychainStore.set(refresh, account: Account.refresh)
    } else if KeychainStore.get(account: Account.refresh) == nil {
      throw DriveAuthError.noRefreshToken
    }
  }

  private func refreshProfile() async throws {
    let token = try await accessToken()
    var req = URLRequest(url: userInfoURL)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: req)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    if let mail = json["email"] as? String {
      email = mail
      KeychainStore.set(mail, account: Account.email)
    }
  }

  private func startAuthSession(url: URL, callbackScheme: String) async throws -> URL {
    try await withCheckedThrowingContinuation { cont in
      let presenter = AuthPresenter()
      self.presentation = presenter
      let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callback, error in
        self?.authSession = nil
        self?.presentation = nil
        if let callback {
          cont.resume(returning: callback)
        } else {
          cont.resume(throwing: error ?? DriveAuthError.canceled)
        }
      }
      session.presentationContextProvider = presenter
      session.prefersEphemeralWebBrowserSession = false
      self.authSession = session
      if !session.start() {
        cont.resume(throwing: DriveAuthError.cannotStart)
      }
    }
  }

  private static func randomURLSafe(_ bytes: Int) -> String {
    var buf = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
    return Data(buf).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func codeChallenge(_ verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func formEncode(_ fields: [String: String]) -> String {
    fields.map { key, value in
      let k = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
      let v = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
      return "\(k)=\(v)"
    }
    .joined(separator: "&")
  }
}

private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let key = scenes.flatMap(\.windows).first(where: \.isKeyWindow) { return key }
    return scenes.flatMap(\.windows).first ?? ASPresentationAnchor()
  }
}

enum DriveAuthError: LocalizedError {
  case missingClientID, badClientID, badURL, noCode, canceled, cannotStart
  case tokenFailed, noRefreshToken, notSignedIn

  var errorDescription: String? {
    switch self {
    case .missingClientID:
      return "Google Drive isn’t configured in this build."
    case .badClientID:
      return "Invalid Google OAuth Client ID in this build."
    case .badURL: return "Could not build the Google sign-in URL."
    case .noCode: return "Google did not return an auth code."
    case .canceled: return "Sign-in canceled."
    case .cannotStart: return "Could not open Google sign-in."
    case .tokenFailed: return "Google token exchange failed."
    case .noRefreshToken: return "No refresh token — try signing in again."
    case .notSignedIn: return "Not signed in to Google Drive."
    }
  }
}
