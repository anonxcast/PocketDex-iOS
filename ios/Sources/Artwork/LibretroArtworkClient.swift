import Foundation

/// Free, no-account artwork from the public Libretro thumbnails CDN.
/// https://thumbnails.libretro.com/{System}/Named_{Boxarts|Titles|Logos}/…
actor LibretroArtworkClient {
  static let shared = LibretroArtworkClient()

  private let base = URL(string: "https://thumbnails.libretro.com")!
  private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.httpAdditionalHeaders = [
      "User-Agent": "PocketDex/1.0 (Libretro thumbnails; personal library)"
    ]
    return URLSession(configuration: cfg)
  }()

  /// Cached directory listings: "system|Boxarts" → filenames
  private var listingCache: [String: [String]] = [:]

  private enum ArtKind: String {
    case boxarts = "Named_Boxarts"
    case titles = "Named_Titles"
    case logos = "Named_Logos"
    case snaps = "Named_Snaps"
  }

  /// In-game snapshots (Named_Snaps) matched strictly to this ROM’s title — not other games’ art.
  func fetchScreenshots(
    for romName: String,
    displayName: String? = nil,
    console: ConsoleKind,
    limit: Int = 6
  ) async -> [Data] {
    guard let system = Self.systemFolder(for: console) else { return [] }
    // Prefer the dump filename (Libretro naming). Display name is only a fallback.
    let queries = [romName, displayName]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    var out: [Data] = []
    var seenBytes = Set<Int>()

    for query in queries {
      let snapFiles = await bestScreenshotFilenames(romName: query, system: system, kind: .snaps, limit: limit)
      for file in snapFiles {
        guard let data = await download(system: system, kind: .snaps, file: file) else { continue }
        if seenBytes.insert(data.count).inserted {
          out.append(data)
        }
        if out.count >= limit { return out }
      }
      if !out.isEmpty { break }

      // Same-title title screen only (must pass the same strict matcher).
      if let title = await bestScreenshotFilenames(romName: query, system: system, kind: .titles, limit: 1).first,
         let data = await download(system: system, kind: .titles, file: title),
         seenBytes.insert(data.count).inserted {
        out.append(data)
        break
      }
    }
    return out
  }

  /// Download cover / banner / icon / logo when possible. Missing kinds stay nil.
  func fetchBundle(
    for romName: String,
    console: ConsoleKind
  ) async -> (cover: Data?, banner: Data?, icon: Data?, logo: Data?) {
    guard let system = Self.systemFolder(for: console) else {
      return (nil, nil, nil, nil)
    }
    let coverName = await bestFilename(romName: romName, system: system, kind: .boxarts)
    let titleName = await bestFilename(romName: romName, system: system, kind: .titles)
    let logoName = await bestFilename(romName: romName, system: system, kind: .logos)

    async let coverTask: Data? = {
      guard let coverName else { return nil }
      return await download(system: system, kind: .boxarts, file: coverName)
    }()
    async let bannerTask: Data? = {
      guard let titleName else { return nil }
      return await download(system: system, kind: .titles, file: titleName)
    }()
    async let logoTask: Data? = {
      guard let logoName else { return nil }
      return await download(system: system, kind: .logos, file: logoName)
    }()

    let c = await coverTask
    let b = await bannerTask
    let logo = await logoTask
    // Icon falls back to cover when Libretro has no separate badge art.
    return (c, b ?? c, c, logo)
  }

  // MARK: - Match

  private func bestFilename(romName: String, system: String, kind: ArtKind) async -> String? {
    await bestFilenames(romName: romName, system: system, kind: kind, limit: 1).first
  }

  private func bestFilenames(romName: String, system: String, kind: ArtKind, limit: Int) async -> [String] {
    let listing = await listing(system: system, kind: kind)
    guard !listing.isEmpty else { return [] }

    let query = Self.normalize(romName)
    guard !query.isEmpty else { return [] }

    var scored: [(file: String, score: Int)] = []
    for file in listing {
      let stem = (file as NSString).deletingPathExtension
      let score = Self.matchScore(query: query, candidate: Self.normalize(stem), rawCandidate: stem)
      // Require a reasonably confident hit so hacks / odd names stay blank.
      if score >= 70 {
        scored.append((file, score))
      }
    }
    scored.sort { $0.score > $1.score }
    return Array(scored.prefix(max(0, limit)).map(\.file))
  }

  /// Screenshot matcher: only same-title dumps (e.g. FireRed ≠ Emerald ≠ LeafGreen).
  private func bestScreenshotFilenames(
    romName: String,
    system: String,
    kind: ArtKind,
    limit: Int
  ) async -> [String] {
    let listing = await listing(system: system, kind: kind)
    guard !listing.isEmpty else { return [] }

    let query = Self.normalize(romName)
    guard !query.isEmpty else { return [] }

    var scored: [(file: String, score: Int)] = []
    for file in listing {
      let stem = (file as NSString).deletingPathExtension
      let score = Self.screenshotMatchScore(
        query: query,
        candidate: Self.normalize(stem),
        rawCandidate: stem
      )
      if score >= 90 {
        scored.append((file, score))
      }
    }
    guard let best = scored.map(\.score).max() else { return [] }
    // Keep only the top tier (regional / rev variants of the same game).
    let top = scored.filter { $0.score >= best - 5 }.sorted { $0.score > $1.score }
    return Array(top.prefix(max(0, limit)).map(\.file))
  }

  /// Higher is better. 100 = exact core title match.
  private static func matchScore(query: String, candidate: String, rawCandidate: String) -> Int {
    if query == candidate { return 100 }
    // Query is the start of the candidate (e.g. "pokemon emerald" ⊂ "pokemon emerald version").
    if candidate.hasPrefix(query + " ") || candidate.hasPrefix(query) && candidate.count - query.count < 16 {
      return 90
    }
    if query.hasPrefix(candidate) && query.count - candidate.count < 10 {
      return 85
    }
    // Token overlap (ignore tiny words).
    let qTokens = Set(query.split(separator: " ").map(String.init).filter { $0.count > 2 })
    let cTokens = Set(candidate.split(separator: " ").map(String.init).filter { $0.count > 2 })
    guard !qTokens.isEmpty, !cTokens.isEmpty else { return 0 }
    let inter = qTokens.intersection(cTokens)
    let ratio = Double(inter.count) / Double(qTokens.count)
    // Prefer candidates that include every meaningful query token.
    if ratio >= 1.0, cTokens.count - qTokens.count <= 4 { return 80 }
    if ratio >= 0.85 { return 72 }
    if ratio >= 0.7, inter.count >= 2 { return 60 }
    // Raw filename contains the query with libretro dashes (Pokemon - Emerald…).
    let rawNorm = normalize(rawCandidate)
    if rawNorm.contains(query), qTokens.count >= 2 { return 75 }
    return 0
  }

  /// Strict screenshot scoring — generic "pokemon" overlap alone is never enough.
  private static func screenshotMatchScore(query: String, candidate: String, rawCandidate: String) -> Int {
    let q = stripVersionNoise(query)
    let c = stripVersionNoise(candidate)
    if q.isEmpty || c.isEmpty { return 0 }
    if q == c { return 100 }
    if c.hasPrefix(q + " ") || c == q { return 96 }
    if q.hasPrefix(c + " ") || q == c { return 94 }

    let noise: Set<String> = [
      "version", "pokemon", "pokémon", "pocket", "monsters", "game", "boy",
      "color", "advance", "nintendo", "the", "and", "hack", "rom",
    ]
    let qDistinct = Set(
      q.split(separator: " ").map(String.init).filter { $0.count > 2 && !noise.contains($0) }
    )
    let cTokens = Set(c.split(separator: " ").map(String.init).filter { $0.count > 2 })
    // Must have a distinctive title token (firered / emerald / unbound / …).
    guard !qDistinct.isEmpty else { return 0 }
    // Every distinctive query token must appear in the candidate.
    guard qDistinct.isSubset(of: cTokens) else { return 0 }
    // Reject when the candidate has a conflicting Pokémon version token.
    let versionTokens: Set<String> = [
      "firered", "leafgreen", "ruby", "sapphire", "emerald",
      "gold", "silver", "crystal", "diamond", "pearl", "platinum",
      "heartgold", "soulsilver", "black", "white", "yellow", "red", "blue",
      "ultraviolet", "unbound", "radical", "gaia", "glazed", "theta",
    ]
    let qVer = qDistinct.intersection(versionTokens)
    let cVer = cTokens.intersection(versionTokens)
    if !qVer.isEmpty, !cVer.isEmpty, qVer.isDisjoint(with: cVer) {
      return 0
    }
    // Prefer tighter titles (fewer extra tokens).
    let extra = cTokens.subtracting(qDistinct).subtracting(noise).count
    if extra <= 2 { return 92 }
    if extra <= 4 { return 90 }
    return 0
  }

  private static func stripVersionNoise(_ s: String) -> String {
    s.replacingOccurrences(of: #"\bversion\b"#, with: " ", options: .regularExpression)
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
  }

  /// Strip regions/tags and diacritics for comparison.
  static func normalize(_ name: String) -> String {
    var s = name
    // Drop parenthetical / bracket tags: (USA), [b1], etc.
    s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\{[^}]*\}"#, with: " ", options: .regularExpression)
    // Libretro / filesystem substitutions commonly seen in dumps.
    for pair in [("&", " "), ("_", " "), ("-", " "), (".", " "), ("'", ""), ("\"", "")] {
      s = s.replacingOccurrences(of: pair.0, with: pair.1)
    }
    s = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let allowed = s.map { ch -> Character in
      (ch.isLetter || ch.isNumber || ch == " ") ? ch : " "
    }
    return String(allowed)
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
      .lowercased()
  }

  // MARK: - Network

  private func listing(system: String, kind: ArtKind) async -> [String] {
    let key = "\(system)|\(kind.rawValue)"
    if let cached = listingCache[key] { return cached }

    guard var comps = URLComponents(url: base.appendingPathComponent(system).appendingPathComponent(kind.rawValue), resolvingAgainstBaseURL: false) else {
      return []
    }
    // Apache fancy indexing → simpler to parse.
    comps.queryItems = [URLQueryItem(name: "F", value: "0")]
    guard let url = comps.url else { return [] }

    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            let html = String(data: data, encoding: .utf8) else {
        listingCache[key] = []
        return []
      }
      let names = Self.parseListing(html)
      listingCache[key] = names
      return names
    } catch {
      listingCache[key] = []
      return []
    }
  }

  private static func parseListing(_ html: String) -> [String] {
    // href="Pokemon%20-%20Emerald%20Version%20(USA,%20Europe).png"
    let pattern = #"href="([^"]+\.(?:png|jpg|jpeg|webp))""#
    guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
    let range = NSRange(html.startIndex..<html.endIndex, in: html)
    var out: [String] = []
    re.enumerateMatches(in: html, options: [], range: range) { match, _, _ in
      guard let match, let r = Range(match.range(at: 1), in: html) else { return }
      var path = String(html[r])
      if let decoded = path.removingPercentEncoding { path = decoded }
      let file = (path as NSString).lastPathComponent
      if file.lowercased() != "parent directory", !file.isEmpty {
        out.append(file)
      }
    }
    return out
  }

  private func download(system: String, kind: ArtKind, file: String) async -> Data? {
    // Encode like Python urllib.parse.quote(..., safe="") so "(", ",", etc. match the CDN.
    let encSystem = Self.percentEncodePath(system)
    let encFile = Self.percentEncodePath(file)
    guard let url = URL(string: "\(base.absoluteString)/\(encSystem)/\(kind.rawValue)/\(encFile)") else {
      return nil
    }
    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            data.count > 64 else { return nil }
      return data
    } catch {
      return nil
    }
  }

  private static func percentEncodePath(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
  }

  static func systemFolder(for console: ConsoleKind) -> String? {
    switch console {
    case .gba: return "Nintendo - Game Boy Advance"
    case .gbc: return "Nintendo - Game Boy Color"
    case .gb: return "Nintendo - Game Boy"
    case .nds: return "Nintendo - Nintendo DS"
    }
  }
}

