import Foundation

/// Thin SteamGridDB API v2 client (Bearer API key from user preferences).
actor SteamGridDBClient {
  static let shared = SteamGridDBClient()

  private let base = URL(string: "https://www.steamgriddb.com/api/v2")!
  private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    return URLSession(configuration: cfg)
  }()

  private let usernameAccount = "steamgriddb.username"

  struct GameHit: Identifiable, Decodable, Hashable {
    let id: Int
    let name: String
    let types: [String]?
    let verified: Bool?
  }

  struct ImageHit: Identifiable, Decodable, Hashable {
    let id: Int
    let url: String
    let thumb: String?
    let width: Int?
    let height: Int?
    let style: String?
  }

  struct UserProfile: Equatable {
    var id: Int?
    var name: String
    var avatar: String?
  }

  private struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let errors: [String]?
  }

  func apiKey() -> String? {
    let key = KeychainStore.get(account: "steamgriddb.apiKey")?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (key?.isEmpty == false) ? key : nil
  }

  func setAPIKey(_ key: String?) {
    let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      KeychainStore.delete(account: "steamgriddb.apiKey")
      KeychainStore.delete(account: usernameAccount)
    } else {
      KeychainStore.set(trimmed, account: "steamgriddb.apiKey")
    }
  }

  func hasAPIKey() -> Bool { apiKey() != nil }

  func cachedUsername() -> String? {
    KeychainStore.get(account: usernameAccount)
  }

  func setCachedUsername(_ name: String?) {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      KeychainStore.delete(account: usernameAccount)
    } else {
      KeychainStore.set(trimmed, account: usernameAccount)
    }
  }

  /// Validate key, resolve username via `/users/me` (or JWT payload), cache it.
  @discardableResult
  func login() async throws -> UserProfile {
    guard apiKey() != nil else { throw ArtworkError.noAPIKey }
    // Prove the key works.
    _ = try await search(term: "pokemon")

    if let profile = try? await fetchCurrentUser() {
      setCachedUsername(profile.name)
      return profile
    }
    if let jwtName = jwtDisplayName(from: apiKey()!) {
      let profile = UserProfile(id: nil, name: jwtName, avatar: nil)
      setCachedUsername(jwtName)
      return profile
    }
    let fallback = UserProfile(id: nil, name: "SteamGridDB", avatar: nil)
    setCachedUsername(fallback.name)
    return fallback
  }

  func testConnection() async throws -> Bool {
    _ = try await login()
    return true
  }

  /// Undocumented but live endpoint — returns the authenticated SGDB user.
  func fetchCurrentUser() async throws -> UserProfile {
    let data = try await rawGet("users/me")
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ArtworkError.api("Bad user response")
    }
    if let success = obj["success"] as? Bool, success == false {
      let err = (obj["errors"] as? [String])?.joined(separator: ", ") ?? "User lookup failed"
      throw ArtworkError.api(err)
    }
    let payload = (obj["data"] as? [String: Any]) ?? obj
    let name =
      (payload["name"] as? String)
      ?? (payload["username"] as? String)
      ?? (payload["display_name"] as? String)
      ?? (payload["displayName"] as? String)
    guard let name, !name.isEmpty else {
      throw ArtworkError.api("No username in SteamGridDB response")
    }
    let id = payload["id"] as? Int
    let avatar = payload["avatar"] as? String
    return UserProfile(id: id, name: name, avatar: avatar)
  }

  func search(term: String) async throws -> [GameHit] {
    let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return [] }
    let path = "search/autocomplete/\(q.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? q)"
    let env: Envelope<[GameHit]> = try await get(path)
    guard env.success, let data = env.data else {
      throw ArtworkError.api(env.errors?.joined(separator: ", ") ?? "Search failed")
    }
    return data
  }

  func grids(gameId: Int) async throws -> [ImageHit] {
    try await images(path: "grids/game/\(gameId)", query: [
      "dimensions": "600x900,342x482,660x930",
      "types": "static",
    ])
  }

  func heroes(gameId: Int) async throws -> [ImageHit] {
    try await images(path: "heroes/game/\(gameId)", query: [
      "dimensions": "1920x620,3840x1240,1600x650",
      "types": "static",
    ])
  }

  func icons(gameId: Int) async throws -> [ImageHit] {
    try await images(path: "icons/game/\(gameId)", query: [
      "types": "static",
    ])
  }

  func logos(gameId: Int) async throws -> [ImageHit] {
    try await images(path: "logos/game/\(gameId)", query: [
      "types": "static",
    ])
  }

  func downloadImage(urlString: String) async throws -> Data {
    guard let url = URL(string: urlString) else { throw ArtworkError.downloadFailed }
    let (data, response) = try await session.data(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw ArtworkError.downloadFailed
    }
    return data
  }

  private func images(path: String, query: [String: String]) async throws -> [ImageHit] {
    let env: Envelope<[ImageHit]> = try await get(path, query: query)
    guard env.success, let data = env.data else {
      throw ArtworkError.api(env.errors?.joined(separator: ", ") ?? "No images")
    }
    return data
  }

  private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
    let data = try await rawGet(path, query: query)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func rawGet(_ path: String, query: [String: String] = [:]) async throws -> Data {
    guard let key = apiKey() else { throw ArtworkError.noAPIKey }
    var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    guard let url = components.url else { throw ArtworkError.api("Bad URL") }
    var req = URLRequest(url: url)
    req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: req)
    if let http = response as? HTTPURLResponse {
      if http.statusCode == 401 {
        throw ArtworkError.api("Invalid SteamGridDB API key")
      }
      if !(200..<300).contains(http.statusCode) {
        // Still return body for /users/me soft failures when status is 200; otherwise error.
        if http.statusCode == 404 {
          throw ArtworkError.api("SteamGridDB endpoint not found")
        }
        throw ArtworkError.api("SteamGridDB HTTP \(http.statusCode)")
      }
    }
    return data
  }

  /// Some SGDB keys are JWTs — pull a display name from the payload when `/users/me` fails.
  private func jwtDisplayName(from token: String) -> String? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 { payload.append("=") }
    guard let data = Data(base64Encoded: payload),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return (obj["name"] as? String)
      ?? (obj["username"] as? String)
      ?? (obj["preferred_username"] as? String)
      ?? (obj["sub"] as? String)
  }
}
