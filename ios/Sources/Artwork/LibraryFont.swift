import CoreText
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Library title fonts (covers / banners). Includes bundled pixel faces + user-imported custom fonts.
enum LibraryFontChoice: String, CaseIterable, Identifiable {
  case pressStart
  case silkscreen
  case vt323
  case plex
  case custom

  var id: String { rawValue }

  var title: String {
    switch self {
    case .pressStart: return "Press Start 2P"
    case .silkscreen: return "Silkscreen"
    case .vt323: return "VT323"
    case .plex: return "IBM Plex"
    case .custom: return "Custom"
    }
  }

  var subtitle: String {
    switch self {
    case .pressStart: return "Chunky arcade pixel"
    case .silkscreen: return "Clean bitmap pixel"
    case .vt323: return "CRT terminal style"
    case .plex: return "Default PocketDex sans"
    case .custom: return "Import your own .ttf / .otf"
    }
  }

  /// PostScript / full name used by UIFont(name:).
  var bundledFontName: String? {
    switch self {
    case .pressStart: return "PressStart2P-Regular"
    case .silkscreen: return "Silkscreen-Regular"
    case .vt323: return "VT323-Regular"
    case .plex: return nil
    case .custom: return nil
    }
  }
}

@MainActor
final class LibraryFontStore: ObservableObject {
  static let shared = LibraryFontStore()

  private enum Key {
    static let choice = "settings.libraryFont"
    static let customName = "settings.libraryFont.customName"
  }

  @Published var choice: LibraryFontChoice {
    didSet { UserDefaults.standard.set(choice.rawValue, forKey: Key.choice) }
  }

  /// Registered PostScript name for the imported custom font.
  @Published var customFontName: String? {
    didSet {
      if let customFontName {
        UserDefaults.standard.set(customFontName, forKey: Key.customName)
      } else {
        UserDefaults.standard.removeObject(forKey: Key.customName)
      }
    }
  }

  private init() {
    let raw = UserDefaults.standard.string(forKey: Key.choice) ?? LibraryFontChoice.pressStart.rawValue
    choice = LibraryFontChoice(rawValue: raw) ?? .pressStart
    customFontName = UserDefaults.standard.string(forKey: Key.customName)
    registerCustomFontsOnDisk()
  }

  var customFontsDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let dir = docs.appendingPathComponent("Fonts", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func titleFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    switch choice {
    case .plex:
      return CETheme.sans(size, weight: weight)
    case .custom:
      if let name = customFontName, UIFont(name: name, size: size) != nil {
        return .custom(name, size: size)
      }
      // Fall back to Press Start if custom missing.
      return .custom(LibraryFontChoice.pressStart.bundledFontName!, size: size)
    case .pressStart, .silkscreen, .vt323:
      let name = choice.bundledFontName!
      if UIFont(name: name, size: size) != nil {
        return .custom(name, size: size)
      }
      return CETheme.sans(size, weight: weight)
    }
  }

  /// Pixel faces are often large; scale down slightly for long titles.
  func titleSize(base: CGFloat) -> CGFloat {
    switch choice {
    case .pressStart: return base * 0.72
    case .silkscreen: return base * 0.9
    case .vt323: return base
    case .plex, .custom: return base
    }
  }

  @discardableResult
  func importFont(from source: URL) throws -> String {
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }

    let ext = source.pathExtension.lowercased()
    guard ["ttf", "otf"].contains(ext) else {
      throw ArtworkError.api("Use a .ttf or .otf font file.")
    }

    let dest = customFontsDirectory.appendingPathComponent(source.lastPathComponent)
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: source, to: dest)

    let names = try registerFont(at: dest)
    guard let name = names.first else {
      throw ArtworkError.api("Could not read font name.")
    }
    customFontName = name
    choice = .custom
    return name
  }

  func registerCustomFontsOnDisk() {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(
      at: customFontsDirectory,
      includingPropertiesForKeys: nil
    ) else { return }
    for url in files where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
      _ = try? registerFont(at: url)
    }
  }

  private func registerFont(at url: URL) throws -> [String] {
    var error: Unmanaged<CFError>?
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    if let error { throw error.takeRetainedValue() as Error }

    guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
      return []
    }
    return descriptors.compactMap { desc in
      CTFontDescriptorCopyAttribute(desc, kCTFontNameAttribute) as? String
    }
  }
}

extension UTType {
  static var fontFiles: [UTType] {
    var types: [UTType] = [.data]
    if let ttf = UTType(filenameExtension: "ttf") { types.append(ttf) }
    if let otf = UTType(filenameExtension: "otf") { types.append(otf) }
    return types
  }
}
