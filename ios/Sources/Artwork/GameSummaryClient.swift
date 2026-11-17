import Foundation

/// Fetches a short “what this game is about” blurb (Wikipedia) for the game page.
actor GameSummaryClient {
  static let shared = GameSummaryClient()

  private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    return URLSession(configuration: cfg)
  }()

  struct Summary: Equatable {
    var title: String
    var extract: String
    var sourceURL: URL?
  }

  func summary(forDisplayName name: String, console: ConsoleKind?) async -> Summary? {
    if let local = Self.curatedSummary(for: name) {
      return local
    }
    let queries = searchQueries(for: name, console: console)
    for q in queries {
      if let hit = await searchWikipedia(q),
         isRelevantWikipediaTitle(hit, toQuery: q, displayName: name),
         let page = await pageSummary(title: hit),
         isRelevantWikipediaTitle(page.title, toQuery: q, displayName: name) {
        return page
      }
    }
    return nil
  }

  /// Fan-hack blurbs used by the game page before any cached Wikipedia extract.
  nonisolated static func curatedIfAny(forDisplayName name: String) -> Summary? {
    curatedSummary(for: name)
  }

  /// True when a cached About title still matches this ROM (rejects e.g. Pokopia for R.O.W.E.).
  nonisolated static func cachedTitleLooksValid(_ title: String, forDisplayName name: String) -> Bool {
    let t = title.lowercased()
    let n = name.lowercased()
    if n.contains("rowe") || n.contains("r.o.w.e") {
      return t.contains("r.o.w.e") || t.contains("rowe")
    }
    if n.contains("lazarus") {
      return t.contains("lazarus")
    }
    return Self.sharesDistinctiveToken(query: name, title: title)
  }

  // MARK: - Curated fan hacks (no reliable Wikipedia page)

  nonisolated private static func curatedSummary(for name: String) -> Summary? {
    let u = name.uppercased()
    if u.contains("ROWE") || u.contains("R.O.W.E") {
      return Summary(
        title: "Pokémon R.O.W.E.",
        extract: "Pokémon R.O.W.E. (Randomized Open World Emerald) is a fan-made Game Boy Advance ROM hack of Pokémon Emerald by BelialClover. It turns Hoenn into a free open-world adventure with randomized elements, travel across Hoenn, Kanto, and the Sevii Islands, follower Pokémon, and a large National Pokédex.",
        sourceURL: nil
      )
    }
    if u.contains("RADICAL") {
      return Summary(
        title: "Pokémon Radical Red",
        extract: "Pokémon Radical Red is a difficulty-focused FireRed ROM hack with modern battle mechanics, a huge expanded Pokédex, and rebalanced trainers throughout Kanto.",
        sourceURL: nil
      )
    }
    if u.contains("UNBOUND") {
      return Summary(
        title: "Pokémon Unbound",
        extract: "Pokémon Unbound is a large FireRed-based ROM hack set in the new region of Borrius, with an original story, expanded Pokédex, and modern quality-of-life features.",
        sourceURL: nil
      )
    }
    if u.contains("SEAGLASS") {
      return Summary(
        title: "Pokémon Emerald Seaglass",
        extract: "Pokémon Emerald Seaglass is an Emerald ROM hack that refreshes Hoenn with updated visuals, quality-of-life changes, and a polished classic Emerald experience.",
        sourceURL: nil
      )
    }
    if u.contains("MODERN EMERALD") {
      return Summary(
        title: "Pokémon Modern Emerald",
        extract: "Pokémon Modern Emerald is an Emerald ROM hack that brings newer generation mechanics, Fairy type, and expanded species into the classic Hoenn adventure.",
        sourceURL: nil
      )
    }
    if u.contains("HEART") && u.contains("SOUL") && !u.contains("HEARTGOLD") {
      return Summary(
        title: "Pokémon Heart and Soul",
        extract: "Pokémon Heart and Soul is a pokeemerald-expansion ROM hack featuring Johto and Kanto, follower Pokémon, and a large expanded Pokédex on a modern Emerald engine.",
        sourceURL: nil
      )
    }
    if u.contains("SOULGOLD") || u.contains("SOUL GOLD") || u.contains("SOULDGOLD") {
      return Summary(
        title: "Pokémon SoulGold (GBA)",
        extract: "Pokémon SoulGold is a Game Boy Advance ROM hack that retells the Johto journey on a pokeemerald-expansion engine, with an expanded Pokédex and modern battle features.",
        sourceURL: nil
      )
    }
    if u.contains("ROCKET EDITION") || (u.contains("ROCKET") && u.contains("FIRERED")) {
      return Summary(
        title: "Pokémon FireRed Rocket Edition",
        extract: "Pokémon FireRed Rocket Edition is a FireRed ROM hack where you play as a Team Rocket grunt climbing the organization’s ranks through Kanto.",
        sourceURL: nil
      )
    }
    if u.contains("CRYSTAL ADVANCE") || u.contains("CRYSTALADVANCE") {
      return Summary(
        title: "Pokémon Crystal Advance Redux",
        extract: "Pokémon Crystal Advance Redux is a FireRed-based GBA ROM hack that brings the Johto adventure of Gold, Silver, and Crystal to the Game Boy Advance with updated features and quality-of-life changes.",
        sourceURL: nil
      )
    }
    if u.contains("LAZARUS") {
      return Summary(
        title: "Pokémon Lazarus",
        extract: """
        Pokémon Lazarus (v2.0) is one of the most played modern Emerald ROM hacks — a full pokeemerald-expansion rebuild (boot splash “PRET × RHH”) rather than a patch on retail Emerald. The adventure is set in Ilios, an original region with its own towns and routes (including places like Acrisia City, Sofos City, Port Pello, and the Sea of Asteri), plus a custom region map and orange trainer card unique to the hack.

        Gameplay leans on expansion-era quality of life and depth: a large National Pokédex (species stored by National Dex number, so Kalos starters like Fennekin show up early), physical/special split and Fairy-era battle rules, and day-and-night wild encounters on many outdoor maps. Night runs from 8 PM to 7 AM on the in-game clock, so the same grass can hide a completely different roster after dark.

        Lazarus keeps a familiar Emerald-style save and party structure while expanding bags, dex flags, and battle data for the newer engine — which is why it’s a favorite for long playthroughs and for companions that can read live party, map, and matchup info.
        """,
        sourceURL: nil
      )
    }
    return nil
  }

  // MARK: - Wikipedia

  private func searchWikipedia(_ query: String) async -> String? {
    var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
    components.queryItems = [
      URLQueryItem(name: "action", value: "query"),
      URLQueryItem(name: "list", value: "search"),
      URLQueryItem(name: "srsearch", value: query),
      URLQueryItem(name: "srlimit", value: "8"),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "utf8", value: "1"),
    ]
    guard let url = components.url,
          let obj = try? await getJSON(url),
          let queryObj = obj["query"] as? [String: Any],
          let search = queryObj["search"] as? [[String: Any]] else { return nil }

    let candidates = search.compactMap { $0["title"] as? String }
    if let best = candidates.first(where: { isRelevantWikipediaTitle($0, toQuery: query, displayName: query) }) {
      return best
    }
    return nil
  }

  private func pageSummary(title: String) async -> Summary? {
    let encoded = title
      .replacingOccurrences(of: " ", with: "_")
      .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
    guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)"),
          let obj = try? await getJSON(url) else { return nil }
    let type = obj["type"] as? String
    if type == "disambiguation" { return nil }
    guard let extract = obj["extract"] as? String,
          !extract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let pageTitle = (obj["title"] as? String) ?? title
    let source: URL? = {
      if let s = (obj["content_urls"] as? [String: Any])?["desktop"] as? [String: Any],
         let page = s["page"] as? String {
        return URL(string: page)
      }
      return URL(string: "https://en.wikipedia.org/wiki/\(encoded)")
    }()
    return Summary(title: pageTitle, extract: extract, sourceURL: source)
  }

  private func getJSON(_ url: URL) async throws -> [String: Any] {
    var req = URLRequest(url: url)
    // Wikimedia requires a descriptive User-Agent.
    req.setValue("PocketDex/1.0 (iOS; game library summaries; contact via App Store)", forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(for: req)
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw URLError(.cannotParseResponse)
    }
    return obj
  }

  /// Reject Wikipedia pages that share only “Pokémon” / generic words (e.g. ROWE → Pokopia).
  private func isRelevantWikipediaTitle(_ title: String, toQuery query: String, displayName: String) -> Bool {
    Self.sharesDistinctiveToken(query: displayName.isEmpty ? query : displayName, title: title)
      || Self.sharesDistinctiveToken(query: query, title: title)
  }

  nonisolated private static func sharesDistinctiveToken(query: String, title: String) -> Bool {
    let stop: Set<String> = [
      "pokemon", "pokémon", "version", "game", "video", "the", "and", "gba", "gbc", "nds",
      "edition", "hack", "rom", "fan", "experimental",
    ]
    func tokens(_ s: String) -> Set<String> {
      let cleaned = s.lowercased()
        .replacingOccurrences(of: "é", with: "e")
        .replacingOccurrences(of: ".", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
      return Set(
        cleaned
          .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
          .map(String.init)
          .filter { $0.count >= 3 && !stop.contains($0) }
      )
    }
    let q = tokens(query)
    let t = tokens(title)
    guard !q.isEmpty else { return false }
    return !q.intersection(t).isEmpty
  }

  private func searchQueries(for name: String, console: ConsoleKind?) -> [String] {
    let cleaned = name
      .replacingOccurrences(of: #"[\[\(].*?[\]\)]"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var queries: [String] = []
    let lower = cleaned.lowercased()

    // Common Pokémon retail pairs — Wikipedia uses combined article titles.
    if lower.contains("firered") || lower.contains("fire red") {
      queries.append("Pokémon FireRed and LeafGreen")
    }
    if lower.contains("leafgreen") || lower.contains("leaf green") {
      queries.append("Pokémon FireRed and LeafGreen")
    }
    if lower.contains("heartgold") || lower.contains("heart gold") {
      queries.append("Pokémon HeartGold and SoulSilver")
    }
    if lower.contains("soulsilver") || lower.contains("soul silver") {
      queries.append("Pokémon HeartGold and SoulSilver")
    }
    if lower.contains("ruby") && lower.contains("pokemon") {
      queries.append("Pokémon Ruby and Sapphire")
    }
    if lower.contains("sapphire") && (lower.contains("pokemon") || lower.contains("pokémon")) {
      queries.append("Pokémon Ruby and Sapphire")
    }
    if lower.contains("modern") && lower.contains("emerald") {
      // Fan hack — curated summary handles this; skip retail Emerald Wikipedia.
    } else if lower.contains("emerald") && (lower.contains("pokemon") || lower.contains("pokémon") || console == .gba) {
      queries.append("Pokémon Emerald")
    }
    if (lower.contains("diamond") || lower.contains("pearl")) && (lower.contains("pokemon") || lower.contains("pokémon") || console == .nds) {
      queries.append("Pokémon Diamond and Pearl")
    }
    if lower.contains("platinum") && (lower.contains("pokemon") || lower.contains("pokémon") || console == .nds) {
      queries.append("Pokémon Platinum")
    }
    if lower.contains("black 2") || lower.contains("black2") || lower.contains("white 2") || lower.contains("white2") {
      queries.append("Pokémon Black 2 and White 2")
    } else if lower.contains("black") || lower.contains("white") {
      if lower.contains("pokemon") || lower.contains("pokémon") || console == .nds {
        queries.append("Pokémon Black and White")
      }
    }
    if lower.contains("crystal") && (lower.contains("pokemon") || lower.contains("pokémon") || console == .gbc || console == .gb) {
      queries.append("Pokémon Crystal")
    }
    if lower.contains("gold") && !lower.contains("heart") && !lower.contains("soulgold")
        && (lower.contains("pokemon") || console == .gbc || console == .gb) {
      queries.append("Pokémon Gold and Silver")
    }
    if lower.contains("silver") && !lower.contains("soul") && (lower.contains("pokemon") || console == .gbc || console == .gb) {
      queries.append("Pokémon Gold and Silver")
    }
    if lower.contains("yellow") && (lower.contains("pokemon") || console == .gb || console == .gbc) {
      queries.append("Pokémon Yellow")
    }
    if (lower.contains("red") || lower.contains("blue")) && !lower.contains("firered") && !lower.contains("fire")
        && (lower.contains("pokemon") || console == .gb) {
      queries.append("Pokémon Red and Blue")
    }

    queries.append("\(cleaned) video game")
    if let console {
      queries.append("\(cleaned) \(console.title)")
    }
    queries.append(cleaned)
    // De-dupe while preserving order.
    var seen = Set<String>()
    return queries.filter { seen.insert($0.lowercased()).inserted }
  }
}
