import Foundation
import SwiftUI

/// Features unlocked when a ROM is “optimized” for PocketDex.
struct OptimizedRomFeatures: OptionSet, Hashable {
  let rawValue: Int
  static let expand = OptimizedRomFeatures(rawValue: 1 << 0)
  static let companion = OptimizedRomFeatures(rawValue: 1 << 1)
  static let saveEditor = OptimizedRomFeatures(rawValue: 1 << 2)
  static let shaders = OptimizedRomFeatures(rawValue: 1 << 3)

  static let playStack: OptimizedRomFeatures = [.expand, .companion, .saveEditor, .shaders]

  var labels: [String] {
    var out: [String] = []
    if contains(.expand) { out.append("Expand / Zoom") }
    if contains(.companion) {
      out.append("Companion · Smart Island (reactive coach · phrases · tap tips)")
    }
    if contains(.saveEditor) { out.append("Save Editor") }
    if contains(.shaders) { out.append("Shaders") }
    return out
  }
}

enum OptimizedRomFamily: String, CaseIterable, Identifiable {
  case retailGen3 = "Retail Gen 3"
  case fireredHacks = "FireRed hacks"
  case emeraldHacks = "Emerald hacks"
  case gameBoy = "Game Boy / Color"
  case nintendoDS = "Nintendo DS"

  var id: String { rawValue }

  var blurb: String {
    switch self {
    case .retailGen3: return "Official carts — Expand by CRC or soft-map"
    case .fireredHacks: return "BPRE rebuilds & CFRU (Radical Red, Unbound, …)"
    case .emeraldHacks: return "BPEE rebuilds & expansions (Seaglass, …)"
    case .gameBoy: return "GB/GBC with WIDE where tables exist"
    case .nintendoDS: return "melonDS Expand on supported carts"
    }
  }
}

struct OptimizedRomEntry: Identifiable, Hashable {
  let id: String
  let title: String
  let detail: String
  let family: OptimizedRomFamily
  let features: OptimizedRomFeatures
  /// Substrings matched against the library filename (uppercased).
  let fileHints: [String]
  /// If any of these appear in the filename, this entry does not match (avoids false “Optimized”).
  let excludeHints: [String]

  init(
    id: String,
    title: String,
    detail: String,
    family: OptimizedRomFamily,
    features: OptimizedRomFeatures,
    fileHints: [String],
    excludeHints: [String] = []
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.family = family
    self.features = features
    self.fileHints = fileHints
    self.excludeHints = excludeHints
  }
}

