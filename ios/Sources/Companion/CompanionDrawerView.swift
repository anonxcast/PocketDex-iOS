import SwiftUI

enum CompanionTab: String, CaseIterable, Identifiable {
  case party, bag, map, battle, dex, settings

  var id: String { rawValue }

  var title: String {
    switch self {
    case .party: return "Party"
    case .bag: return "Bag"
    case .map: return "Map"
    case .battle: return "Battle"
    case .dex: return "Dex"
    case .settings: return "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .party: return "person.3.fill"
    case .bag: return "bag.fill"
    case .map: return "map.fill"
    case .battle: return "bolt.fill"
    case .dex: return "books.vertical.fill"
    case .settings: return "gearshape.fill"
    }
  }
}

/// PocketDex companion drawer content: Party | Bag | Map | Battle | Dex | Settings.
struct CompanionDrawerView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @ObservedObject private var live = CompanionLiveStore.shared
  let onClose: () -> Void

  @State private var tab: CompanionTab = .party
  /// Held copy so live publishes don’t remount ScrollView / jump landscape scroll.
  @State private var heldSnap: CompanionSnapshot?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Rectangle().fill(CETheme.border).frame(height: 1)
      tabBar
      Rectangle().fill(CETheme.border).frame(height: 1)
      ScrollView {
        content
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .transaction { $0.animation = nil }
    .onAppear { heldSnap = live.snapshot }
    .onChange(of: live.snapshot) { _, new in
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) { heldSnap = new }
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("POCKETDEX COMPANION")
          .font(CETheme.sans(11, weight: .bold))
          .tracking(1.0)
          .foregroundStyle(CETheme.crystal)
        Text(heldSnap?.gameName ?? live.gameName ?? "Party · Bag · Map · Battle · Dex · Settings")
          .font(CETheme.sans(13, weight: .medium))
          .foregroundStyle(CETheme.muted)
          .lineLimit(2)
          .minimumScaleFactor(0.85)
          .fixedSize(horizontal: false, vertical: true)
        if live.match == .bestEffort {
          Text("Unverified")
            .font(CETheme.sans(10, weight: .bold))
            .foregroundStyle(CETheme.accent)
        }
      }
      Spacer()
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(CETheme.text)
          .frame(width: 34, height: 34)
          .background(CETheme.hover, in: Circle())
      }
      .accessibilityLabel("Close companion")
    }
    .padding(16)
  }

  private var tabBar: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(CompanionTab.allCases) { t in
          Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = t }
          } label: {
            VStack(spacing: 3) {
              Image(systemName: t.symbol)
                .font(.system(size: 13, weight: .semibold))
              Text(t.title)
                .font(CETheme.sans(10, weight: .semibold))
            }
            .foregroundStyle(tab == t ? CETheme.crystal : CETheme.muted)
            .frame(minWidth: 52)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .background(tab == t ? CETheme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(t.title)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
  }

  @ViewBuilder
  private var content: some View {
    if tab == .settings {
      InGameSettingsTab()
    } else if let snap = heldSnap {
      switch tab {
      case .party: PartyTab(snap: snap)
      case .bag: BagTab(snap: snap)
      case .map: MapTab(snap: snap)
      case .battle: BattleTab(snap: snap)
      case .dex: DexTab(snap: snap)
      case .settings: InGameSettingsTab()
      }
    } else {
      VStack(alignment: .leading, spacing: 10) {
        Text(live.hint)
          .font(CETheme.sans(14))
          .foregroundStyle(CETheme.text)
        if live.match == .bestEffort {
          CompanionNote("Best-effort profile — party/bag may be wrong until this ROM is pinned. It’s in Settings › Support.")
        } else if live.match == .none {
          CompanionNote("No companion profile yet. Play still works. Open Settings › Support to share the queue for pinning.")
        } else {
          CompanionNote("Companion reads Gen 1–3 on GB/GBC/GBA (Red–Emerald + common hacks, best-effort). DS plays via melonDS. Data appears once a save is loaded.")
        }
        let pendingCount = CompanionRomIdentity.loadPending().count
        if pendingCount > 0 {
          Text("Support queue: \(pendingCount) ROM\(pendingCount == 1 ? "" : "s")")
            .font(CETheme.sans(12, weight: .semibold))
            .foregroundStyle(CETheme.muted)
        }
        Button {
          tab = .settings
        } label: {
          Text("Open in-game Settings")
            .font(CETheme.sans(14, weight: .semibold))
            .foregroundStyle(CETheme.crystal)
        }
        .buttonStyle(.plain)
      }
    }
  }
}

