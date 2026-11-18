import CryptoKit
import Foundation

enum Gen3Game: String {
  case emerald
  case fireRed
  case unbound
}

/// RAM globals + save-block offsets for one Gen 3 game (from upstream gamedata/gen3/*.toml).
struct NativeConfig {
  var id: String
  var displayName: String
  var game: Gen3Game
  var tables: Gen3Tables

  var playerParty: UInt32
  var playerPartyCount: UInt32
  var battleMons: UInt32
  var battlerPositions: UInt32
  var battlersCount: UInt32
  var battleTypeFlags: UInt32
  var gMain: UInt32
  var saveBlock1Ptr: UInt32
  var saveBlock2Ptr: UInt32
  var mapHeader: UInt32
  var bagPockets: UInt32
  var bagPocketCount: Int
  /// SaveBlock2 offset of the u32 encryption key (bag quantities / money XOR its low bits). nil = R/S plain.
  var encryptionKeyOff: UInt32?
  /// SaveBlock1 offset of money (XOR encryption key when present).
  var moneyOff: UInt32
  /// bagPocketOrder[p] = stable `Gen3Pocket` id that gBagPockets[p] holds in this engine.
  var bagPocketOrder: [Int]

  /// When true, saveBlock1Ptr / saveBlock2Ptr are the blocks themselves (Ruby/Sapphire), not pointers.
  var staticSaveBlocks: Bool = false

  /// SaveBlock1 offset of `pos` (x u16, y u16, mapGroup u8, mapNum u8).
  var saveBlock1PosOff: UInt32 = 0
  /// gMain.inBattle byte (bit 1).
  var inBattleOff: UInt32 = 0x439
  /// gMain vblank / frame counter.
  var frameCounterOff: UInt32 = 0x24

  /// gEnemyParty (6 x monStride); 0 = not known for this game.
  var enemyParty: UInt32 = 0

  /// gBattleMons entry layout (vanilla 0x58 vs expansion 0x60 / HnS 0x88 / SoulGold 0x98).
  var battleMonLayout: BattleMonLayout = .vanilla

  /// Bytes per party mon in EWRAM (100 vanilla; 96 SoulGold; 0x4C ROWE).
  var monStride: Int = Gen3Const.monStructSize
  /// How to decode party / enemy party bytes.
  var partyMonKind: PartyMonKind = .vanilla
  /// Expansion bit-packing (species:11|tera:5, moves:11, pp:7). Default = full u16/u8.
  var speciesMask: Int = 0xFFFF
  var moveMask: Int = 0xFFFF
  var ppMask: Int = 0xFF

  // Pokédex flag layout (struct Pokedex in SaveBlock2 + sb2DexOff; anti-cheat copies of `seen` in SaveBlock1).
  var dexEnabled: Bool = false
  var sb2DexOff: UInt32 = 0x18
  /// Where `dexSeenOff` / `dexCaughtOff` are relative to (or absolute for `.fixed`).
  var dexFlagBlock: DexFlagBlock = .saveBlock2
  var dexSeenOff: UInt32 = 0x5C
  var dexCaughtOff: UInt32 = 0x28
  var dexBytes: Int = 52
  var dexSeenCopies: [UInt32] = []
  var dexNationalMagicOff: Int = 3
  var dexNationalMagic: UInt8 = 0xB9
  var dexNationalCount: Int = 386

  var shinyBelow: Int = Gen3Const.shinyBelow

  /// SoulGold / Team Rocket V3 pack `regionMapSectionId` as u16 at mapHeader+0x14 (mapType at +0x18).
  var mapSecWide: Bool = false
}

/// Matches Android `DexFlagBlock` — expansion / CFRU put flags in SaveBlock1.
enum DexFlagBlock: String {
  case saveBlock2
  case saveBlock1
  /// Absolute EWRAM addresses in dexSeenOff / dexCaughtOff (e.g. Gaia).
  case fixed
}

