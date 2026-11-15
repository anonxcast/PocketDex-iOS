import CryptoKit
import Foundation

/// RetroAchievements Web API (username + web API key). Play HUD polls for newly earned unlocks.
actor RetroAchievementsClient {
  static let shared = RetroAchievementsClient()

  private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    cfg.httpAdditionalHeaders = [
      "User-Agent": "PocketDex/1.0 (RetroAchievements; personal library)"
    ]
    return URLSession(configuration: cfg)
  }()

  private let userAccount = "retroachievements.username"
  private let keyAccount = "retroachievements.apiKey"

  struct Profile: Equatable {
    var username: String
    var displayName: String
    var avatarUrl: String?
    var totalPoints: Int
    var softcorePoints: Int
  }

  struct Achievement: Identifiable, Equatable {
    var id: Int
    var title: String
    var description: String
    var points: Int
    var badgeUrl: String?
    var isEarned: Bool
    var dateEarned: String?
  }

  struct GameProgress: Equatable {
    var gameId: Int
    var title: String
    var consoleName: String?
    var imageIconUrl: String?
    var numAchievements: Int
    var numAwarded: Int
    var userScore: Int
    var totalPossible: Int
    var achievements: [Achievement]
  }

  enum RAError: LocalizedError {
    case notSignedIn
    case badCredentials
    case api(String)
    case noGame

    var errorDescription: String? {
      switch self {
      case .notSignedIn: return "Sign in to RetroAchievements in Settings"
      case .badCredentials: return "Invalid RetroAchievements username or API key"
      case .api(let m): return m
      case .noGame: return "No RetroAchievements set for this ROM"
      }
    }
  }

  func credentials() -> (username: String, apiKey: String)? {
    guard let u = KeychainStore.get(account: userAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let k = KeychainStore.get(account: keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !u.isEmpty, !k.isEmpty else { return nil }
    return (u, k)
  }

  func isSignedIn() -> Bool { credentials() != nil }

  func cachedUsername() -> String? {
    KeychainStore.get(account: userAccount)
  }

  func setCredentials(username: String?, apiKey: String?) {
    let u = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let k = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if u.isEmpty || k.isEmpty {
      KeychainStore.delete(account: userAccount)
      KeychainStore.delete(account: keyAccount)
    } else {
      KeychainStore.set(u, account: userAccount)
      KeychainStore.set(k, account: keyAccount)
    }
  }

  func signOut() { setCredentials(username: nil, apiKey: nil) }

  @discardableResult
  func login(username: String, apiKey: String) async throws -> Profile {
    setCredentials(username: username, apiKey: apiKey)
    do {
      let profile = try await fetchProfile()
      return profile
    } catch {
      signOut()
      throw error
    }
  }

  func fetchProfile() async throws -> Profile {
    guard let creds = credentials() else { throw RAError.notSignedIn }
    let raw = try await getJSON(
      "API_GetUserProfile.php",
      query: ["u": creds.username, "y": creds.apiKey]
    )
    if raw["User"] == nil && raw["user"] == nil {
      if let err = raw["Error"] as? String { throw RAError.api(err) }
      throw RAError.badCredentials
    }
    let user = (raw["User"] as? String) ?? creds.username
    let display = (raw["User"] as? String) ?? user
    let avatar = raw["UserPic"] as? String
    let total = intValue(raw["TotalPoints"] ?? raw["totalPoints"])
    let soft = intValue(raw["TotalSoftcorePoints"] ?? raw["totalSoftcorePoints"])
    let avatarUrl: String? = {
      guard let avatar, !avatar.isEmpty else { return nil }
      if avatar.hasPrefix("http") { return avatar }
      return "https://media.retroachievements.org\(avatar.hasPrefix("/") ? "" : "/")\(avatar)"
    }()
    return Profile(
      username: user,
      displayName: display,
      avatarUrl: avatarUrl,
      totalPoints: total,
      softcorePoints: soft
    )
  }

  /// MD5 of the ROM file (works for most retail GB/GBC/GBA dumps RA knows).
  func md5Hex(ofFile url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    let digest = Insecure.MD5.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  func gameId(forRomMD5 md5: String) async throws -> Int {
    // Public game-id lookup used by rcheevos clients.
    var components = URLComponents(string: "https://retroachievements.org/dorequest.php")!
    components.queryItems = [
      URLQueryItem(name: "r", value: "gameid"),
      URLQueryItem(name: "m", value: md5.lowercased()),
    ]
    guard let url = components.url else { throw RAError.api("Bad URL") }
    let (data, response) = try await session.data(from: url)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw RAError.api("RA HTTP \(http.statusCode)")
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RAError.api("Bad game-id response")
    }
    let id = intValue(obj["GameID"] ?? obj["gameID"] ?? obj["gameId"])
    if id <= 0 { throw RAError.noGame }
    return id
  }

  func progress(forGameId gameId: Int) async throws -> GameProgress {
    guard let creds = credentials() else { throw RAError.notSignedIn }
    let raw = try await getJSON(
      "API_GetGameInfoAndUserProgress.php",
      query: [
        "u": creds.username,
        "g": String(gameId),
        "y": creds.apiKey,
      ]
    )
    let title = (raw["Title"] as? String) ?? "Game"
    let console = raw["ConsoleName"] as? String
    let icon = mediaURL(raw["ImageIcon"] as? String)
    let num = intValue(raw["NumAchievements"])
    let awardedHard = intValue(raw["NumAwardedToUser"])
    let awardedSoft = intValue(raw["NumAwardedToUserSoftcore"])
    let awarded = max(awardedHard, awardedSoft)
    let userScore = intValue(raw["Score"]) // may be absent
    var list: [Achievement] = []
    if let map = raw["Achievements"] as? [String: [String: Any]] {
      for (_, a) in map {
        let id = intValue(a["ID"] ?? a["id"])
        let title = (a["Title"] as? String) ?? "Achievement"
        let desc = (a["Description"] as? String) ?? ""
        let points = intValue(a["Points"])
        let badgeName = a["BadgeName"] as? String
        let badge: String? = {
          guard let badgeName, !badgeName.isEmpty else { return nil }
          return "https://media.retroachievements.org/Badge/\(badgeName).png"
        }()
        let earned = (a["DateEarned"] as? String)?.isEmpty == false
          || (a["DateEarnedHardcore"] as? String)?.isEmpty == false
        let date = (a["DateEarnedHardcore"] as? String) ?? (a["DateEarned"] as? String)
        list.append(Achievement(
          id: id,
          title: title,
          description: desc,
          points: points,
          badgeUrl: badge,
          isEarned: earned,
          dateEarned: date
        ))
      }
    }
    list.sort { lhs, rhs in
      if lhs.isEarned != rhs.isEarned { return lhs.isEarned && !rhs.isEarned }
      return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }
    let totalPossible = list.reduce(0) { $0 + $1.points }
    let earnedPoints = list.filter(\.isEarned).reduce(0) { $0 + $1.points }
    return GameProgress(
      gameId: gameId,
      title: title,
      consoleName: console,
      imageIconUrl: icon,
      numAchievements: num > 0 ? num : list.count,
      numAwarded: awarded > 0 ? awarded : list.filter(\.isEarned).count,
      userScore: userScore > 0 ? userScore : earnedPoints,
      totalPossible: totalPossible,
      achievements: list
    )
  }

  func progress(forRomAt url: URL) async throws -> GameProgress {
    let md5 = try md5Hex(ofFile: url)
    let id = try await gameId(forRomMD5: md5)
    return try await progress(forGameId: id)
  }

  /// Resolve whether a ROM hash has an RA set (for play-HUD tracking).
  func supportedGame(forRomAt url: URL) async throws -> (gameId: Int, title: String, iconUrl: String?) {
    let progress = try await progress(forRomAt: url)
    return (progress.gameId, progress.title, progress.imageIconUrl)
  }

  /// Recent unlocks for `gameId` (RA returns a top-level JSON array).
  func recentAchievements(forGameId gameId: Int, minutes: Int = 90) async throws -> [(achievement: Achievement, gameId: Int)] {
    guard let creds = credentials() else { throw RAError.notSignedIn }
    let rows = try await getJSONArray(
      "API_GetUserRecentAchievements.php",
      query: [
        "u": creds.username,
        "y": creds.apiKey,
        "m": String(max(1, minutes)),
      ]
    )
    return rows.compactMap { a -> (Achievement, Int)? in
      let gid = intValue(a["GameID"] ?? a["gameID"] ?? a["GameId"])
      guard gid == gameId else { return nil }
      let id = intValue(a["AchievementID"] ?? a["ID"] ?? a["id"])
      guard id > 0 else { return nil }
      let title = (a["Title"] as? String) ?? "Achievement"
      let desc = (a["Description"] as? String) ?? ""
      let points = intValue(a["Points"])
      let badgeName = (a["BadgeName"] as? String) ?? (a["Badge"] as? String)
      let badge: String? = {
        guard let badgeName, !badgeName.isEmpty else { return nil }
        if badgeName.hasPrefix("http") { return badgeName }
        return "https://media.retroachievements.org/Badge/\(badgeName).png"
      }()
      let date = (a["DateAwarded"] as? String) ?? (a["DateEarned"] as? String)
      let ach = Achievement(
        id: id,
        title: title,
        description: desc,
        points: points,
        badgeUrl: badge,
        isEarned: true,
        dateEarned: date
      )
      return (ach, gid)
    }
  }

  /// In-game + title images for a hash-matched RA entry (works for Unbound and other hacks).
  func screenshotData(forRomAt url: URL, limit: Int = 4) async throws -> [Data] {
    guard let creds = credentials() else { throw RAError.notSignedIn }
    let md5 = try md5Hex(ofFile: url)
    let id = try await gameId(forRomMD5: md5)
    let raw = try await getJSON(
      "API_GetGame.php",
      query: [
        "i": String(id),
        "y": creds.apiKey,
      ]
    )
    // Prefer real gameplay frames over title / box.
    let paths = [
      raw["ImageIngame"] as? String,
      raw["ImageTitle"] as? String,
    ].compactMap { $0 }
    var out: [Data] = []
    for path in paths {
      guard let urlStr = mediaURL(path), let media = URL(string: urlStr) else { continue }
      do {
        let (data, response) = try await session.data(from: media)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          continue
        }
        if data.count > 64 {
          out.append(data)
        }
      } catch {
        continue
      }
      if out.count >= limit { break }
    }
    return out
  }

  // MARK: - HTTP

  private func getJSON(_ endpoint: String, query: [String: String]) async throws -> [String: Any] {
    let data = try await getData(endpoint, query: query)
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw RAError.api("Bad JSON")
    }
    return obj
  }

  private func getJSONArray(_ endpoint: String, query: [String: String]) async throws -> [[String: Any]] {
    let data = try await getData(endpoint, query: query)
    let obj = try JSONSerialization.jsonObject(with: data)
    if let arr = obj as? [[String: Any]] { return arr }
    if let arr = obj as? [Any] { return arr.compactMap { $0 as? [String: Any] } }
    if let dict = obj as? [String: Any] {
      if let arr = dict["RecentAchievements"] as? [[String: Any]] { return arr }
      return dict.values.compactMap { $0 as? [String: Any] }
    }
    return []
  }

  private func getData(_ endpoint: String, query: [String: String]) async throws -> Data {
    var components = URLComponents(string: "https://retroachievements.org/API/\(endpoint)")!
    components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    guard let url = components.url else { throw RAError.api("Bad URL") }
    let (data, response) = try await session.data(from: url)
    if let http = response as? HTTPURLResponse {
      if http.statusCode == 401 || http.statusCode == 403 { throw RAError.badCredentials }
      if !(200..<300).contains(http.statusCode) {
        throw RAError.api("RA HTTP \(http.statusCode)")
      }
    }
    return data
  }

  private func intValue(_ any: Any?) -> Int {
    if let i = any as? Int { return i }
    if let n = any as? NSNumber { return n.intValue }
    if let s = any as? String, let i = Int(s) { return i }
    return 0
  }

  private func mediaURL(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    if path.hasPrefix("http") { return path }
    return "https://media.retroachievements.org\(path.hasPrefix("/") ? "" : "/")\(path)"
  }
}
