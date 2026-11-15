import Foundation

enum SaveGeneration { case gen1, gen2, gen3, gen4, gen5 }

struct SaveMon: Identifiable, Equatable {
  var id: String
  var species: Int
  var level: Int
  var heldItem: Int
  var friendship: Int
  var moves: [Int]
  var pp: [Int]
  var evs: [Int]
  var ivs: [Int]
  var nickname: String
  var shiny: Bool
  /// Gen 3 personality-derived gender; nil when unknown / not applicable.
  var gender: Gen3MonGender?
  var isEgg: Bool
  var exp: Int
  var nature: Int?
}

struct SaveItemStack: Identifiable, Equatable {
  var id: String { "\(pocket)-\(item)" }
  var item: Int
  var quantity: Int
  var pocket: Int
}

struct SaveTrainer: Equatable {
  var name: String
  var money: Int
  var coins: Int
  var trainerId: Int
  var secretId: Int
  var isFemale: Bool
  var playTime: String
}

struct SaveBox: Identifiable, Equatable {
  var id: Int { index }
  var index: Int
  var name: String
  /// Occupied slots only (empty PC cells omitted).
  var mons: [SaveMon]
}

struct SaveDexSummary: Equatable {
  var owned: Int
  var seen: Int
  var max: Int
  var nationalEnabled: Bool?
}