// MARK: - Shared bits

private struct CompanionNote: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(CETheme.sans(13))
      .foregroundStyle(CETheme.muted)
      .fixedSize(horizontal: false, vertical: true)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(CETheme.border, lineWidth: 1))
  }
}

private struct CompanionCard<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      content
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(CETheme.border, lineWidth: 1))
  }
}

private struct SectionTitle: View {
  let text: String
  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text.uppercased())
      .font(CETheme.sans(11, weight: .bold))
      .tracking(0.8)
      .foregroundStyle(CETheme.muted)
  }
}

private struct KeyValueRow: View {
  let key: String
  let value: String

  init(_ key: String, _ value: String) {
    self.key = key
    self.value = value
  }

  var body: some View {
    HStack {
      Text(key)
        .font(CETheme.sans(13))
        .foregroundStyle(CETheme.muted)
      Spacer()
      Text(value)
        .font(CETheme.mono(13))
        .foregroundStyle(CETheme.text)
    }
  }
}

private struct HPBar: View {
  let hp: Int
  let maxHp: Int

  private var fraction: CGFloat {
    guard maxHp > 0 else { return 0 }
    return min(1, max(0, CGFloat(hp) / CGFloat(maxHp)))
  }

  private var color: Color {
    if fraction > 0.5 { return Color(red: 0.30, green: 0.80, blue: 0.45) }
    if fraction > 0.2 { return Color(red: 0.95, green: 0.78, blue: 0.25) }
    return Color(red: 0.95, green: 0.35, blue: 0.35)
  }

  var body: some View {
    // ScaleEffect avoids GeometryReader inside ScrollView (landscape jump source).
    Capsule()
      .fill(CETheme.hover)
      .frame(height: 6)
      .overlay(alignment: .leading) {
        Capsule()
          .fill(color)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
          .scaleEffect(x: fraction, y: 1, anchor: .leading)
      }
      .clipShape(Capsule())
      .accessibilityLabel("HP \(hp) of \(maxHp)")
  }
}

private func monDisplayName(_ mon: Mon, tables: Gen3Tables) -> String {
  if mon.isEgg { return "Egg" }
  return mon.nickname ?? Gen3Names.species(mon.species, tables: tables)
}

// MARK: - Party

private struct PartyTab: View {
  let snap: CompanionSnapshot
  @State private var expanded: Int?

  var body: some View {
    if snap.party.isEmpty {
      CompanionNote("No Pokémon in the party yet. Start a new game or load a save and this fills in live.")
    } else {
      VStack(spacing: 8) {
        ForEach(snap.party) { mon in
          PartyRow(
            mon: mon,
            tables: snap.tables,
            expanded: expanded == mon.slot
          ) {
            withAnimation(.easeOut(duration: 0.18)) {
              expanded = expanded == mon.slot ? nil : mon.slot
            }
          }
        }
      }
    }
  }
}

