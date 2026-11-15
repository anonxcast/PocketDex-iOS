import Foundation

/// Multi-source in-game screenshots: local play captures → save-state thumbs →
/// Libretro Named_Snaps (retail) → RetroAchievements ImageIngame (hash-matched hacks).
actor GameScreenshotClient {
  static let shared = GameScreenshotClient()

  private let session: URLSession = {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 20
    cfg.httpAdditionalHeaders = [
      "User-Agent": "PocketDex/1.0 (screenshots; personal library)"
    ]
    return URLSession(configuration: cfg)
  }()

  struct Result: Sendable {
    var images: [Data]
    var status: String
  }

  func fetch(
    romURL: URL,
    artworkKey: String,
    romName: String,
    displayName: String,
    console: ConsoleKind,
    limit: Int = 6
  ) async -> Result {
    var out: [Data] = []
    var seen = Set<Int>()
    func append(_ data: Data?) {
      guard let data, data.count > 64, out.count < limit else { return }
      // Fingerprint: length + first/last bytes (avoid hashing full PNGs).
      var hasher = Hasher()
      hasher.combine(data.count)
      hasher.combine(data.prefix(64))
      hasher.combine(data.suffix(64))
      guard seen.insert(hasher.finalize()).inserted else { return }
      out.append(data)
    }

    // 1) Snaps captured from this exact dump while playing.
    let local = await MainActor.run {
      RomArtworkStore.shared.screenshotData(forKey: artworkKey, limit: limit)
    }
    for d in local { append(d) }
    if out.count >= limit {
      return Result(images: out, status: "")
    }

    // 2) Save-state thumbnails — also real frames from this ROM.
    let slots = [RomLibrary.autoSaveSlot] + Array(1...RomLibrary.saveStateSlotCount)
    for slot in slots {
      let url = RomLibrary.stateThumbPath(forRom: romURL, slot: slot)
      append(try? Data(contentsOf: url))
      if out.count >= limit { break }
    }
    if out.count >= limit {
      return Result(images: out, status: "")
    }

    // 3) Libretro Named_Snaps — strict title match (retail / known dumps).
    let libretro = await LibretroArtworkClient.shared.fetchScreenshots(
      for: romName,
      displayName: displayName,
      console: console,
      limit: limit
    )
    for d in libretro { append(d) }
    if out.count >= limit {
      return Result(images: out, status: "")
    }

    // 4) RetroAchievements media (hash → game) — covers Unbound and other RA hacks.
    if await RetroAchievementsClient.shared.isSignedIn() {
      if let ra = try? await RetroAchievementsClient.shared.screenshotData(forRomAt: romURL, limit: limit) {
        for d in ra { append(d) }
      }
    }

    let status: String
    if out.isEmpty {
      status = "No in-game snaps yet. Play the game (or sign in to RetroAchievements) to fill this strip."
    } else {
      status = ""
    }
    return Result(images: Array(out.prefix(limit)), status: status)
  }
}
