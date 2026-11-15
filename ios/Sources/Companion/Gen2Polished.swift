import Foundation

/// Polished Crystal 3.2.x companion constants (from PokeDaisy Gen2SpeciesPolishedCrystal / Gen2Reader).
enum Gen2Polished {
  static let numSpecies = 0x123 // 291
  static let battleMonSize = 35
  static let eggSpecies = 0xFF
  /// VariantSpeciesAndFormTable packed as (species9 << 8) | form5 — used by polishedSpeciesId.
  static let variantForms: [Int] = [
    0, 8215, 0, 9602, 0, 12002, 0, 1302, 0, 1402, 0, 1,
    2, 0, 1, 2, 0, 1, 2, 0, 2502, 0, 2602, 0,
    3202, 0, 3302, 0, 3402, 0, 3502, 0, 4, 2, 0, 4,
    2, 0, 4, 2, 0, 5802, 0, 5902, 0, 6702, 0, 6902,
    0, 3403, 0, 4, 3, 0, 4, 3, 0, 4, 3, 0,
    5003, 0, 5303, 0, 6, 3, 0, 7, 3, 0, 9003, 0,
    9103, 0, 9203, 0, 703, 0, 3, 0, 3, 4, 0, 3,
    4, 0, 6404, 0, 6504, 0, 9, 4, 0, 304, 0, 704,
    0, 205, 0, 8005, 0, 8002, 0, 8003, 0, 11, 2,
  ]

  static func speciesId(species: Int, form: Int) -> Int {
    let s9 = species | ((form & 0x20) != 0 ? 0x100 : 0)
    let key = (s9 << 8) | (form & 0x1F)
    if let k = variantForms.firstIndex(of: key) {
      return numSpecies + 1 + k
    }
    return s9
  }
}