private struct PartyRow: View {
  let mon: Mon
  let tables: Gen3Tables
  let expanded: Bool
  let onTap: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: onTap) {
        HStack(spacing: 10) {
          ZStack {
            Circle().fill(CETheme.hover)
            Text(mon.isEgg ? "🥚" : "#\(mon.species)")
              .font(CETheme.mono(10))
              .foregroundStyle(CETheme.muted)
          }
          .frame(width: 38, height: 38)

          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
              Text(monDisplayName(mon, tables: tables))
                .font(CETheme.sans(14, weight: .semibold))
                .foregroundStyle(CETheme.text)
                .lineLimit(1)
              if mon.shiny {
                Image(systemName: "star.fill")
                  .font(.system(size: 11))
                  .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.3))
                  .accessibilityLabel("Shiny")
              }
              if let st = mon.statusLabel {
                Text(st)
                  .font(CETheme.sans(9, weight: .bold))
                  .foregroundStyle(.black)
                  .padding(.horizontal, 5)
                  .padding(.vertical, 2)
                  .background(CETheme.accent2, in: Capsule())
              }
              Spacer(minLength: 4)
              if !mon.isEgg {
                Text("Lv \(mon.level)")
                  .font(CETheme.mono(12))
                  .foregroundStyle(CETheme.muted)
              }
            }
            if !mon.isEgg {
              HPBar(hp: mon.hp, maxHp: mon.maxHp)
              Text("\(mon.hp) / \(mon.maxHp)")
                .font(CETheme.mono(11))
                .foregroundStyle(CETheme.muted)
            }
          }
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(CETheme.muted)
        }
      }
      .buttonStyle(.plain)

      if expanded && !mon.isEgg {
        MonDetail(mon: mon, tables: tables)
          .transition(.opacity)
      }
    }
    .padding(12)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(expanded ? CETheme.crystal.opacity(0.5) : CETheme.border, lineWidth: 1))
  }
}

private struct MonDetail: View {
  let mon: Mon
  let tables: Gen3Tables

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Rectangle().fill(CETheme.border).frame(height: 1)

      if mon.nickname != nil {
        KeyValueRow("Species", Gen3Names.species(mon.species, tables: tables))
      }
      if mon.heldItem != 0 {
        KeyValueRow("Held item", Gen3Names.item(mon.heldItem, tables: tables))
      }
      if let exp = mon.exp {
        KeyValueRow("Exp", "\(exp)")
      }

      if let stats = mon.stats {
        natureRow(stats.nature)
        statGrid(stats)
      }

      SectionTitle("Moves")
      VStack(spacing: 6) {
        ForEach(0..<Gen3Const.numMoves, id: \.self) { i in
          let move = i < mon.moves.count ? mon.moves[i] : 0
          if move != 0 {
            HStack {
              Text(Gen3Names.move(move, tables: tables))
                .font(CETheme.sans(13, weight: .medium))
                .foregroundStyle(CETheme.text)
              Spacer()
              Text("PP \(i < mon.pp.count ? mon.pp[i] : 0)")
                .font(CETheme.mono(12))
                .foregroundStyle(CETheme.muted)
            }
          }
        }
      }
    }
  }

  private func natureRow(_ nature: Int) -> some View {
    let up = Gen3Natures.raises(nature)
    let down = Gen3Natures.lowers(nature)
    return HStack {
      Text("Nature")
        .font(CETheme.sans(13))
        .foregroundStyle(CETheme.muted)
      Spacer()
      Text(Gen3Natures.name(nature))
        .font(CETheme.sans(13, weight: .semibold))
        .foregroundStyle(CETheme.text)
      if let up, let down {
        Text("+\(Gen3Stat.names[up]) −\(Gen3Stat.names[down])")
          .font(CETheme.mono(11))
          .foregroundStyle(CETheme.muted)
      } else {
        Text("neutral")
          .font(CETheme.mono(11))
          .foregroundStyle(CETheme.muted)
      }
    }
  }

  private func statGrid(_ stats: MonStats) -> some View {
    let up = Gen3Natures.raises(stats.nature)
    let down = Gen3Natures.lowers(stats.nature)
    return VStack(spacing: 4) {
      HStack {
        Text("").frame(width: 34, alignment: .leading)
        gridHeader("Stat")
        gridHeader("IV")
        gridHeader("EV")
      }
      ForEach(0..<6, id: \.self) { i in
        HStack {
          Text(Gen3Stat.names[i])
            .font(CETheme.sans(12, weight: .semibold))
            .foregroundStyle(i == up ? Color(red: 0.85, green: 0.85, blue: 0.85) : (i == down ? CETheme.accent : CETheme.muted))
            .frame(width: 34, alignment: .leading)
          gridCell(i < stats.stats.count ? stats.stats[i] : 0)
          gridCell(i < stats.ivs.count ? stats.ivs[i] : 0)
          gridCell(i < stats.evs.count ? stats.evs[i] : 0)
        }
      }
    }
  }

  private func gridHeader(_ t: String) -> some View {
    Text(t)
      .font(CETheme.sans(10, weight: .bold))
      .foregroundStyle(CETheme.muted)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private func gridCell(_ v: Int) -> some View {
    Text("\(v)")
      .font(CETheme.mono(12))
      .foregroundStyle(CETheme.text)
      .frame(maxWidth: .infinity, alignment: .trailing)
  }
}