/// Single source of truth for Settings › Optimized ROMs and filename → save-editor hints.
enum OptimizedRomCatalog {
  static let all: [OptimizedRomEntry] = [
    // Retail Gen 3
    .init(id: "emerald", title: "Pokémon Emerald", detail: "All languages · TrashMan trimmed dumps",
          family: .retailGen3, features: .playStack, fileHints: ["EMERALD", "ESMERALDA", "SMARAGD", "EMERAUDE", "SMERALDO"]),
    .init(id: "firered", title: "Pokémon FireRed", detail: "USA/Europe rev 0 & 1 + languages",
          family: .retailGen3, features: .playStack, fileHints: ["FIRERED", "FIRE RED", "ROJO FUEGO", "FEUERROTE", "ROUGE FEU"]),
    .init(id: "leafgreen", title: "Pokémon LeafGreen", detail: "USA/Europe rev 0 & 1 + languages",
          family: .retailGen3, features: .playStack, fileHints: ["LEAFGREEN", "LEAF GREEN", "VERDE HOJA", "BLATTGRUENE"]),
    .init(id: "ruby", title: "Pokémon Ruby", detail: "USA rev 0–2 + languages",
          family: .retailGen3, features: .playStack, fileHints: ["RUBY", "RUBI", "RUBIN", "RUBIS", "RUBINO"]),
    .init(id: "sapphire", title: "Pokémon Sapphire", detail: "USA rev 0–2 + languages",
          family: .retailGen3, features: .playStack, fileHints: ["SAPPHIRE", "ZAFIRO", "SAPHIR", "ZAFIRRO", "ZAFFIRO"]),

    // FireRed hacks
    .init(id: "radical_red", title: "Pokémon Radical Red", detail: "v4.1 tables · device dumps aliased",
          family: .fireredHacks, features: .playStack, fileHints: ["RADICAL"]),
    .init(id: "unbound", title: "Pokémon Unbound", detail: "2.1.x · FireRed CFRU save layout",
          family: .fireredHacks, features: .playStack, fileHints: ["UNBOUND"]),
    .init(id: "rocket_edition", title: "FireRed Rocket Edition", detail: "Retail BPRE · Expand + FR save editor + national names",
          family: .fireredHacks, features: .playStack, fileHints: ["ROCKET EDITION", "ROCKET"]),
    .init(id: "crystal_advance_redux", title: "Crystal Advance Redux",
          detail: "BPRE 32 MB · Expand soft-map → FR · CFRU save editor + companion",
          family: .fireredHacks, features: .playStack,
          fileHints: ["CRYSTAL ADVANCE", "ADVANCE REDUX", "CRYSTALADVANCE"]),

    // Emerald hacks
    .init(id: "seaglass", title: "Emerald Seaglass", detail: "v3.0 · Expand + Emerald save format",
          family: .emeraldHacks, features: .playStack, fileHints: ["SEAGLASS"]),
    .init(id: "modern_emerald", title: "Pokémon Modern Emerald",
          detail: "v3.6 · Expand + companion + Modern Emerald save editor",
          family: .emeraldHacks, features: .playStack,
          fileHints: ["MODERN EMERALD"]),
    .init(id: "heart_and_soul", title: "Pokémon Heart and Soul", detail: "v2.0.6 · Expand + HnS save format + masked species HUD",
          family: .emeraldHacks, features: .playStack,
          fileHints: ["HEART AND SOUL", "HEARTSOUL"]),
    // Free Roam GBA (pokehns) — Expand via pk_wide AACBBF26 (not HnS soft-map); companion + HnS save.
    .init(id: "crystal_enhanced", title: "Pokémon Crystal Enhanced",
          detail: "Free Roam (site CRC AACBBF26) · Expand/Zoom + companion + HnS save editor",
          family: .emeraldHacks, features: .playStack,
          fileHints: ["CRYSTAL ENHANCED", "CRYSENHA", "POKECRYSENHA"],
          excludeHints: ["CRYSTAL ADVANCE", "CRYSTALADVANCE"]),
    // Retail / GBC Crystal must not match this GBA Free Roam hack.

    .init(id: "rowe", title: "Pokémon R.O.W.E.", detail: "v2.1.9.1 · Expand/Zoom (EX objects + 12-bit metatiles, Elite Redux–style) + companion + save editor",
          family: .emeraldHacks, features: .playStack,
          fileHints: ["R.O.W.E", "ROWE"]),
    .init(id: "soulgold_gba", title: "Pokémon SoulGold (GBA)", detail: "v1.2.1 · Expand + SoulGold party/battle decode + companion",
          family: .emeraldHacks, features: .playStack,
          fileHints: ["SOULGOLD", "SOUL GOLD", "SOULDGOLD"]),
    .init(id: "lazarus", title: "Pokémon Lazarus", detail: "v2.0 · Expand + companion + Lazarus Emerald save editor",
          family: .emeraldHacks, features: .playStack,
          fileHints: ["LAZARUS"]),
    .init(id: "wishes", title: "Pokémon Wishes of Tomorrow",
          detail: "v1.3.0 · Expand/Zoom + companion + Wishes Emerald save editor",
          family: .emeraldHacks, features: .playStack,
          fileHints: ["WISHES"]),

    // GB / GBC (Expand where pk_wide_gb tables exist — Red/Blue/Green/Yellow / Crystal / Polished)
    .init(id: "polished", title: "Polished Crystal", detail: "3.2.3 CRC · Expand + Gen 2 companion & editor",
          family: .gameBoy, features: .playStack, fileHints: ["POLISHED"]),
    .init(id: "prism", title: "Pokémon Prism",
          detail: "v0.95 build 254 · Expand (Prism WIDE profile) + Gen 2 companion & editor",
          family: .gameBoy, features: .playStack,
          fileHints: ["PRISM", "POKEPRISM", "POKEMON PRISM"]),
    .init(id: "crystal_clear", title: "Pokémon Crystal Clear",
          detail: "Expand via pk_wide_gb (Clear profile) + Gen 2 companion & editor",
          family: .gameBoy, features: .playStack, fileHints: ["CRYSTAL CLEAR"]),
    // Not Crystal Advance / Redux (GBA hacks) — those are separate unoptimized titles.
    .init(id: "crystal", title: "Pokémon Crystal", detail: "English / AU / DE · Expand via pk_wide_gb",
          family: .gameBoy, features: .playStack, fileHints: ["CRYSTAL"],
          excludeHints: ["CRYSTAL ADVANCE", "ADVANCE REDUX", "CRYSTALREDUX", "CRYSTAL ENHANCED", "CRYSENHA", "CRYSTAL CLEAR", "CLEAR", "PRISM"]),
    .init(id: "gold", title: "Pokémon Gold",
          detail: "Companion + Gen 2 save editor · Expand unavailable (no pk_wide_gb row)",
          family: .gameBoy, features: [.companion, .saveEditor, .shaders],
          fileHints: ["GOLD VERSION", "POKEMON GOLD", "POKEMON_GLD"],
          excludeHints: ["HEARTGOLD", "HEART GOLD", "SOULGOLD", "SOUL GOLD"]),
    .init(id: "silver", title: "Pokémon Silver",
          detail: "Companion + Gen 2 save editor · Expand unavailable (no pk_wide_gb row)",
          family: .gameBoy, features: [.companion, .saveEditor, .shaders],
          fileHints: ["SILVER VERSION", "POKEMON SILVER", "POKEMON_SLV"],
          excludeHints: ["SOULSILVER", "SOUL SILVER"]),
    .init(id: "yellow", title: "Pokémon Yellow", detail: "USA/Europe CRC 7d527d62 · Expand via pk_wide_gb",
          family: .gameBoy, features: .playStack, fileHints: ["YELLOW"]),
    .init(id: "red", title: "Pokémon Red", detail: "USA/Europe CRC 9f7fdd53 · Expand via pk_wide_gb",
          family: .gameBoy, features: .playStack, fileHints: ["RED VERSION", "POKEMON RED"],
          excludeHints: ["FIRERED", "FIRE RED", "RADICAL", "ROCKET", "REDUX"]),
    .init(id: "blue", title: "Pokémon Blue", detail: "USA/Europe CRC d6da8a1a · Expand via pk_wide_gb",
          family: .gameBoy, features: .playStack, fileHints: ["BLUE VERSION", "POKEMON BLUE"]),
    .init(id: "green", title: "Pokémon Green (Midori)", detail: "JP Midori CRC baeacd2b · Expand via pk_wide_gb",
          family: .gameBoy, features: .playStack, fileHints: ["MIDORI", "POKEMON GREEN"],
          excludeHints: ["LEAFGREEN", "LEAF GREEN", "EMERALD"]),

    // DS
    .init(id: "heartgold", title: "HeartGold / SoulSilver", detail: "melonDS Expand · Gen 4 save editor",
          family: .nintendoDS, features: [.expand, .companion, .shaders, .saveEditor], fileHints: ["HEARTGOLD", "SOULSILVER", "HEART GOLD", "SOUL SILVER"]),
    .init(id: "platinum", title: "Pokémon Platinum", detail: "melonDS Expand · Gen 4 save editor",
          family: .nintendoDS, features: [.expand, .companion, .shaders, .saveEditor], fileHints: ["PLATINUM"]),
    .init(id: "black_white", title: "Pokémon Black / White",
          detail: "melonDS Expand · Gen 5 companion + save editor",
          family: .nintendoDS, features: .playStack,
          fileHints: ["BLACK VERSION", "WHITE VERSION", "POKEMON BLACK", "POKEMON WHITE"],
          excludeHints: ["BLACK 2", "WHITE 2", "BLACK2", "WHITE2"]),
    .init(id: "black2_white2", title: "Pokémon Black 2 / White 2",
          detail: "melonDS Expand · Gen 5 companion + save editor",
          family: .nintendoDS, features: .playStack,
          fileHints: ["BLACK 2", "WHITE 2", "BLACK2", "WHITE2"]),
  ]