/// Whole-file SHA-1 helpers. GBA detection masks the cart GPIO/RTC hole (0xC4…0xC9);
/// GB/GBC must use the plain file hash — those bytes are real ROM data (e.g. Polished Crystal).
enum RomSHA1 {
  /// GBA: GPIO/RTC hole zeroed — matches Android `sha1HexChunked`.
  static func hex(of url: URL) -> String? { hex(of: url, maskGpioHole: true) }

  /// GB/GBC: plain file SHA-1 (no GPIO mask).
  static func hexPlain(of url: URL) -> String? { hex(of: url, maskGpioHole: false) }

  static func hex(of url: URL, maskGpioHole: Bool) -> String? {
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return nil }
    let needsMask = maskGpioHole && data.count > 0xCA && (0xC4..<0xCA).contains(where: { data[$0] != 0 })
    let digest: Insecure.SHA1Digest
    if needsMask {
      var copy = data
      for i in 0xC4..<0xCA { copy[i] = 0 }
      digest = Insecure.SHA1.hash(data: copy)
    } else {
      digest = Insecure.SHA1.hash(data: data)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

enum Gen3Config {
  static let emeraldPocketOrder = [Gen3Pocket.items, Gen3Pocket.pokeBalls, Gen3Pocket.tmHm, Gen3Pocket.berries, Gen3Pocket.keyItems]
  static let fireRedPocketOrder = [Gen3Pocket.items, Gen3Pocket.keyItems, Gen3Pocket.pokeBalls, Gen3Pocket.tmHm, Gen3Pocket.berries]

  /// Convenience aliases over generated gamedata configs (see `Gen3ConfigsGen`).
  static var emerald: NativeConfig { Gen3ConfigsGen.emerald_retail }
  static var fireRedRev0: NativeConfig { Gen3ConfigsGen.firered_rev0 }
  static var fireRedRev1: NativeConfig { Gen3ConfigsGen.firered_rev1 }
  static var leafGreen: NativeConfig { Gen3ConfigsGen.leafgreen_rev0 }
  static var unbound: NativeConfig { Gen3ConfigsGen.unbound_with_dex }
  static var emeraldSeaglass: NativeConfig { Gen3ConfigsGen.emerald_seaglass }
  static var rubySapphire: NativeConfig { Gen3ConfigsGen.ruby }

  /// Retail GBA FireRed / LeafGreen / Emerald ROMs are 16 MB; anything bigger on those codes is a rebuild.
  static let retailRomSize: UInt32 = 0x0100_0000

  /// Looks up a generated profile. Missing ids return nil — never traps; play continues
  /// without companion when a hack isn't pinned yet.
  private static func generated(_ id: String) -> NativeConfig? {
    guard var c = Gen3ConfigsGen.byId[id]?() else { return nil }
    enrich(&c)
    return c
  }

  /// Fields Android `NativeConfigsGen` keeps that iOS codegen often drops (masks, battle size, party stride).
  private static func enrich(_ c: inout NativeConfig) {
    switch c.id {
    case "heart_and_soul", "crystal_enhanced":
      c.speciesMask = 0x07FF
      c.moveMask = 0x07FF
      c.ppMask = 0x7F
      c.saveBlock1PosOff = 4
      c.battleMonLayout = .heartAndSoul
      c.tables = .hns
      // HnS: SB2 ptr @ 0x030041D4, SB1 @ 0x030041D8. CE Free Roam IWRAM is +8, same order
      // (SB2 then SB1) — not SB1 then +4. Wrong SB2 → bag qty stays XOR'd (×40k noise).
      if c.id == "crystal_enhanced" {
        c.saveBlock1Ptr = 0x030041E0
        c.saveBlock2Ptr = 0x030041DC
      }
    case "soulgold", "soulgold_v1_2", "soulgold_v1_2b", "soulgold_v1_2c":
      c.speciesMask = 0x07FF
      c.moveMask = 0x07FF
      c.ppMask = 0x7F
      c.monStride = 96
      c.partyMonKind = .soulGold(packedAttacks: false)
      c.battleMonLayout = .soulGold
      c.tables = .national
      c.mapSecWide = true
    case "soulgold_v1_2_1":
      c.speciesMask = 0x07FF
      c.moveMask = 0x07FF
      c.ppMask = 0x7F
      c.monStride = 96
      c.partyMonKind = .soulGold(packedAttacks: true)
      c.battleMonLayout = .soulGold
      c.tables = .national
      c.mapSecWide = true
    case "rowe":
      c.monStride = 0x4C
      c.partyMonKind = .rowe
      c.speciesMask = 0x0FFF
      c.battleMonLayout = .expansion
      c.tables = .national
    case "team_rocket_v3":
      c.mapSecWide = true
      c.tables = .national
    case "modern_emerald":
      // Android: vanilla 0x58 BattlePokemon (iOS codegen wrongly marked .expansion).
      c.battleMonLayout = .vanilla
      c.bagPocketOrder = emeraldPocketOrder
      c.encryptionKeyOff = 0xBC
      c.moneyOff = 0x490
      // SB2 pokedex + bag-shifted SB1 seen copies (Items pocket 90).
      // Flag bits are ME NATIONAL_DEX_* (1…432), not species ids; array is NUM_SPECIES-sized (58 bytes).
      c.dexEnabled = true
      c.dexFlagBlock = .saveBlock2
      c.dexSeenOff = 0x5C
      c.dexCaughtOff = 0x28
      c.dexBytes = 58
      c.dexSeenCopies = [0xA78, 0x3C14]
      c.dexNationalCount = 432
      c.tables = .modernEmerald
    case "rocket_edition":
      c.tables = .national
    case "lazarus":
      // National-dex species ids; expansion 0x60 battle mon; encryption key at SB2+0xB0.
      c.battleMonLayout = .expansion
      c.tables = .national
    case "wishes":
      c.speciesMask = 0x07FF
      c.moveMask = 0x07FF
      c.ppMask = 0x7F
      c.battleMonLayout = .wishes
      c.tables = .national
    case "tmt2":
      c.speciesMask = 0x07FF
      c.moveMask = 0x07FF
      c.ppMask = 0x7F
    default:
      break
    }
  }

  private static func labeled(_ id: String, displayName: String) -> NativeConfig? {
    guard var c = generated(id) else { return nil }
    c.displayName = displayName
    return c
  }

  enum MatchKind: String {
    case sha1
    case header
    case bestEffort = "best_effort"
    case none
  }

  struct Detection {
    var config: NativeConfig?
    var match: MatchKind
  }

  /// Hand pins for dumps that share a known engine but aren't in Poller.kt.
  private static let manualSha1Pins: [String: String] = [
    // Pokemon - Emerald Version (U)(TrashMan).gba — ~14.2 MB trimmed retail BPEE
    "4006dd1ab91df53b976a049fd974434294c552dd": "emerald_retail",
    // Pokemon Radical Red.gba (device dump) — Expand alias → Radical Red v4.1 WIDE
    "77e287d4fc53ea0fe9e51974ce19566eb786905c": "radical_red_v4_1",
    // Live device library (2026-11-13) — exact SHA-1 → companion profile
    "41cb23d8dccc8ebd7c649cd8fbb58eeace6e2fdc": "firered_rev0",
    "574fa542ffebb14be69902d1d36f1ec0a4afd71e": "leafgreen_rev0",
    "f28b6ffc97847e94a6c21a63cacf633ee5c8df1e": "port_axve0",
    "3ccbbd45f8553c36463f13b938e833f652b793e4": "port_axpe0",
    "033d05374ae34eb84fae62c693ca8f3da23dd1bd": "rocket_edition",
    "b9f4d332d30fc88c379f9e037f9eae3b2755ead4": "emerald_seaglass",
    "b4776b82a4c7915d0fadeaa27e013523f99dfd94": "unbound_with_dex",
    // Device library (2026-11-14) — also in RomIdentityGen; kept here for offline clarity
    "ab3bc012598d73dce965450df79893aeff97c834": "modern_emerald",
    "79ee6df0869c1773c8c6a5f764afc1f8d833d8bb": "heart_and_soul",
    "81bd0f4bfa1c04ab2c6faab1bddd10e8a390ea77": "rowe",
    "dacb6e40e7f572ddefd2dfa10e99c0da6835b062": "soulgold_v1_2_1", // Soulgold (v1.2.1).gba
    // Crystal Advance Redux — FireRed rev 0 RAM (BPRE 32 MB, no dedicated Poller profile yet)
    "5229160b68e3f2ee804a9e0f90e7a09b01254626": "firered_rev0",
    // Pokemon Lazarus.gba (device dump / v2.0) — also in RomIdentityGen
    "7dcdc7e280bc4631487e13dd37e6e0cea04adea6": "lazarus",
    // Crystal Enhanced — crystalenhanceddex.app patch CRC AACBBF26
    "755bdc2f01994881a72a448279f47666f1b0fb39": "crystal_enhanced",
    // Wishes of Tomorrow v1.3.0 (device / FlatFoot Labs)
    "0fb19d1d9ed68b550a4c1f562eaf0977d1007dbc": "wishes",
  ]

  /// Exact companion profile from a GPIO-masked whole-file SHA-1.
  /// Checks Documents/Companion/pins.json (runtime, agent-pushed) then generated Poller pins.
  private static func fromSha1(_ sha1: String) -> NativeConfig? {
    let key = sha1.lowercased()
    if let id = CompanionRomIdentity.loadPins()[key], let c = generated(id) {
      return c
    }
    if let id = manualSha1Pins[key], let c = generated(id) {
      return c
    }
    if let id = RomIdentityGen.sha1ToConfigId[key] {
      return generated(id)
    }
    return nil
  }

  /// Picks a config from cart header + optional whole-file SHA-1.
  /// Prefer `sha1` for every hack — hundreds of ROMs share BPRE/BPEE headers with different RAM maps.
  static func detect(
    code: String,
    title: String,
    revision: Int,
    romSize: UInt32,
    sha1: String? = nil
  ) -> NativeConfig? {
    detectDetailed(code: code, title: title, revision: revision, romSize: romSize, sha1: sha1).config
  }

  /// Ghost Grey builds (developer asked PokeDaisy to drop support — BlockedGames 1.5.1).
  static let blockedSha1s: Set<String> = [
    "20dfaea1d5317cf95fe0b493208edce7d50b865f", // Ghost Grey v1.0.1
    "74337272566a74625d6dedefe47d2d153eb48ec1", // Ghost Grey v1.0.2
    "0dafc0116b74406a2df491e26ccb40dd362fb0b7", // Ghost Grey v1.0.4
  ]

  static func detectDetailed(
    code: String,
    title: String,
    revision: Int,
    romSize: UInt32,
    sha1: String? = nil,
    fileName: String? = nil
  ) -> Detection {
    if let sha1, blockedSha1s.contains(sha1.lowercased()) {
      return Detection(config: nil, match: .none)
    }
    if let sha1, let pinned = fromSha1(sha1) {
      // Ghost Grey configs still exist in generated tables — never wire them.
      if pinned.id.hasPrefix("ghost_grey") {
        return Detection(config: nil, match: .none)
      }
      return Detection(config: pinned, match: .sha1)
    }

    let t = title.uppercased()
    let fn = (fileName ?? "").uppercased()
    // Title / filename fallbacks only when the build isn't SHA-1 pinned yet.
    if t.contains("SEAGLASS") || fn.contains("SEAGLASS"), let c = generated("emerald_seaglass") {
      return Detection(config: c, match: .header)
    }
    if t.contains("UNBOUND") || fn.contains("UNBOUND"), let c = generated("unbound_with_dex") {
      return Detection(config: c, match: .header)
    }
    if fn.contains("RADICAL"), let c = generated("radical_red_v4_1") {
      return Detection(config: c, match: .header)
    }
    if fn.contains("ROCKET"), let c = generated("rocket_edition") {
      return Detection(config: c, match: .header)
    }
    if (fn.contains("CRYSTAL") && fn.contains("ADVANCE")) || fn.contains("CRYSTALADVANCE"),
       let c = generated("firered_rev0") {
      return Detection(config: c, match: .header)
    }
    if fn.contains("MODERN") && fn.contains("EMERALD"), let c = generated("modern_emerald") {
      return Detection(config: c, match: .header)
    }
    // Crystal Enhanced (GBA Free Roam / pokehns) — before plain Crystal / Crystal Advance.
    if (fn.contains("CRYSTAL") && fn.contains("ENHANCED"))
        || t.contains("CRYSENHA") || t.contains("POKECRYSENHA"),
       let c = generated("crystal_enhanced") {
      return Detection(config: c, match: .header)
    }
    if (fn.contains("HEART") && fn.contains("SOUL") && !fn.contains("HEARTGOLD"))
        || t.contains("HNS"),
       let c = generated("heart_and_soul") {
      return Detection(config: c, match: .header)
    }
    if fn.contains("ROWE") || fn.contains("R.O.W.E") || fn.contains("R.O.W.E."),
       let c = generated("rowe") {
      return Detection(config: c, match: .header)
    }
    if fn.contains("SOULGOLD") || fn.contains("SOUL GOLD") || fn.contains("SOULDGOLD")
        || t.contains("SOULGOLD"),
       let c = generated("soulgold_v1_2_1") {
      return Detection(config: c, match: .header)
    }
    if fn.contains("LAZARUS") || t.contains("LAZARUS"), let c = generated("lazarus") {
      return Detection(config: c, match: .header)
    }
    if fn.contains("WISHES") || t.contains("WISHES"), let c = generated("wishes") {
      return Detection(config: c, match: .header)
    }

    switch code {
    case "BPEE", "BPES", "BPED", "BPEF", "BPEI", "BPEJ":
      if romSize > retailRomSize {
        // Large BPEE often = expansion rebuild. Try known titles, else Emerald-family
        // best-effort (party/bag/map may be wrong — queued for an exact pin).
        if fn.contains("MODERN") && fn.contains("EMERALD"), let c = generated("modern_emerald") {
          return Detection(config: c, match: .header)
        }
        if (fn.contains("CRYSTAL") && fn.contains("ENHANCED"))
            || t.contains("CRYSENHA") || t.contains("POKECRYSENHA"),
           let c = generated("crystal_enhanced") {
          return Detection(config: c, match: .header)
        }
        if (fn.contains("HEART") && fn.contains("SOUL")) || t.contains("HNS"),
           let c = generated("heart_and_soul") {
          return Detection(config: c, match: .header)
        }
        if fn.contains("ROWE") || fn.contains("R.O.W.E"), let c = generated("rowe") {
          return Detection(config: c, match: .header)
        }
        if fn.contains("SOULGOLD") || fn.contains("SOUL GOLD") || t.contains("SOULGOLD"),
           let c = generated("soulgold_v1_2_1") {
          return Detection(config: c, match: .header)
        }
        if fn.contains("LAZARUS") || t.contains("LAZARUS"), let c = generated("lazarus") {
          return Detection(config: c, match: .header)
        }
        if t.contains("ROGUE") || fn.contains("ROGUE"), let c = generated("emerald_rogue") {
          return Detection(config: c, match: .header)
        }
        if t.contains("KAIZO") || fn.contains("KAIZO"), let c = generated("emerald_kaizo") {
          return Detection(config: c, match: .header)
        }
        if t.contains("LEGACY") || fn.contains("LEGACY"), let c = generated("emerald_legacy") {
          return Detection(config: c, match: .header)
        }
        return Detection(
          config: bestEffort(
            base: emerald,
            id: "emerald_best_effort",
            displayName: title.isEmpty ? "Emerald-based hack" : title.trimmingCharacters(in: .whitespaces),
            game: .emerald
          ),
          match: .bestEffort
        )
      }
      let langId: String = {
        switch code {
        case "BPES": return "emerald_es"
        case "BPED": return "emerald_de"
        case "BPEF": return "emerald_fr"
        case "BPEI": return "emerald_it"
        case "BPEJ": return "emerald_ja"
        default: return "emerald_retail"
        }
      }()
      if code == "BPEE" {
        return Detection(config: generated("emerald_retail"), match: .header)
      }
      let c = labeled(langId, displayName: "Pokémon Emerald (\(code.suffix(1)))")
        ?? generated("emerald_retail")
      return Detection(config: c, match: .header)

    case "BPRE", "BPRJ", "BPRD", "BPRF", "BPRI", "BPRS":
      // Large BPRE → often CFRU (FireRed rev 0 RAM).
      if code == "BPRE" && romSize > retailRomSize {
        if t.contains("UNBOUND") || fn.contains("UNBOUND"), let c = generated("unbound_with_dex") {
          return Detection(config: c, match: .header)
        }
        if fn.contains("RADICAL"), let c = generated("radical_red_v4_1") {
          return Detection(config: c, match: .header)
        }
        if (fn.contains("CRYSTAL") && fn.contains("ADVANCE")) || fn.contains("CRYSTALADVANCE"),
           let c = generated("firered_rev0") {
          return Detection(config: c, match: .header)
        }
        return Detection(
          config: bestEffort(
            base: fireRedRev0,
            id: "cfru_best_effort",
            displayName: title.isEmpty ? "FireRed-based hack" : title.trimmingCharacters(in: .whitespaces),
            game: .fireRed
          ),
          match: .bestEffort
        )
      }
      if code != "BPRE" {
        return Detection(
          config: labeled("firered_rev0", displayName: "Pokémon FireRed (\(code))"),
          match: .header
        )
      }
      return Detection(config: revision == 1 ? fireRedRev1 : fireRedRev0, match: .header)

    case "BPGE", "BPGJ", "BPGD", "BPGF", "BPGI", "BPGS":
      if romSize > retailRomSize {
        return Detection(
          config: bestEffort(
            base: leafGreen,
            id: "leafgreen_best_effort",
            displayName: title.isEmpty ? "LeafGreen-based hack" : title.trimmingCharacters(in: .whitespaces),
            game: .fireRed
          ),
          match: .bestEffort
        )
      }
      if code != "BPGE" {
        return Detection(
          config: labeled("leafgreen_rev0", displayName: "Pokémon LeafGreen (\(code))"),
          match: .header
        )
      }
      let c = revision == 1 ? (generated("leafgreen_rev1") ?? leafGreen) : leafGreen
      return Detection(config: c, match: .header)

    case "AXVE", "AXPE", "AXVJ", "AXPJ", "AXVD", "AXPD", "AXVF", "AXPF", "AXVI", "AXPI", "AXVS", "AXPS":
      let isRuby = code.hasPrefix("AXV")
      let baseId = isRuby ? "ruby" : "sapphire"
      let label = (isRuby ? "Pokémon Ruby" : "Pokémon Sapphire") + " (\(code))"
      if revision == 0 {
        let rev0 = isRuby ? "port_axve0" : "port_axpe0"
        if let c = labeled(rev0, displayName: label) {
          return Detection(config: c, match: .header)
        }
      }
      if romSize > retailRomSize, let base = generated(baseId) {
        return Detection(
          config: bestEffort(
            base: base,
            id: "\(baseId)_best_effort",
            displayName: title.isEmpty ? label : title.trimmingCharacters(in: .whitespaces),
            game: .emerald
          ),
          match: .bestEffort
        )
      }
      return Detection(config: labeled(baseId, displayName: label), match: .header)

    case "PUVV":
      // Ultra Violet uses its own game code — require SHA-1 (handled above) or fail closed.
      return Detection(config: nil, match: .none)

    default:
      // Unknown maker code: still try title clues for common hacks, else queue as none.
      if t.contains("UNBOUND"), let c = generated("unbound_with_dex") {
        return Detection(config: c, match: .header)
      }
      if t.contains("SEAGLASS"), let c = generated("emerald_seaglass") {
        return Detection(config: c, match: .header)
      }
      return Detection(config: nil, match: .none)
    }
  }

  /// Clone a retail/family profile for an unpinned hack — dex off, distinct id for the queue.
  private static func bestEffort(
    base: NativeConfig,
    id: String,
    displayName: String,
    game: Gen3Game
  ) -> NativeConfig {
    var c = base
    c.id = id
    c.displayName = displayName
    c.game = game
    c.dexEnabled = false
    return c
  }
}