// MARK: - Bag

private struct BagTab: View {
  let snap: CompanionSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CompanionCard {
        HStack {
          Image(systemName: "yensign.circle.fill")
            .foregroundStyle(CETheme.crystal)
          Text("Money")
            .font(CETheme.sans(13))
            .foregroundStyle(CETheme.muted)
          Spacer()
          Text(snap.money.map { "₽\($0.formatted())" } ?? "—")
            .font(CETheme.mono(15))
            .foregroundStyle(CETheme.text)
        }
      }

      if snap.bag.isEmpty {
        CompanionNote("The bag is empty (or hasn't been read yet).")
      } else {
        ForEach(snap.bagByPocket, id: \.pocket) { section in
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
              Image(systemName: Gen3Pocket.symbol(section.pocket))
                .font(.system(size: 11))
                .foregroundStyle(CETheme.crystal)
              SectionTitle(Gen3Pocket.name(section.pocket))
              Text("\(section.items.count)")
                .font(CETheme.mono(11))
                .foregroundStyle(CETheme.muted)
            }
            CompanionCard {
              ForEach(section.items) { item in
                HStack {
                  Text(Gen3Names.item(item.itemId, tables: snap.tables))
                    .font(CETheme.sans(13, weight: .medium))
                    .foregroundStyle(CETheme.text)
                    .lineLimit(2)
                  Spacer(minLength: 8)
                  Text("×\(item.quantity)")
                    .font(CETheme.mono(13))
                    .foregroundStyle(CETheme.text)
                }
              }
            }
          }
        }
      }
    }
  }
}

// MARK: - Map

private struct MapTab: View {
  let snap: CompanionSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CompanionCard {
        SectionTitle("Location")
        Text(snap.mapSecName ?? "Unknown area")
          .font(CETheme.sans(18, weight: .bold))
          .foregroundStyle(CETheme.text)
        Text("Map \(snap.mapGroup).\(snap.mapNum)")
          .font(CETheme.mono(12))
          .foregroundStyle(CETheme.muted)
      }
      CompanionCard {
        KeyValueRow("Map group", "\(snap.mapGroup)")
        KeyValueRow("Map number", "\(snap.mapNum)")
        KeyValueRow("Map section", "\(snap.mapSec)")
        KeyValueRow("Position", "x \(snap.x) · y \(snap.y)")
        KeyValueRow("In battle", snap.inBattle ? "Yes" : "No")
      }
    }
  }
}

// MARK: - Battle

private struct BattleTab: View {
  let snap: CompanionSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CompanionCard {
        HStack {
          Circle()
            .fill(snap.inBattle ? Color(red: 0.95, green: 0.35, blue: 0.35) : CETheme.border)
            .frame(width: 10, height: 10)
          Text(snap.inBattle ? "In battle" : "Not in battle")
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(CETheme.text)
        }
        if snap.inBattle {
          let kind = snap.isTrainer == true ? "Trainer" : (snap.isTrainer == false ? "Wild" : "Unknown")
          KeyValueRow("Type", "\(kind)\(snap.isDouble ? " · Double" : " · Single")")
        }
      }