  static var byFamily: [(OptimizedRomFamily, [OptimizedRomEntry])] {
    OptimizedRomFamily.allCases.compactMap { fam in
      let rows = all.filter { $0.family == fam }
      return rows.isEmpty ? nil : (fam, rows)
    }
  }

  /// True when a library filename looks like a known CFRU / expanded-species hack.
  static func usesExpandedSpecies(fileName: String) -> Bool {
    let u = fileName.uppercased()
    if ["RADICAL", "UNBOUND", "SEAGLASS", "ROCKET", "GAIA", "ODYSSEY", "AMETHYST", "IMPERIUM", "CFRU",
        "MODERN EMERALD", "ROWE", "R.O.W.E", "SOULGOLD", "SOUL GOLD", "SOULDGOLD", "HEARTSOUL",
        "LAZARUS", "CRYSTAL ADVANCE", "CRYSTALADVANCE", "ADVANCE REDUX",
        "CRYSTAL ENHANCED", "CRYSENHA"]
      .contains(where: { u.contains($0) }) {
      return true
    }
    // "Heart and Soul" without matching DS HeartGold.
    if u.contains("HEART") && u.contains("SOUL") && !u.contains("HEARTGOLD") { return true }
    return false
  }

  static func entry(matchingFileName fileName: String) -> OptimizedRomEntry? {
    let u = fileName.uppercased()
    // Prefer longer / more specific hints first (e.g. RADICAL before RED, LEAFGREEN before GREEN).
    var best: (OptimizedRomEntry, Int)?
    for e in all {
      if e.excludeHints.contains(where: { u.contains($0) }) { continue }
      for hint in e.fileHints where u.contains(hint) {
        let score = hint.count
        if best == nil || score > best!.1 { best = (e, score) }
      }
    }
    return best?.0
  }

