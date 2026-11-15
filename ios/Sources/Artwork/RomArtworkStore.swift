import Foundation
import UIKit

enum RomArtworkKind: String, CaseIterable, Identifiable {
  case cover, banner, icon, logo

  var id: String { rawValue }

  var title: String {
    switch self {
    case .cover: return "Cover"
    case .banner: return "Banner"
    case .icon: return "Icon"
    case .logo: return "Logo"
    }
  }

  var subtitle: String {
    switch self {
    case .cover: return "Box art for the portrait grid"
    case .banner: return "Wide hero for landscape"
    case .icon: return "Small square badge"
    case .logo: return "Game logo — replaces the title text when set"
    }
  }

  var systemImage: String {
    switch self {
    case .cover: return "rectangle.portrait.fill"
    case .banner: return "rectangle.fill"
    case .icon: return "app.fill"
    case .logo: return "textformat"
    }
  }

  /// Preferred display aspect (width / height).
  var aspectRatio: CGFloat {
    switch self {
    case .cover: return 2.0 / 3.0
    case .banner: return 3.0 / 1.0
    case .icon: return 1.0
    // Wider cells, not ultra-flat — logos read large in the picker grid.
    case .logo: return 2.2 / 1.0
    }
  }

  fileprivate var fileBase: String { rawValue }
}

struct RomArtworkMeta: Codable, Equatable {
  var steamGridGameId: Int?
  var steamGridGameName: String?
  /// Custom library title; nil / empty → use the ROM filename.
  var displayName: String?
  /// Bumped only when the user edits/clears `displayName` — scrapes must not touch this.
  var displayNameSetAt: Date?
  /// Cached Wikipedia (or similar) blurb for the game page.
  var summary: String?
  var summaryTitle: String?
  var updatedAt: Date?

  /// Merge local + remote artwork meta. Newer `updatedAt` gap-fills artwork fields;
  /// library titles follow `displayNameSetAt` so SteamGrid/sync cannot erase renames.
  static func merging(_ a: RomArtworkMeta, _ b: RomArtworkMeta) -> RomArtworkMeta {
    let aTime = a.updatedAt ?? .distantPast
    let bTime = b.updatedAt ?? .distantPast
    let aNewer = aTime >= bTime
    let newer = aNewer ? a : b
    let older = aNewer ? b : a

    var out = newer
    out.steamGridGameId = newer.steamGridGameId ?? older.steamGridGameId
    out.steamGridGameName = Self.preferNonEmpty(newer.steamGridGameName, older.steamGridGameName)
    out.summary = Self.preferNonEmpty(newer.summary, older.summary)
    out.summaryTitle = Self.preferNonEmpty(newer.summaryTitle, older.summaryTitle)

    let aStamp = a.displayNameStamp
    let bStamp = b.displayNameStamp
    if let aStamp, let bStamp {
      if aStamp >= bStamp {
        out.displayName = Self.normalizedDisplayName(a.displayName)
        out.displayNameSetAt = a.displayNameSetAt ?? aStamp
      } else {
        out.displayName = Self.normalizedDisplayName(b.displayName)
        out.displayNameSetAt = b.displayNameSetAt ?? bStamp
      }
    } else if let aStamp {
      out.displayName = Self.normalizedDisplayName(a.displayName)
      out.displayNameSetAt = a.displayNameSetAt ?? aStamp
    } else if let bStamp {
      out.displayName = Self.normalizedDisplayName(b.displayName)
      out.displayNameSetAt = b.displayNameSetAt ?? bStamp
    } else {
      out.displayName = nil
      out.displayNameSetAt = nil
    }

    out.updatedAt = max(aTime, bTime)
    return out
  }

  /// User rename/clear timestamp; legacy metas with a title fall back to `updatedAt`.
  fileprivate var displayNameStamp: Date? {
    if let displayNameSetAt { return displayNameSetAt }
    if Self.normalizedDisplayName(displayName) != nil { return updatedAt ?? .distantPast }
    return nil
  }

  private static func normalizedDisplayName(_ raw: String?) -> String? {
    let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return t.isEmpty ? nil : t
  }

  private static func preferNonEmpty(_ primary: String?, _ fallback: String?) -> String? {
    if let n = normalizedDisplayName(primary) { return n }
    return normalizedDisplayName(fallback)
  }
}

/// On-disk artwork for each ROM under Documents/Artwork/<romKey>/.
@MainActor
final class RomArtworkStore: ObservableObject {
  static let shared = RomArtworkStore()