      if snap.inBattle {
        if let tip = Gen3BattleData.liveSuggestions(from: snap) {
          SectionTitle("Suggested moves")
          CompanionCard {
            Text("vs \(tip.foeName)")
              .font(CETheme.sans(12, weight: .semibold))
              .foregroundStyle(CETheme.crystal)
            ForEach(tip.moves) { mv in
              HStack(spacing: 8) {
                Text(mv.name)
                  .font(CETheme.sans(13, weight: .medium))
                  .foregroundStyle(CETheme.text)
                if !mv.typeName.isEmpty {
                  Text(mv.typeName.uppercased())
                    .font(CETheme.sans(9, weight: .bold))
                    .foregroundStyle(CETheme.muted)
                }
                Spacer()
                if mv.power > 0 {
                  Text(mv.multiplierLabel)
                    .font(CETheme.mono(12))
                    .foregroundStyle(mv.multiplierPct >= 200 ? Color(red: 0.35, green: 0.85, blue: 0.45)
                                      : (mv.multiplierPct == 0 ? Color(red: 0.95, green: 0.35, blue: 0.35)
                                         : (mv.multiplierPct < 100 ? Color(red: 0.95, green: 0.75, blue: 0.3) : CETheme.text)))
                  Text(mv.verdict)
                    .font(CETheme.sans(9, weight: .bold))
                    .foregroundStyle(CETheme.muted)
                } else {
                  Text("STATUS")
                    .font(CETheme.sans(9, weight: .bold))
                    .foregroundStyle(CETheme.muted)
                }
              }
            }
          }
        }

        let foes = [1, 3].compactMap { pos in snap.battleMons[pos].map { (pos, $0) } }
        if foes.isEmpty {
          CompanionNote("Foe data isn't available for this battle yet.")
        } else {
          SectionTitle("Foe")
          ForEach(foes, id: \.0) { foe in
            BattleMonCard(mon: foe.1, tables: snap.tables)
          }
        }

        let allies = [0, 2].compactMap { pos in snap.battleMons[pos].map { (pos, $0) } }
        if !allies.isEmpty {
          SectionTitle("Your side")
          ForEach(allies, id: \.0) { ally in
            BattleMonCard(mon: ally.1, tables: snap.tables)
          }
        }

        if snap.isTrainer == true && !snap.foeParty.isEmpty {
          SectionTitle("Foe team")
          CompanionCard {
            ForEach(snap.foeParty) { mon in
              HStack {
                Text(Gen3Names.species(mon.species, tables: snap.tables))
                  .font(CETheme.sans(13, weight: .medium))
                  .foregroundStyle(CETheme.text)
                if mon.shiny {
                  Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.3))
                }
                Spacer()
                Text("Lv \(mon.level)")
                  .font(CETheme.mono(12))
                  .foregroundStyle(CETheme.muted)
                Text("\(mon.hp)/\(mon.maxHp)")
                  .font(CETheme.mono(12))
                  .foregroundStyle(CETheme.muted)
              }
            }
          }
        }
      } else {
        CompanionNote("Open this tab during a battle to see the foe's species, level, HP and moves.")
      }
    }
  }
}

private struct BattleMonCard: View {
  let mon: BattleMon
  let tables: Gen3Tables

  var body: some View {
    CompanionCard {
      HStack {
        Text(Gen3Names.species(mon.species, tables: tables))
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(CETheme.text)
        if mon.shiny {
          Image(systemName: "star.fill")
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.3))
        }
        Spacer()
        Text("Lv \(mon.level)")
          .font(CETheme.mono(12))
          .foregroundStyle(CETheme.muted)
      }
      HPBar(hp: mon.hp, maxHp: mon.maxHp)
      Text("\(mon.hp) / \(mon.maxHp)")
        .font(CETheme.mono(11))
        .foregroundStyle(CETheme.muted)
      if mon.item != 0 {
        KeyValueRow("Item", Gen3Names.item(mon.item, tables: tables))
      }
      ForEach(0..<Gen3Const.numMoves, id: \.self) { i in
        let move = i < mon.moves.count ? mon.moves[i] : 0
        if move != 0 {
          HStack {
            Text(Gen3Names.move(move, tables: tables))
              .font(CETheme.sans(12))
              .foregroundStyle(CETheme.text)
            Spacer()
            Text("PP \(i < mon.pp.count ? mon.pp[i] : 0)")
              .font(CETheme.mono(11))
              .foregroundStyle(CETheme.muted)
          }
        }
      }
    }
  }
}

// MARK: - Dex

private struct DexTab: View {
  let snap: CompanionSnapshot