  /// Match library filename, then display name (custom titles still count).
  static func entry(fileName: String, displayName: String? = nil) -> OptimizedRomEntry? {
    if let e = entry(matchingFileName: fileName) { return e }
    if let displayName, displayName != fileName,
       let e = entry(matchingFileName: displayName) {
      return e
    }
    return nil
  }

  static func isOptimized(fileName: String, displayName: String? = nil) -> Bool {
    entry(fileName: fileName, displayName: displayName) != nil
  }
}

/// Compact library / game-page banner: Optimized vs Not optimized.
struct OptimizedStatusBadge: View {
  let optimized: Bool
  var compact: Bool = false

  private var fill: Color {
    optimized
      ? Color(red: 0.22, green: 0.78, blue: 0.52)
      : Color(red: 0.45, green: 0.45, blue: 0.48)
  }

  var body: some View {
    HStack(spacing: compact ? 3 : 4) {
      Image(systemName: optimized ? "sparkles" : "minus.circle")
        .font(.system(size: compact ? 8 : 9, weight: .bold))
      Text(optimized ? "OPTIMIZED" : "NOT OPTIMIZED")
        .font(CETheme.mono(compact ? 7 : 8))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
    .foregroundStyle(optimized ? Color.black.opacity(0.88) : CETheme.text.opacity(0.9))
    .padding(.horizontal, compact ? 6 : 7)
    .padding(.vertical, compact ? 3 : 4)
    .background(fill.opacity(optimized ? 0.95 : 0.75), in: Capsule())
    .overlay(
      Capsule()
        .stroke(fill.opacity(0.95), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    .accessibilityLabel(optimized ? "Optimized" : "Not optimized")
  }
}
