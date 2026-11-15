import Foundation
import UniformTypeIdentifiers

struct DeltaSkinItem: Identifiable, Hashable {
  let id: URL
  let name: String
  let url: URL
  let console: ConsoleKind
  let extractedDirectory: URL
}

enum DeltaSkinManager {
  static var skinsDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let dir = docs.appendingPathComponent("Skins", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static var contentTypes: [UTType] {
    var types: [UTType] = [.zip, .data]
    if let skin = UTType(filenameExtension: "deltaskin") { types.append(skin) }
    return types
  }

  private static func preferenceKey(for console: ConsoleKind) -> String {
    "selectedDeltaSkin.\(console.rawValue)"
  }

  /// nil / missing = skins disabled (use default virtual pad)
  static func selectedSkin(for console: ConsoleKind) -> DeltaSkinItem? {
    guard let path = UserDefaults.standard.string(forKey: preferenceKey(for: console)), !path.isEmpty else {
      return nil
    }
    return listSkins(for: console).first(where: {
      $0.extractedDirectory.path == path || $0.url.path == path
    })
  }

  static var isSkinEnabled: Bool {
    get { UserDefaults.standard.object(forKey: "deltaSkinsEnabled") as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: "deltaSkinsEnabled") }
  }

  static func activeSkin(for console: ConsoleKind) -> DeltaSkinItem? {
    guard isSkinEnabled else { return nil }
    return selectedSkin(for: console)
  }

  static func select(_ skin: DeltaSkinItem?) {
    guard let skin else { return }
    // Must match the path used in listSkins / UI comparison.
    let path = skin.extractedDirectory.path
    UserDefaults.standard.set(path, forKey: preferenceKey(for: skin.console))
    UserDefaults.standard.synchronize()
    isSkinEnabled = true
  }

  static func disableSkins() {
    isSkinEnabled = false
  }

  static func clearSelection(for console: ConsoleKind) {
    UserDefaults.standard.removeObject(forKey: preferenceKey(for: console))
    UserDefaults.standard.synchronize()
  }

  static func delete(_ skin: DeltaSkinItem) throws {
    for kind in ConsoleKind.allCases {
      if selectedSkin(for: kind)?.id == skin.id {
        clearSelection(for: kind)
      }
    }
    if FileManager.default.fileExists(atPath: skin.extractedDirectory.path) {
      try FileManager.default.removeItem(at: skin.extractedDirectory)
    }
  }

  static func listSkins(for console: ConsoleKind? = nil) -> [DeltaSkinItem] {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: skinsDirectory,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    return urls.compactMap { dir -> DeltaSkinItem? in
      var isDir: ObjCBool = false
      guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
      let infoURL = dir.appendingPathComponent("info.json")
      guard let data = try? Data(contentsOf: infoURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
      let gameType = (json["gameTypeIdentifier"] as? String) ?? ""
      guard let kind = ConsoleKind.allCases.first(where: { $0.deltaGameType == gameType })
              ?? inferConsole(from: gameType) else { return nil }
      if let console, kind != console { return nil }
      let name = (json["name"] as? String) ?? dir.lastPathComponent
      return DeltaSkinItem(id: dir, name: name, url: dir, console: kind, extractedDirectory: dir)
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  private static func inferConsole(from gameType: String) -> ConsoleKind? {
    let t = gameType.lowercased()
    if t.contains("gba") { return .gba }
    if t.contains("gbc") { return .gbc }
    if t.contains(".gb") || t.hasSuffix("gb") { return .gb }
    if t.contains(".ds") || t.contains("nds") { return .nds }
    return nil
  }

  @discardableResult
  static func importSkin(from source: URL) throws -> DeltaSkinItem {
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }

    let ext = source.pathExtension.lowercased()
    guard ext == "deltaskin" || ext == "zip" else { throw SkinImportError.unsupported }

    let tmpZip = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".deltaskin")
    try Data(contentsOf: source, options: [.mappedIfSafe]).write(to: tmpZip, options: [.atomic])
    defer { try? FileManager.default.removeItem(at: tmpZip) }

    let staging = FileManager.default.temporaryDirectory.appendingPathComponent("skin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    guard pk_unzip(tmpZip.path, staging.path) else { throw SkinImportError.invalidSkin }

    let root = findInfoDirectory(in: staging) ?? staging
    let infoURL = root.appendingPathComponent("info.json")
    guard let infoData = try? Data(contentsOf: infoURL),
          let json = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] else {
      throw SkinImportError.invalidSkin
    }
    let gameType = (json["gameTypeIdentifier"] as? String) ?? ""
    guard let kind = ConsoleKind.allCases.first(where: { $0.deltaGameType == gameType })
            ?? inferConsole(from: gameType) else {
      throw SkinImportError.unknownConsole(gameType)
    }
    let name = (json["name"] as? String) ?? source.deletingPathExtension().lastPathComponent
    let dest = uniqueSkinDirectory(named: name)
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: root, to: dest)
    let item = DeltaSkinItem(id: dest, name: name, url: dest, console: kind, extractedDirectory: dest)
    select(item)
    return item
  }

  private static func uniqueSkinDirectory(named name: String) -> URL {
    let safe = name.replacingOccurrences(of: "/", with: "-")
    var dest = skinsDirectory.appendingPathComponent(safe, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dest.path) { return dest }
    var i = 2
    while true {
      dest = skinsDirectory.appendingPathComponent("\(safe) \(i)", isDirectory: true)
      if !FileManager.default.fileExists(atPath: dest.path) { return dest }
      i += 1
    }
  }

  private static func findInfoDirectory(in root: URL) -> URL? {
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("info.json").path) { return root }
    guard let kids = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
    return kids.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("info.json").path) }
  }
}

enum SkinImportError: LocalizedError {
  case unsupported, invalidSkin, unknownConsole(String)
  var errorDescription: String? {
    switch self {
    case .unsupported: return "Expected a .deltaskin file."
    case .invalidSkin: return "That skin is missing info.json or could not be unpacked."
    case .unknownConsole(let t): return "Unsupported skin console: \(t)"
    }
  }
}
