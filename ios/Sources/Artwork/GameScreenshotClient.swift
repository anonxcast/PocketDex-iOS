import Foundation
import UIKit

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
      // Drop pure-black / pure-white frames from the old premultiplied thumb bug.
      guard Self.looksLikeRealFrame(data) else { return }
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

  /// Reject frames that are almost entirely black or white (bad capture / blank buffer).
  private static func looksLikeRealFrame(_ data: Data) -> Bool {
    guard let img = UIImage(data: data)?.cgImage else { return false }
    let w = img.width
    let h = img.height
    guard w >= 8, h >= 8 else { return false }
    let sw = min(48, w)
    let sh = min(36, h)
    let bpr = sw * 4
    var buf = [UInt8](repeating: 0, count: bpr * sh)
    guard let ctx = CGContext(
      data: &buf,
      width: sw,
      height: sh,
      bitsPerComponent: 8,
      bytesPerRow: bpr,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return true }
    ctx.interpolationQuality = .low
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: sw, height: sh))
    var sum = 0
    var dark = 0
    var bright = 0
    let n = sw * sh
    for i in stride(from: 0, to: buf.count, by: 4) {
      let y = Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])
      sum += y
      if y < 24 { dark += 1 }
      if y > 750 { bright += 1 }
    }
    let mean = Double(sum) / Double(max(1, n) * 3)
    let darkFrac = Double(dark) / Double(max(1, n))
    let brightFrac = Double(bright) / Double(max(1, n))
    if darkFrac > 0.92 && mean < 12 { return false }
    if brightFrac > 0.92 && mean > 245 { return false }
    return true
  }
}
