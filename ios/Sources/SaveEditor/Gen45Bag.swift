import Foundation

/// One Gen 4 / Gen 5 bag pouch: `slots` of {u16 item, u16 quantity} from `off` (relative to the bag's base).
/// Filled stacks come first; the rest are zero.
struct Gen45Pouch {
  let off: Int
  let slots: Int
  /// The app-wide pocket id (`BagPocket.id`) this pouch is shown under.
  let pocket: BagPocket
  /// The most one stack holds (1 for key items).
  let maxQuantity: Int
  /// A TM/HM pouch: HM stacks (ids 420...427 in Gen 4 and 5) hold 1.
  let isTMHM: Bool

  init(off: Int, slots: Int, pocket: BagPocket, maxQuantity: Int = 999, isTMHM: Bool = false) {
    self.off = off
    self.slots = slots
    self.pocket = pocket
    self.maxQuantity = maxQuantity
    self.isTMHM = isTMHM
  }

  func stackMax(item: Int) -> Int {
    if isTMHM && (420...427).contains(item) { return 1 }
    return maxQuantity
  }
}

enum Gen45Bag {
  /// Every filled stack, pouch by pouch, in the save's order.
  static func read(_ bytes: [UInt8], base: Int, pouches: [Gen45Pouch]) -> [SaveItemStack] {
    var out: [SaveItemStack] = []
    for p in pouches {
      for i in 0..<p.slots {
        let o = base + p.off + i * 4
        guard o + 3 < bytes.count else { break }
        let item = saveU16(bytes, o)
        let qty = saveU16(bytes, o + 2)
        if item != 0 && qty != 0 { out.append(SaveItemStack(item: item, quantity: qty, pocket: p.pocket.id)) }
      }
    }
    return out
  }

  /// Sets the quantity of the stack holding `item` (0 removes it, closing the gap). Throws, leaving `bytes`
  /// untouched, if the bag has no such stack, the item id is out of range or the quantity is more than a stack holds.
  static func setQuantity(
    _ bytes: inout [UInt8], base: Int, pouches: [Gen45Pouch], item: Int, quantity: Int, maxItem: Int
  ) throws {
    guard (1...maxItem).contains(item) else { throw Gen45MonError("item \(item)") }
    for p in pouches {
      var stacks: [(Int, Int)] = []
      var at = -1
      for i in 0..<p.slots {
        let o = base + p.off + i * 4
        let id = saveU16(bytes, o)
        let q = saveU16(bytes, o + 2)
        if id == 0 || q == 0 { continue }
        if id == item { at = stacks.count }
        stacks.append((id, q))
      }
      guard at >= 0 else { continue }
      guard (0...p.stackMax(item: item)).contains(quantity) else {
        throw Gen45MonError("quantity \(quantity) for item \(item)")
      }
      if quantity == 0 { stacks.remove(at: at) } else { stacks[at].1 = quantity }
      for i in 0..<p.slots {
        let o = base + p.off + i * 4
        if i < stacks.count {
          savePutU16(&bytes, o, stacks[i].0)
          savePutU16(&bytes, o + 2, stacks[i].1)
        } else {
          savePutU32(&bytes, o, 0)
        }
      }
      return
    }
    throw Gen45MonError("the bag has no item \(item)")
  }
}

// MARK: - Shared party editing

extension Gen45Mon {
  /// Applies the non-nil edits to a copy and, if all validate, to `self`. Changing species, level, EVs or IVs
  /// recomputes stats (HP clamped to the new max, or full with `healFully`); a level or growth-group change resets EXP
  /// to the level's threshold on the (new) species' growth rate.
  mutating func apply(
    species: Int? = nil, level: Int? = nil, moves: [Int]? = nil, heldItem: Int? = nil, maxItem: Int,
    evs: [Int]? = nil, ivs: [Int]? = nil, nickname: String? = nil, hp: Int? = nil, healFully: Bool = false,
    nature: Int? = nil, gender: Gen3MonGender? = nil
  ) throws {
    var m = self
    var statsChanged = false
    if let species {
      try m.setSpecies(species)
      if species != self.species { statsChanged = true }
    }
    if let evs { try m.setEVs(evs); statsChanged = true }
    if let ivs { try m.setIVs(ivs); statsChanged = true }
    if let level {
      try m.setLevel(level)
      statsChanged = true
    } else if species != nil && species != self.species {
      try m.setLevel(max(1, m.level))   // EXP on the new species' growth rate
    }
    if let moves { try m.setMoves(moves) }
    if let heldItem { try m.setHeldItem(heldItem, maxItem: maxItem) }
    if let nickname { m.setNickname(nickname) }
    if let nature { try m.setNature(nature); statsChanged = true }
    if let gender { try m.setGender(gender) }
    if statsChanged { m.recomputeStats(healFully: healFully) }
    if let hp { try m.setHP(hp) }
    self = m
  }
}