@MainActor
enum LibretroArtworkApplier {
  /// Fill missing cover / banner / icon / logo from Libretro. Quietly skips when nothing matches.
  @discardableResult
  static func applyIfNeeded(to rom: RomItem) async -> Bool {
    guard let console = rom.console else { return false }
    let key = rom.artworkKey
    let store = RomArtworkStore.shared
    let needCover = !store.hasArtwork(forKey: key, kind: .cover)
    let needBanner = !store.hasArtwork(forKey: key, kind: .banner)
    let needIcon = !store.hasArtwork(forKey: key, kind: .icon)
    let needLogo = !store.hasArtwork(forKey: key, kind: .logo)
    guard needCover || needBanner || needIcon || needLogo else { return false }

    let bundle = await LibretroArtworkClient.shared.fetchBundle(for: rom.name, console: console)
    var wrote = false
    if needCover, let data = bundle.cover {
      try? store.save(imageData: data, forKey: key, kind: .cover)
      wrote = true
    }
    if needBanner, let data = bundle.banner {
      try? store.save(imageData: data, forKey: key, kind: .banner)
      wrote = true
    }
    if needIcon, let data = bundle.icon {
      try? store.save(imageData: data, forKey: key, kind: .icon)
      wrote = true
    }
    if needLogo, let data = bundle.logo {
      try? store.save(imageData: data, forKey: key, kind: .logo)
      wrote = true
    }
    if wrote {
      var meta = store.meta(forKey: key) ?? RomArtworkMeta()
      meta.steamGridGameName = meta.steamGridGameName ?? "Libretro"
      store.saveMeta(meta, forKey: key)
    }
    return wrote
  }
}
