import Foundation

/// Competitive-style EV spreads tailored to a Pokémon's base stats and nature.
struct SmartEVProfile: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  /// HP, Atk, Def, Spe, SpA, SpD — sums to ≤ 510, each ≤ 252.
  let evs: [Int]
  /// Whether this profile leans into the nature's +stat.
  let natureAligned: Bool
}

enum SmartEVProfiles {
  private static let maxStat = 252
  private static let maxTotal = 510
  private static let leftover = 4

  /// Profiles for `species` under `nature` (0…24). Always includes Clear + a nature-first pick.
  static func profiles(species: Int, nature: Int, tables: Gen3Tables) -> [SmartEVProfile] {
    let base = Gen3BaseStats.stats(species: species, tables: tables)
    guard base.count >= 6, species > 0 else {
      return [clear]
    }

    let up = Gen3Natures.raises(nature)   // 1…5 or nil
    let down = Gen3Natures.lowers(nature)
    let physical = base[Gen3Stat.attack] >= base[Gen3Stat.spAttack]
    let offense = physical ? Gen3Stat.attack : Gen3Stat.spAttack
    let bulk = base[Gen3Stat.defense] >= base[Gen3Stat.spDefense]
      ? Gen3Stat.defense : Gen3Stat.spDefense
    let otherBulk = bulk == Gen3Stat.defense ? Gen3Stat.spDefense : Gen3Stat.defense
    let spe = Gen3Stat.speed
    let hp = Gen3Stat.hp

    var out: [SmartEVProfile] = []

    // 1) Nature Sweep — invest the +stat first when it's useful.
    if let up, up != down {
      let second: Int = {
        if up == spe { return offense }
        if up == offense { return spe }
        if up == hp || up == Gen3Stat.defense || up == Gen3Stat.spDefense {
          return offense
        }
        return spe
      }()
      let third = leftoverStat(excluding: [up, second], prefer: [hp, bulk, otherBulk])
      out.append(make(
        id: "nature-sweep",
        title: "Nature Sweep",
        primary: up, secondary: second, tertiary: third,
        natureAligned: true
      ))
    }

    // 2) Fast offense — classic 252/252/4
    out.append(make(
      id: "fast-offense",
      title: physical ? "Fast Physical" : "Fast Special",
      primary: offense, secondary: spe, tertiary: hp,
      natureAligned: up == offense || up == spe
    ))

    // 3) Bulky offense
    out.append(make(
      id: "bulky-offense",
      title: physical ? "Bulky Physical" : "Bulky Special",
      primary: hp, secondary: offense, tertiary: up == spe ? spe : bulk,
      natureAligned: up == hp || up == offense
    ))

    // 4) Speed tank / pivot
    out.append(make(
      id: "fast-bulk",
      title: "Fast Bulk",
      primary: hp, secondary: spe, tertiary: bulk,
      natureAligned: up == spe || up == hp
    ))

    // 5) Defensive wall matching nature bias
    let wallStat: Int = {
      if let up, up == Gen3Stat.defense || up == Gen3Stat.spDefense { return up }
      return bulk
    }()
    out.append(make(
      id: "wall",
      title: wallStat == Gen3Stat.defense ? "Physical Wall" : "Special Wall",
      primary: hp, secondary: wallStat, tertiary: otherBulk,
      natureAligned: up == wallStat || up == hp
    ))

    // 6) Mixed attacker when bases are close
    let atk = base[Gen3Stat.attack], spa = base[Gen3Stat.spAttack]
    if abs(atk - spa) <= 15 {
      out.append(make(
        id: "mixed",
        title: "Mixed Attacker",
        primary: Gen3Stat.attack, secondary: Gen3Stat.spAttack, tertiary: spe,
        natureAligned: up == Gen3Stat.attack || up == Gen3Stat.spAttack
      ))
    }

    out.append(clear)

    // De-dupe identical EV arrays; prefer nature-aligned titles first.
    var seen = Set<String>()
    let unique = out.filter { p in
      let key = p.evs.map(String.init).joined(separator: ",")
      if seen.contains(key) { return false }
      seen.insert(key)
      return true
    }
    return unique.sorted { a, b in
      if a.natureAligned != b.natureAligned { return a.natureAligned && !b.natureAligned }
      if a.id == "clear" { return false }
      if b.id == "clear" { return true }
      return a.title < b.title
    }
  }

  private static let clear = SmartEVProfile(
    id: "clear",
    title: "Clear EVs",
    subtitle: "0 / 0 / 0 / 0 / 0 / 0",
    evs: [0, 0, 0, 0, 0, 0],
    natureAligned: false
  )

  private static func make(
    id: String, title: String,
    primary: Int, secondary: Int, tertiary: Int,
    natureAligned: Bool
  ) -> SmartEVProfile {
    var evs = [Int](repeating: 0, count: 6)
    evs[primary] = maxStat
    evs[secondary] = maxStat
    evs[tertiary] = leftover
    // Clamp if primary == secondary somehow.
    if primary == secondary {
      evs[primary] = maxStat
      evs[tertiary] = leftover
      let rest = leftoverStat(excluding: [primary, tertiary], prefer: [Gen3Stat.hp, Gen3Stat.speed])
      evs[rest] = maxTotal - maxStat - leftover
    }
    let total = evs.reduce(0, +)
    if total > maxTotal {
      evs[tertiary] = max(0, leftover - (total - maxTotal))
    }
    let subtitle = zip(SaveEditorCatalog.statLabels, evs)
      .filter { $0.1 > 0 }
      .map { "\($0.1) \($0.0)" }
      .joined(separator: " · ")
    return SmartEVProfile(
      id: id, title: title,
      subtitle: subtitle.isEmpty ? "Empty" : subtitle,
      evs: evs, natureAligned: natureAligned
    )
  }

  private static func leftoverStat(excluding: [Int], prefer: [Int]) -> Int {
    for p in prefer where !excluding.contains(p) { return p }
    return (0..<6).first { !excluding.contains($0) } ?? Gen3Stat.hp
  }
}