  private enum Filter: String, CaseIterable, Identifiable {
    case all = "All", seen = "Seen", caught = "Caught"
    var id: String { rawValue }
  }

  @State private var filter: Filter = .seen
  @State private var selected: Int?

  private let columns = [
    GridItem(.adaptive(minimum: 72), spacing: 10),
  ]

  var body: some View {
    if let dex = snap.dex {
      VStack(alignment: .leading, spacing: 12) {
        CompanionCard {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
              Text("\(dex.caught)")
                .font(CETheme.sans(28, weight: .bold))
                .foregroundStyle(CETheme.accent)
              Text("Caught")
                .font(CETheme.sans(11, weight: .semibold))
                .foregroundStyle(CETheme.muted)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
              Text("\(dex.seen)")
                .font(CETheme.sans(28, weight: .bold))
                .foregroundStyle(CETheme.crystal)
              Text("Seen")
                .font(CETheme.sans(11, weight: .semibold))
                .foregroundStyle(CETheme.muted)
            }
          }
          HPBar(hp: dex.caught, maxHp: max(dex.total, 1))
          Text("\(dex.caught) / \(dex.total) caught · \(dex.seen) seen\(dex.nationalUnlocked ? "" : " · National Dex locked")")
            .font(CETheme.sans(11))
            .foregroundStyle(CETheme.muted)
          Text("Color = caught · grayscale = seen only. Tap a Pokémon for more.")
            .font(CETheme.sans(10))
            .foregroundStyle(CETheme.muted.opacity(0.9))
        }

        Picker("Filter", selection: $filter) {
          ForEach(Filter.allCases) { f in Text(f.rawValue).tag(f) }
        }
        .pickerStyle(.segmented)

        LazyVGrid(columns: columns, spacing: 10) {
          ForEach(rows(dex), id: \.self) { n in
            Button {
              selected = n
            } label: {
              DexCell(
                number: n,
                configId: snap.configId,
                caught: dex.caughtSet.contains(n),
                seen: dex.seenSet.contains(n)
              )
            }
            .buttonStyle(.plain)
            .disabled(!dex.seenSet.contains(n) && !dex.caughtSet.contains(n))
          }
        }
      }
      .sheet(item: Binding(
        get: { selected.map { DexSelection(id: $0) } },
        set: { selected = $0?.id }
      )) { sel in
        DexDetailSheet(
          number: sel.id,
          configId: snap.configId,
          caught: dex.caughtSet.contains(sel.id),
          seen: dex.seenSet.contains(sel.id),
          tables: snap.tables,
          gameName: snap.gameName
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
      }
    } else {
      CompanionNote("Reading the Pokédex from your save… keep playing or open the in-game Pokédex once so flags update.")
    }
  }

  private func rows(_ dex: DexSummary) -> [Int] {
    (1...dex.total).filter { n in
      switch filter {
      case .all: return true
      case .seen: return dex.seenSet.contains(n)
      case .caught: return dex.caughtSet.contains(n)
      }
    }
  }
}

private struct DexSelection: Identifiable {
  let id: Int
}

private struct DexCell: View {
  let number: Int
  let configId: String
  let caught: Bool
  let seen: Bool

  private var known: Bool { seen || caught }
  private var national: Int { Gen3Names.nationalForDexNumber(number, configId: configId) }
  private var displayName: String { Gen3Names.dexDisplayName(number, configId: configId) }

  var body: some View {
    VStack(spacing: 4) {
      SpeciesIconView(
        nationalDex: known ? national : nil,
        size: 44,
        grayscale: known && !caught,
        hidden: !known
      )
      Text(String(format: "#%03d", number))
        .font(CETheme.mono(9))
        .foregroundStyle(CETheme.muted)
      Text(known ? displayName : "???")
        .font(CETheme.sans(10, weight: .medium))
        .foregroundStyle(known ? CETheme.text : CETheme.muted)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
    .background(CETheme.card.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(caught ? CETheme.accent.opacity(0.55) : CETheme.border.opacity(0.5), lineWidth: 1)
    )
  }
}

private struct DexDetailSheet: View {
  let number: Int
  let configId: String
  let caught: Bool
  let seen: Bool
  let tables: Gen3Tables
  let gameName: String