  /// Bumps whenever art changes so the library refreshes.
  @Published private(set) var revision: Int = 0

  private let cache = NSCache<NSString, UIImage>()
  private let fm = FileManager.default

  var rootDirectory: URL {
    let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
    let root = docs.appendingPathComponent("Artwork", isDirectory: true)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  func directory(forKey key: String) -> URL {
    let dir = rootDirectory.appendingPathComponent(key, isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func imageURL(forKey key: String, kind: RomArtworkKind) -> URL? {
    let dir = directory(forKey: key)
    for ext in ["jpg", "jpeg", "png", "webp"] {
      let url = dir.appendingPathComponent("\(kind.fileBase).\(ext)")
      if fm.fileExists(atPath: url.path) { return url }
    }
    return nil
  }

  func hasArtwork(forKey key: String, kind: RomArtworkKind) -> Bool {
    imageURL(forKey: key, kind: kind) != nil
  }

  func image(forKey key: String, kind: RomArtworkKind) -> UIImage? {
    let cacheKey = "\(key)/\(kind.rawValue)" as NSString
    if let cached = cache.object(forKey: cacheKey) { return cached }
    guard let url = imageURL(forKey: key, kind: kind),
          let data = try? Data(contentsOf: url),
          let img = UIImage(data: data) else { return nil }
    cache.setObject(img, forKey: cacheKey)
    return img
  }

  /// Cover for grid; banner for landscape with cover fallback; icon with cover fallback.
  /// Logo never falls back — missing logo keeps the text title.
  func displayImage(forKey key: String, preferred: RomArtworkKind) -> UIImage? {
    if let img = image(forKey: key, kind: preferred) { return img }
    switch preferred {
    case .banner:
      return image(forKey: key, kind: .cover)
    case .icon:
      return image(forKey: key, kind: .cover)
    case .cover, .logo:
      return nil
    }
  }

  @discardableResult
  func save(imageData: Data, forKey key: String, kind: RomArtworkKind) throws -> URL {
    let dir = directory(forKey: key)
    let dest: URL
    // Logos need transparency — keep PNG. Other kinds prefer JPEG for size.
    if kind == .logo, let ui = UIImage(data: imageData) {
      for ext in ["jpg", "jpeg", "webp"] {
        try? fm.removeItem(at: dir.appendingPathComponent("\(kind.fileBase).\(ext)"))
      }
      dest = dir.appendingPathComponent("\(kind.fileBase).png")
      let png = ui.pngData() ?? imageData
      try png.write(to: dest, options: .atomic)
      cache.setObject(ui, forKey: "\(key)/\(kind.rawValue)" as NSString)
    } else if let ui = UIImage(data: imageData),
              let jpeg = ui.jpegData(compressionQuality: 0.88) {
      dest = dir.appendingPathComponent("\(kind.fileBase).jpg")
      for ext in ["png", "jpeg", "webp"] {
        try? fm.removeItem(at: dir.appendingPathComponent("\(kind.fileBase).\(ext)"))
      }
      try jpeg.write(to: dest, options: .atomic)
      cache.setObject(ui, forKey: "\(key)/\(kind.rawValue)" as NSString)
    } else {
      dest = dir.appendingPathComponent("\(kind.fileBase).png")
      try imageData.write(to: dest, options: .atomic)
      if let ui = UIImage(data: imageData) {
        cache.setObject(ui, forKey: "\(key)/\(kind.rawValue)" as NSString)
      }
    }
    bump()
    return dest
  }

  @discardableResult
  func save(uiImage: UIImage, forKey key: String, kind: RomArtworkKind) throws -> URL {
    guard let data = uiImage.jpegData(compressionQuality: 0.88) ?? uiImage.pngData() else {
      throw ArtworkError.encodeFailed
    }
    return try save(imageData: data, forKey: key, kind: kind)
  }

  func clear(forKey key: String, kind: RomArtworkKind?) {
    let dir = directory(forKey: key)
    if let kind {
      for ext in ["jpg", "jpeg", "png", "webp"] {
        try? fm.removeItem(at: dir.appendingPathComponent("\(kind.fileBase).\(ext)"))
      }
      cache.removeObject(forKey: "\(key)/\(kind.rawValue)" as NSString)
    } else {
      try? fm.removeItem(at: dir)
      for k in RomArtworkKind.allCases {
        cache.removeObject(forKey: "\(key)/\(k.rawValue)" as NSString)
      }
    }
    bump()
  }

  func meta(forKey key: String) -> RomArtworkMeta? {
    let url = directory(forKey: key).appendingPathComponent("meta.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(RomArtworkMeta.self, from: data)
  }

  func saveMeta(_ meta: RomArtworkMeta, forKey key: String) {
    var m = meta
    m.updatedAt = Date()
    let url = directory(forKey: key).appendingPathComponent("meta.json")
    guard let data = try? JSONEncoder().encode(m) else { return }
    try? data.write(to: url, options: .atomic)
    bump()
  }

  func displayName(forKey key: String) -> String? {
    let name = meta(forKey: key)?.displayName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (name?.isEmpty == false) ? name : nil
  }

  func setDisplayName(_ name: String?, forKey key: String) {
    var m = meta(forKey: key) ?? RomArtworkMeta()
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    m.displayName = trimmed.isEmpty ? nil : trimmed
    m.displayNameSetAt = Date()
    saveMeta(m, forKey: key)
  }

  /// Absolute path to `Artwork/<key>/meta.json` (created if needed).
  func metaFileURL(forKey key: String) -> URL {
    directory(forKey: key).appendingPathComponent("meta.json")
  }

  /// After Google Drive restores Artwork files, drop the in-memory image cache.
  func reloadFromDisk() {
    cache.removeAllObjects()
    bump()
  }

  // MARK: - In-game screenshots (captured while playing)

  private static let maxStoredScreenshots = 8

  func screenshotsDirectory(forKey key: String) -> URL {
    let dir = directory(forKey: key).appendingPathComponent("snaps", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func screenshotURLs(forKey key: String) -> [URL] {
    let dir = screenshotsDirectory(forKey: key)
    let urls = (try? fm.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    )) ?? []
    return urls
      .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
      .sorted { a, b in
        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return da > db
      }
  }

  func screenshotData(forKey key: String, limit: Int = 6) -> [Data] {
    Array(screenshotURLs(forKey: key).prefix(limit)).compactMap { try? Data(contentsOf: $0) }
  }

  /// Keep the newest frames from this dump for the game page (FIFO capped).
  @discardableResult
  func appendScreenshot(imageData: Data, forKey key: String) -> URL? {
    guard !imageData.isEmpty else { return nil }
    let dir = screenshotsDirectory(forKey: key)
    let name = String(format: "snap_%lld.png", Int64(Date().timeIntervalSince1970 * 1000))
    let dest = dir.appendingPathComponent(name)
    do {
      try imageData.write(to: dest, options: .atomic)
    } catch {
      return nil
    }
    let existing = screenshotURLs(forKey: key)
    if existing.count > Self.maxStoredScreenshots {
      for old in existing.suffix(from: Self.maxStoredScreenshots) {
        try? fm.removeItem(at: old)
      }
    }
    bump()
    return dest
  }

  @discardableResult
  func appendScreenshot(uiImage: UIImage, forKey key: String) -> URL? {
    guard let data = uiImage.pngData() ?? uiImage.jpegData(compressionQuality: 0.9) else { return nil }
    return appendScreenshot(imageData: data, forKey: key)
  }

  private func bump() {
    revision &+= 1
  }
}

enum ArtworkError: LocalizedError {
  case encodeFailed
  case downloadFailed
  case noAPIKey
  case api(String)

  var errorDescription: String? {
    switch self {
    case .encodeFailed: return "Could not encode image."
    case .downloadFailed: return "Could not download image."
    case .noAPIKey: return "Add a SteamGridDB API key in Settings."
    case .api(let msg): return msg
    }
  }
}

extension RomItem {
  /// Stable folder name under Artwork/ (filename + size so renames of unrelated files don’t collide).
  var artworkKey: String {
    let stem = url.deletingPathExtension().lastPathComponent
    let safe = stem
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return "\(safe)_\(byteCount)"
  }

  /// Pause/resume identity — Unicode-normalized so NFD/NFC path variants of the same ROM match.
  var sessionKey: String {
    let stem = url.deletingPathExtension().lastPathComponent
      .precomposedStringWithCanonicalMapping
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return "\(stem)_\(byteCount)"
  }

  /// Library title (custom name if set, otherwise the ROM filename).
  @MainActor
  var displayName: String {
    RomArtworkStore.shared.displayName(forKey: artworkKey) ?? name
  }
}
