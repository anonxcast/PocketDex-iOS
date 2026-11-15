import Foundation
import UniformTypeIdentifiers

struct RomItem: Identifiable, Hashable {
  let id: URL
  let name: String
  let url: URL
  let byteCount: Int64
  var console: ConsoleKind? { ConsoleKind.from(romExtension: url.pathExtension) }
}

enum RomLibrary {
  static let supportedExtensions: Set<String> = [
    "gba", "gbc", "gb", "nds", "zip", "7z", "deltaskin"
  ]

  static var romsDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let roms = docs.appendingPathComponent("ROMs", isDirectory: true)
    try? FileManager.default.createDirectory(at: roms, withIntermediateDirectories: true)
    return roms
  }

  static var savesDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let saves = docs.appendingPathComponent("Saves", isDirectory: true)
    try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
    return saves
  }

  static var statesDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let states = docs.appendingPathComponent("States", isDirectory: true)
    try? FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
    return states
  }

  static var contentTypes: [UTType] {
    var types: [UTType] = [.data, .zip]
    for ext in ["gba", "gbc", "gb", "nds", "7z", "deltaskin"] {
      if let t = UTType(filenameExtension: ext) { types.append(t) }
    }
    return types
  }

  static func listRoms() -> [RomItem] {
    let fm = FileManager.default
    guard let urls = try? fm.contentsOfDirectory(
      at: romsDirectory,
      includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    return urls.compactMap { url in
      let ext = url.pathExtension.lowercased()
      // Only list extracted carts — zip/7z are imported by extracting a ROM first.
      guard ["gba", "gbc", "gb", "nds"].contains(ext) else { return nil }
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
      guard values?.isRegularFile == true else { return nil }
      return RomItem(
        id: url,
        name: url.deletingPathExtension().lastPathComponent,
        url: url,
        byteCount: Int64(values?.fileSize ?? 0)
      )
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  @discardableResult
  static func importFile(from source: URL) throws -> URL {
    let ext = source.pathExtension.lowercased()
    if ext == "deltaskin" {
      _ = try DeltaSkinManager.importSkin(from: source)
      return source
    }
    if ext == "7z" {
      throw RomImportError.unsupportedArchive("7z — unzip the ROM on a computer first, then import the .nds/.gba/.gb/.gbc file")
    }
    guard supportedExtensions.contains(ext) else {
      throw RomImportError.unsupportedType(ext)
    }

    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }

    if ext == "zip" {
      return try importZipRom(from: source)
    }

    let dest = uniqueDestination(for: source.lastPathComponent)
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    let data = try Data(contentsOf: source, options: [.mappedIfSafe])
    try data.write(to: dest, options: [.atomic])
    DeletedCloudNames.unmark(dest.lastPathComponent)
    return dest
  }

  /// Unzips an archive and imports the first playable ROM (`.gb` / `.gbc` / `.gba` / `.nds`).
  private static func importZipRom(from source: URL) throws -> URL {
    let fm = FileManager.default
    let staging = fm.temporaryDirectory.appendingPathComponent("pd-rom-zip-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: staging) }

    let tmpZip = staging.appendingPathComponent("in.zip")
    try Data(contentsOf: source, options: [.mappedIfSafe]).write(to: tmpZip, options: [.atomic])
    guard pk_unzip(tmpZip.path, staging.path) else {
      throw RomImportError.badArchive
    }

    let playable = ["nds", "gba", "gbc", "gb"]
    var found: URL?
    if let enumerator = fm.enumerator(at: staging, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
      for case let url as URL in enumerator {
        let e = url.pathExtension.lowercased()
        guard playable.contains(e) else { continue }
        // Prefer NDS when multiple (common multi-rom packs still get one cart).
        if found == nil || (e == "nds" && found?.pathExtension.lowercased() != "nds") {
          found = url
        }
      }
    }
    guard let rom = found else { throw RomImportError.noRomInArchive }

    let dest = uniqueDestination(for: rom.lastPathComponent)
    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
    try fm.copyItem(at: rom, to: dest)
    DeletedCloudNames.unmark(dest.lastPathComponent)
    return dest
  }

  static func savePath(forRom romURL: URL) -> URL {
    savesDirectory.appendingPathComponent(romURL.deletingPathExtension().lastPathComponent + ".sav")
  }

  /// Manual slots are 1…saveStateSlotCount; slot 0 is the dedicated Auto slot.
  static let saveStateSlotCount = 8
  static let autoSaveSlot = 0

  static func isValidSaveSlot(_ slot: Int) -> Bool {
    slot == autoSaveSlot || (1...saveStateSlotCount).contains(slot)
  }

  private static func stateStem(forRom romURL: URL) -> String {
    romURL.deletingPathExtension().lastPathComponent
      .precomposedStringWithCanonicalMapping
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
  }

  /// Instant save-state path (0 = Auto, 1…N = manual).
  static func statePath(forRom romURL: URL, slot: Int) -> URL {
    statesDirectory.appendingPathComponent("\(stateStem(forRom: romURL)).ss\(slot)")
  }

  /// PNG thumbnail written beside each save state.
  static func stateThumbPath(forRom romURL: URL, slot: Int) -> URL {
    statesDirectory.appendingPathComponent("\(stateStem(forRom: romURL)).ss\(slot).png")
  }

  private static func uniqueDestination(for filename: String) -> URL {
    var dest = romsDirectory.appendingPathComponent(filename)
    if !FileManager.default.fileExists(atPath: dest.path) { return dest }
    let base = (filename as NSString).deletingPathExtension
    let ext = (filename as NSString).pathExtension
    var i = 2
    while true {
      dest = romsDirectory.appendingPathComponent("\(base) \(i).\(ext)")
      if !FileManager.default.fileExists(atPath: dest.path) { return dest }
      i += 1
    }
  }

  /// Removes the ROM plus its battery save, save states/thumbs, and library artwork.
  /// Also tombstones + purges matching Google Drive copies so auto-sync cannot restore them.
  static func deleteGame(_ rom: RomItem) throws {
    let fm = FileManager.default
    let key = rom.artworkKey
    let romName = rom.url.lastPathComponent
    var related: [String] = []
    if fm.fileExists(atPath: rom.url.path) {
      try fm.removeItem(at: rom.url)
    }
    let sav = savePath(forRom: rom.url)
    if fm.fileExists(atPath: sav.path) {
      related.append(sav.lastPathComponent)
      try fm.removeItem(at: sav)
    }
    let stem = stateStem(forRom: rom.url)
    if let urls = try? fm.contentsOfDirectory(at: statesDirectory, includingPropertiesForKeys: nil) {
      for url in urls where url.lastPathComponent.hasPrefix(stem + ".ss") {
        related.append(url.lastPathComponent)
        try? fm.removeItem(at: url)
      }
    }
    Task { @MainActor in
      RomArtworkStore.shared.clear(forKey: key, kind: nil)
      RomArtworkStore.shared.setDisplayName(nil, forKey: key)
      await GoogleDriveSync.shared.purgeDeletedGame(
        romFileName: romName,
        relatedNames: related,
        artworkKey: key
      )
    }
  }
}

enum RomImportError: LocalizedError {
  case unsupportedType(String)
  case unsupportedArchive(String)
  case badArchive
  case noRomInArchive
  var errorDescription: String? {
    switch self {
    case .unsupportedType(let ext):
      return "Unsupported file type .\(ext)."
    case .unsupportedArchive(let detail):
      return "Can't import \(detail)."
    case .badArchive:
      return "Couldn't unzip that archive."
    case .noRomInArchive:
      return "No .gb / .gbc / .gba / .nds ROM found inside the zip."
    }
  }
}