  @Environment(\.dismiss) private var dismiss

  private var national: Int { Gen3Names.nationalForDexNumber(number, configId: configId) }
  private var name: String { Gen3Names.dexDisplayName(number, configId: configId) }
  private var types: Gen3BattleData.SpeciesTypes? {
    if tables == .modernEmerald {
      let sid = Gen3Names.speciesIdForDexNumber(number, configId: configId)
      return Gen3BattleData.speciesTypes(sid, tables: .modernEmerald)
    }
    if tables == .hns {
      return Gen3BattleData.speciesTypes(national, tables: .hns)
        ?? Gen3BattleData.speciesTypes(national, tables: .national)
    }
    return Gen3BattleData.speciesTypes(national, tables: .national)
      ?? Gen3BattleData.speciesTypes(national, tables: tables)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 16) {
            SpeciesIconView(
              nationalDex: national,
              size: 84,
              grayscale: !caught
            )
            .padding(10)
            .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
              Text(String(format: "No. %03d", number))
                .font(CETheme.mono(12))
                .foregroundStyle(CETheme.muted)
              Text(name)
                .font(CETheme.sans(24, weight: .bold))
                .foregroundStyle(CETheme.text)
              HStack(spacing: 6) {
                statusChip(caught ? "Caught" : "Seen", color: caught ? CETheme.accent : CETheme.crystal)
                if let types {
                  typeChip(types.type1)
                  if types.type2 != Gen3BattleData.typeNone, types.type2 != types.type1 {
                    typeChip(types.type2)
                  }
                }
              }
            }
            Spacer(minLength: 0)
          }

          CompanionCard {
            VStack(alignment: .leading, spacing: 8) {
              Text("In-game")
                .font(CETheme.sans(12, weight: .semibold))
                .foregroundStyle(CETheme.muted)
              Text(gameName)
                .font(CETheme.sans(14, weight: .medium))
                .foregroundStyle(CETheme.text)
              Text(caught
                   ? "Registered as owned in your Pokédex."
                   : "Seen in the wild or in battle, but not caught yet.")
                .font(CETheme.sans(13))
                .foregroundStyle(CETheme.muted)
            }
          }

          if let types {
            CompanionCard {
              VStack(alignment: .leading, spacing: 8) {
                Text("Types")
                  .font(CETheme.sans(12, weight: .semibold))
                  .foregroundStyle(CETheme.muted)
                HStack(spacing: 8) {
                  typeChip(types.type1)
                  if types.type2 != Gen3BattleData.typeNone, types.type2 != types.type1 {
                    typeChip(types.type2)
                  }
                }
                Text("Type data from PocketDex’s battle tables (best-effort for ROM hacks).")
                  .font(CETheme.sans(11))
                  .foregroundStyle(CETheme.muted)
              }
            }
          }

          let places = Gen4Encounters.foundIn(species: number)
          if !places.isEmpty {
            CompanionCard {
              VStack(alignment: .leading, spacing: 8) {
                Text("Found in (HeartGold)")
                  .font(CETheme.sans(12, weight: .semibold))
                  .foregroundStyle(CETheme.muted)
                ForEach(places, id: \.self) { place in
                  Text(place)
                    .font(CETheme.sans(14, weight: .medium))
                    .foregroundStyle(CETheme.text)
                }
                Text("Wild locations from pret’s HeartGold encounter tables. SoulSilver shares most routes.")
                  .font(CETheme.sans(11))
                  .foregroundStyle(CETheme.muted)
              }
            }
          }

          CompanionNote("Sprites are National Dex menu icons (bundled through Gen 5). Flavor text / height / weight can come later.")
        }
        .padding(16)
      }
      .background(CETheme.bg.ignoresSafeArea())
      .navigationTitle("Pokédex")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .font(CETheme.sans(15, weight: .semibold))
        }
      }
    }
  }

  private func statusChip(_ title: String, color: Color) -> some View {
    Text(title)
      .font(CETheme.sans(11, weight: .bold))
      .foregroundStyle(.black.opacity(0.85))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.9), in: Capsule())
  }

  private func typeChip(_ type: Int) -> some View {
    let label = Gen3BattleData.typeName(type, tables: tables)
    return Text(label.isEmpty ? "—" : label)
      .font(CETheme.sans(11, weight: .bold))
      .foregroundStyle(CETheme.text)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(CETheme.elevated, in: Capsule())
      .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
  }
}

