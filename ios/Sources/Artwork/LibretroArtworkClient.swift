import Foundation

/// Free, no-account artwork from the public Libretro thumbnails CDN.
/// https://thumbnails.libretro.com/{System}/Named_{Boxarts|Titles|Logos}/…
actor LibretroArtworkClient {
  static let shared = LibretroArtworkClient()

  private let base = URL(string: "https://thumbnails.libretro.com")!
  private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    cfg.httpAdditionalHeaders = [
      "User-Agent": "PocketDex/1.0 (Libretro thumbnails; personal library)"
    ]
    return URLSession(configuration: cfg)
  }()

  /// Cached directory listings: "system|Boxarts" → filenames (only successful fetches).
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
  /// Tries `romName` plus any `alternateNames` (cleaned dump titles, display names).
  func fetchBundle(
    for romName: String,
    console: ConsoleKind,
    alternateNames: [String] = []
  ) async -> (cover: Data?, banner: Data?, icon: Data?, logo: Data?) {
    guard let system = Self.systemFolder(for: console) else {
      return (nil, nil, nil, nil)
    }
    var seen = Set<String>()
    let queries = ([romName] + alternateNames)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert(Self.normalize($0)).inserted }

    for query in queries {
      let coverName = await bestFilename(romName: query, system: system, kind: .boxarts)
      let titleName = await bestFilename(romName: query, system: system, kind: .titles)
      let logoName = await bestFilename(romName: query, system: system, kind: .logos)
      guard coverName != nil || titleName != nil || logoName != nil else { continue }

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
      if c != nil || b != nil || logo != nil {
        // Icon falls back to cover when Libretro has no separate badge art.
        return (c, b ?? c, c, logo)
      }
    }
    return (nil, nil, nil, nil)
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
    // GoodTools / scene index: "1986 - Pokemon Emerald (U)(TrashMan)"
    s = s.replacingOccurrences(of: #"^\s*\d{1,5}\s*[-_.]\s*"#, with: "", options: .regularExpression)
    // Drop parenthetical / bracket tags: (USA), [b1], (TrashMan), etc.
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
    let noise: Set<String> = [
      "trashman", "nointro", "nonintro", "goodtools", "repack", "trimmed",
      "fixed", "dump", "rom", "hack", "beta", "proto", "sample", "demo",
    ]
    var tokens = String(allowed)
      .split(separator: " ", omittingEmptySubsequences: true)
      .map(String.init)
      .map { $0.lowercased() }
      .filter { !noise.contains($0) }
    // Leftover scene numbers after the dash strip ("1986 Pokemon Emerald").
    while let first = tokens.first, first.allSatisfy(\.isNumber) {
      tokens.removeFirst()
    }
    return tokens.joined(separator: " ")
  }

  /// Extra search strings when the dump filename is noisy (TrashMan, scene index, …).
  /// TrashMan / scene retail dumps are aliased to the Libretro retail title first
  /// (e.g. `Pokemon - Emerald Version (U)(TrashMan)` → `Pokemon - Emerald Version`).
  static func queryCandidates(
    romName: String,
    displayName: String?,
    console: ConsoleKind? = nil
  ) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    func add(_ raw: String?) {
      guard let raw else { return }
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return }
      let key = normalize(trimmed)
      guard !key.isEmpty, seen.insert(key).inserted else { return }
      out.append(trimmed)
    }
    // Prefer the retail Libretro title so TrashMan / GoodTools dumps hit box art.
    add(retailArtworkAlias(romName: romName, console: console))
    add(romName)
    add(displayName)
    let cleaned = normalize(romName)
    if !cleaned.isEmpty { add(cleaned) }
    return out
  }

  /// Map known trimmed/scene retail dumps onto Libretro’s retail cover names.
  static func retailArtworkAlias(romName: String, console: ConsoleKind?) -> String? {
    let raw = romName.lowercased()
    let n = normalize(romName)
    let isTrashMan = raw.contains("trashman") || raw.contains("trash man")
    let isSceneIndex = romName.range(of: #"^\s*\d{1,5}\s*[-_.]"#, options: .regularExpression) != nil
    // Expansion hacks keep BPEE/BPRE headers but must not steal retail covers.
    let hackNoise = ["seaglass", "modern", "unbound", "radical", "rowe", "theta", "gaia",
                     "glazed", "imperium", "soulgold", "crystal advance", "lazarus",
                     "run and bun", "run & bun", "kaizo"]
    if hackNoise.contains(where: { n.contains($0) || raw.contains($0) }) { return nil }

    let gba = console == nil || console == .gba
    let gbc = console == nil || console == .gbc
    let gb = console == nil || console == .gb
    let nds = console == nil || console == .nds

    // Classic GoodTools zip stem for Emerald (trm-pmeu).
    if gba, raw.contains("trm-pmeu") || n == "trm pmeu" {
      return "Pokemon - Emerald Version"
    }

    guard isTrashMan || isSceneIndex else {
      // Still alias bare trimmed retail names that already normalize cleanly.
      if gba {
        if n == "pokemon emerald" || n == "pokemon emerald version" {
          return "Pokemon - Emerald Version"
        }
        if n == "pokemon firered" || n == "pokemon firered version" || n == "pokemon fire red" {
          return "Pokemon - FireRed Version"
        }
        if n == "pokemon leafgreen" || n == "pokemon leafgreen version" || n == "pokemon leaf green" {
          return "Pokemon - LeafGreen Version"
        }
      }
      return nil
    }

    if gba {
      if n.contains("emerald") { return "Pokemon - Emerald Version" }
      if n.contains("firered") || n.contains("fire red") { return "Pokemon - FireRed Version" }
      if n.contains("leafgreen") || n.contains("leaf green") { return "Pokemon - LeafGreen Version" }
      if n.contains("ruby") { return "Pokemon - Ruby Version" }
      if n.contains("sapphire") { return "Pokemon - Sapphire Version" }
    }
    if gbc {
      if n.contains("crystal") { return "Pokemon - Crystal Version" }
      if n.contains("gold") && !n.contains("heart") { return "Pokemon - Gold Version" }
      if n.contains("silver") && !n.contains("soul") { return "Pokemon - Silver Version" }
      if n.contains("yellow") { return "Pokemon - Yellow Version" }
    }
    if gb {
      if n.contains("red") && !n.contains("firered") && !n.contains("fire") {
        return "Pokemon - Red Version"
      }
      if n.contains("blue") { return "Pokemon - Blue Version" }
    }
    if nds {
      if n.contains("heartgold") || n.contains("heart gold") {
        return "Pokemon - HeartGold Version"
      }
      if n.contains("soulsilver") || n.contains("soul silver") {
        return "Pokemon - SoulSilver Version"
      }
      if n.contains("platinum") { return "Pokemon - Platinum Version" }
    }
    return nil
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
        // Don't cache failures — first-launch / offline would block covers forever.
        return []
      }
      let names = Self.parseListing(html)
      listingCache[key] = names
      return names
    } catch {
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
  /// Fill missing cover / banner / icon / logo from Libretro (free, no account).
  /// Quietly skips when nothing matches. Set `force` to replace existing art for the ROM.
  @discardableResult
  static func applyIfNeeded(to rom: RomItem, force: Bool = false) async -> Bool {
    guard let console = rom.console else { return false }
    let key = rom.artworkKey
    let store = RomArtworkStore.shared
    let needCover = force || !store.hasArtwork(forKey: key, kind: .cover)
    let needBanner = force || !store.hasArtwork(forKey: key, kind: .banner)
    let needIcon = force || !store.hasArtwork(forKey: key, kind: .icon)
    let needLogo = force || !store.hasArtwork(forKey: key, kind: .logo)
    guard needCover || needBanner || needIcon || needLogo else { return false }

    let display = store.displayName(forKey: key)
    let queries = LibretroArtworkClient.queryCandidates(
      romName: rom.name,
      displayName: display,
      console: console
    )
    let primary = queries.first ?? rom.name
    let alts = Array(queries.dropFirst())
    let bundle = await LibretroArtworkClient.shared.fetchBundle(
      for: primary,
      console: console,
      alternateNames: alts
    )
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