// MARK: - In-game settings (Display / Audio / Controls)

private struct InGameSettingsTab: View {
  @EnvironmentObject private var settings: AppSettings
  @EnvironmentObject private var engine: EmulatorEngine

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      CompanionNote("Changes apply immediately while you play.")

      section("Display") {
        cycle("Aspect", settings.gameAspect.title, settings.gameAspect.subtitle) {
          settings.gameAspect.cycle()
        }
        cycle(
          "Zoom",
          engine.zoomStepTitle,
          engine.wideSupported
            ? "Expand only — \(engine.zoomStepCount) steps on this screen"
            : "Needs Expand / WIDE for this ROM",
          enabled: settings.gameAspect == .expand && engine.wideSupported
        ) {
          engine.cycleZoom()
        }
        toggle(
          "Auto Zoom In",
          engine.wideSupported
            ? "Pull in during battles / menus (Expand)"
            : "Needs Expand / WIDE for this ROM",
          $settings.autoZoomIn
        )
        cycle("Status Bar", settings.statusBarMode.title, "Off or in-game strip") {
          settings.statusBarMode.cycle()
        }
        toggle("FPS Counter", "Show frames/sec on the play top bar", $settings.showFps)
        toggle(
          "Folder Layout",
          "Game on top, controls below — for Duo book / tabletop fold",
          $settings.folderLayout
        )
        cycle("DS Layout", settings.dsLayout.title, settings.dsLayout.subtitle) {
          settings.dsLayout.cycle()
        }
        toggle("Keep Screen Awake", "Prevent sleep while playing", $settings.keepScreenAwake)
      }

      section("Shaders") {
        cycle("Filter", settings.screenFilter.title, "LCD · LCD Paper · Scanlines · CRT") {
          settings.screenFilter.cycle()
        }
        cycle(
          "Grid",
          settings.gridStrength.title,
          "LCD / LCD Paper line strength",
          enabled: settings.screenFilter.hasGrid
        ) {
          settings.gridStrength.cycle()
        }
        cycle("Smoothing", settings.smoothing.title, "Softer pixel edges") {
          settings.smoothing.cycle()
        }
        toggle("GBA Colors", "Darker LCD palette", $settings.gbaColors)
        toggle("Unlit Screen", "Reflective grey-green GBA look", $settings.unlitScreen)
      }

      section("Audio & Controls") {
        toggle("Game Audio", "Sound from GB / GBC / GBA", $settings.audioEnabled)
        toggle("Touch Haptics", "Vibrate on pad presses", $settings.hapticsEnabled)
      }
    }
  }

  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title.uppercased())
        .font(CETheme.sans(11, weight: .bold))
        .tracking(0.8)
        .foregroundStyle(CETheme.crystal)
        .padding(.bottom, 8)
      content()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(CETheme.border, lineWidth: 1))
  }

  private func cycle(_ title: String, _ value: String, _ subtitle: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(CETheme.sans(14, weight: .semibold))
            .foregroundStyle(enabled ? CETheme.text : CETheme.muted)
          Text(subtitle)
            .font(CETheme.sans(11))
            .foregroundStyle(CETheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Text(value)
          .font(CETheme.sans(12, weight: .medium))
          .foregroundStyle(CETheme.crystal)
          .multilineTextAlignment(.trailing)
      }
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.5)
  }

  private func toggle(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
    Toggle(isOn: binding) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(CETheme.sans(14, weight: .semibold))
          .foregroundStyle(CETheme.text)
        Text(subtitle)
          .font(CETheme.sans(11))
          .foregroundStyle(CETheme.muted)
      }
    }
    .tint(CETheme.crystal)
    .padding(.vertical, 6)
  }
}
