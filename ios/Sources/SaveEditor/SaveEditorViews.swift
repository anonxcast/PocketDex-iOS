import SwiftUI

// MARK: - Library list

/// Games that already have a battery `.sav` under Documents/Saves — open one to edit.
struct SaveEditorListView: View {
  let roms: [RomItem]
  let engineLoadedStem: String?

  @ObservedObject private var recentlyPlayed = RecentlyPlayedStore.shared

  private var entries: [RomItem] {
    roms.filter { FileManager.default.fileExists(atPath: RomLibrary.savePath(forRom: $0.url).path) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// Single most-recent game that still has a battery save.
  private var mostRecent: RomItem? {
    recentlyPlayed.recent(in: entries, limit: 1).first
  }

  /// Save-backed ROMs grouped in console / generation order (empty groups omitted).
  private var generationSections: [(title: String, roms: [RomItem])] {
    SaveEditorGeneration.allCases.compactMap { gen in
      let rows = entries.filter { SaveEditorGeneration.classify($0) == gen }
      guard !rows.isEmpty else { return nil }
      return (gen.title, rows)
    }
  }

  var body: some View {
    NavigationStack {
      Group {
        if entries.isEmpty {
          VStack(spacing: 14) {
            Image(systemName: "externaldrive.fill.badge.pencil")
              .font(.system(size: 36, weight: .semibold))
              .foregroundStyle(CETheme.muted)
            Text("No saves yet")
              .font(CETheme.sans(17, weight: .semibold))
              .foregroundStyle(CETheme.text)
            Text("Play a game at least once so PocketDex writes its .sav, then come back here to edit party, bag, and money.")
              .font(CETheme.sans(13))
              .foregroundStyle(CETheme.muted)
              .multilineTextAlignment(.center)
              .padding(.horizontal, 28)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
              Text("Edit battery saves while the game is closed. A .sav.bak backup is written before every save.")
                .font(CETheme.sans(12))
                .foregroundStyle(CETheme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

              if let recent = mostRecent {
                sectionHeader("Recently Played")
                NavigationLink {
                  SaveEditorHostView(rom: recent, engineLoadedStem: engineLoadedStem)
                } label: {
                  saveRow(recent, highlight: true)
                }
                .buttonStyle(.plain)
              }

              ForEach(generationSections, id: \.title) { section in
                sectionHeader(section.title)
                ForEach(section.roms) { rom in
                  NavigationLink {
                    SaveEditorHostView(rom: rom, engineLoadedStem: engineLoadedStem)
                  } label: {
                    saveRow(rom)
                  }
                  .buttonStyle(.plain)
                }
              }

              Text("Optimized GBA hacks (Radical Red, Unbound, Seaglass, …) use expanded species ids — open them here after closing the game.")
                .font(CETheme.sans(11))
                .foregroundStyle(CETheme.muted)
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
          }
        }
      }
      .background(CETheme.bg)
      .navigationBarHidden(true)
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(CETheme.sans(13, weight: .semibold))
      .foregroundStyle(CETheme.muted)
      .textCase(.uppercase)
      .tracking(0.6)
      .padding(.top, 4)
  }

  private func saveRow(_ rom: RomItem, highlight: Bool = false) -> some View {
    let save = RomLibrary.savePath(forRom: rom.url)
    let size = (try? FileManager.default.attributesOfItem(atPath: save.path)[.size] as? NSNumber)?.int64Value ?? 0
    let gen = SaveEditorGeneration.classify(rom)
    return HStack(spacing: 12) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(highlight ? CETheme.crystal.opacity(0.12) : CETheme.card)
        if let kind = rom.console {
          ConsoleRailIcon(kind: kind)
            .frame(width: 22, height: 22)
            .foregroundStyle(CETheme.crystal)
        }
      }
      .frame(width: 44, height: 44)
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(
        highlight ? CETheme.crystal.opacity(0.45) : CETheme.border, lineWidth: 1))

      VStack(alignment: .leading, spacing: 3) {
        Text(rom.name)
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(CETheme.text)
          .lineLimit(1)
        Text("\(gen.shortLabel) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
          .font(CETheme.mono(11))
          .foregroundStyle(CETheme.muted)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(CETheme.muted)
    }
    .padding(12)
    .background(
      (highlight ? CETheme.crystal.opacity(0.08) : CETheme.card),
      in: RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous)
    )
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(
      highlight ? CETheme.crystal.opacity(0.35) : CETheme.border, lineWidth: 1))
  }
}

/// Save-editor grouping: console → Pokémon generation bucket.
private enum SaveEditorGeneration: Int, CaseIterable {
  case gen1, gen2, gen3, gen45

  var title: String {
    switch self {
    case .gen1: return "Gen 1 · Game Boy"
    case .gen2: return "Gen 2 · Game Boy Color"
    case .gen3: return "Gen 3 · Game Boy Advance"
    case .gen45: return "Gen 4–5 · Nintendo DS"
    }
  }

  var shortLabel: String {
    switch self {
    case .gen1: return "Gen 1"
    case .gen2: return "Gen 2"
    case .gen3: return "Gen 3"
    case .gen45: return "Gen 4–5"
    }
  }

  static func classify(_ rom: RomItem) -> SaveEditorGeneration {
    switch rom.console {
    case .gb: return .gen1
    case .gbc: return .gen2
    case .gba: return .gen3
    case .nds: return .gen45
    case .none:
      switch rom.url.pathExtension.lowercased() {
      case "gb": return .gen1
      case "gbc": return .gen2
      case "nds": return .gen45
      default: return .gen3
      }
    }
  }
}

// MARK: - Host (opens session)

struct SaveEditorHostView: View {
  let rom: RomItem
  let engineLoadedStem: String?

  @State private var session: SaveSession?
  @State private var openError: String?

  var body: some View {
    Group {
      if let session {
        SaveEditorDetailView(session: session, romName: rom.name, romURL: rom.url)
      } else if let openError {
        VStack(spacing: 12) {
          Text("Can't open this save")
            .font(CETheme.sans(17, weight: .semibold))
            .foregroundStyle(CETheme.text)
          Text(openError)
            .font(CETheme.sans(13))
            .foregroundStyle(CETheme.muted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ProgressView("Opening save…")
          .tint(CETheme.accent)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(CETheme.bg)
    .navigationTitle(rom.name)
    .navigationBarTitleDisplayMode(.inline)
    .onAppear(perform: open)
  }

  private func open() {
    if let s = SaveSession.open(rom: rom.url, engineLoadedStem: engineLoadedStem) {
      session = s
    } else {
      openError = "This .sav isn't a recognised Gen 1–5 layout. Save once in-game first. Supported GBA hacks: Radical Red, Unbound, Seaglass, Rocket Edition, Crystal Advance Redux, Modern Emerald, Heart and Soul, SoulGold, R.O.W.E., plus retail R/S/E/FR/LG."
    }
  }
}

// MARK: - Detail tabs

private enum SaveEditorTab: String, CaseIterable, Identifiable {
  case party, boxes, bag, trainer, dex, trade
  var id: String { rawValue }
  var title: String {
    switch self {
    case .party: return "Party"
    case .boxes: return "Boxes"
    case .bag: return "Bag"
    case .trainer: return "Trainer"
    case .dex: return "Dex"
    case .trade: return "Trade"
    }
  }
}

struct SaveEditorDetailView: View {
  @ObservedObject var session: SaveSession
  let romName: String
  let romURL: URL

  @State private var tab: SaveEditorTab = .party
  @State private var editingMon: SaveMon?
  @State private var showAddMon = false
  @State private var showAddItem = false
  @State private var moneyText = ""
  @State private var coinsText = ""
  @State private var trainerNameText = ""
  @State private var trainerFemale = false
  @State private var markSpeciesText = ""
  @State private var alertMessage: String?
  @State private var showSavedToast = false
  @State private var boxFilter = 0

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(session.gameLabel)
          .font(CETheme.mono(11))
          .foregroundStyle(CETheme.muted)
        Spacer()
        Text(session.readOnly ? "Read-only" : (session.hasChanges ? "Unsaved" : "Writable"))
          .font(CETheme.sans(11, weight: .semibold))
          .foregroundStyle(session.readOnly ? Color.orange : (session.hasChanges ? CETheme.crystal : CETheme.muted))
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)

      if session.readOnly, let why = session.readOnlyReason {
        Text(why)
          .font(CETheme.sans(12))
          .foregroundStyle(Color(red: 1, green: 0.75, blue: 0.35))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(CETheme.elevated)
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(SaveEditorTab.allCases) { t in
            Button {
              tab = t
            } label: {
              Text(t.title)
                .font(CETheme.sans(12, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(tab == t ? CETheme.crystal.opacity(0.22) : CETheme.card, in: Capsule())
                .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
                .foregroundStyle(CETheme.text)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }

      ScrollView {
        switch tab {
        case .party: partyBody
        case .boxes: boxesBody
        case .bag: bagBody
        case .trainer: trainerBody
        case .dex: dexBody
        case .trade: SaveTradeView(primary: session, primaryRomURL: romURL)
        }
      }
    }
    .background(CETheme.bg)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") { commit() }
          .disabled(session.readOnly || !session.hasChanges)
          .font(CETheme.sans(15, weight: .semibold))
      }
    }
    .sheet(item: $editingMon) { mon in
      SaveMonEditorSheet(session: session, mon: mon) {
        editingMon = nil
      }
    }
    .sheet(isPresented: $showAddMon) {
      SaveAddMonSheet(session: session) {
        showAddMon = false
      }
    }
    .sheet(isPresented: $showAddItem) {
      SaveAddItemSheet(session: session) {
        showAddItem = false
      }
    }
    .alert("Save Editor", isPresented: Binding(
      get: { alertMessage != nil },
      set: { if !$0 { alertMessage = nil } }
    )) {
      Button("OK", role: .cancel) { alertMessage = nil }
    } message: {
      Text(alertMessage ?? "")
    }
    .overlay(alignment: .bottom) {
      if showSavedToast {
        Text("Saved · backup at .sav.bak")
          .font(CETheme.sans(13, weight: .semibold))
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(CETheme.card, in: Capsule())
          .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
          .padding(.bottom, 24)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
  }

  private var partyBody: some View {
    let _ = session.revision
    let party = session.party()
    return LazyVStack(spacing: 8) {
      if session.canAddPartyMon {
        Button {
          showAddMon = true
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
              .foregroundStyle(CETheme.crystal)
            Text("Add Pokémon to Party")
              .font(CETheme.sans(15, weight: .semibold))
              .foregroundStyle(CETheme.text)
            Spacer()
            Text("\(party.count)/6")
              .font(CETheme.mono(12))
              .foregroundStyle(CETheme.muted)
          }
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(CETheme.crystal.opacity(0.45), lineWidth: 1))
        }
        .buttonStyle(.plain)
      }

      if party.isEmpty {
        Text("No Pokémon in the party.")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .padding(.top, 24)
      }
      ForEach(Array(party.enumerated()), id: \.element.id) { idx, mon in
        monRow(mon, accessibility: "Edit party slot \(idx + 1)")
      }
    }
    .padding(16)
  }

  private var boxesBody: some View {
    let _ = session.revision
    let boxes = session.boxes()
    return VStack(alignment: .leading, spacing: 12) {
      if boxes.isEmpty {
        Text(session.generation == .gen3
             ? "No PC data."
             : "PC boxes for this generation aren't fully mapped yet (Gen 3 has all 14; Gen 1 shows the current box).")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .padding(.top, 12)
      } else {
        if boxes.count > 1 {
          Picker("Box", selection: $boxFilter) {
            ForEach(boxes) { b in
              Text(b.name).tag(b.index)
            }
          }
          .pickerStyle(.menu)
        }
        let shown = boxes.first(where: { $0.index == boxFilter }) ?? boxes[0]
        Text("\(shown.name) · \(shown.mons.count) Pokémon")
          .font(CETheme.sans(12, weight: .semibold))
          .foregroundStyle(CETheme.muted)
        LazyVStack(spacing: 8) {
          ForEach(shown.mons) { mon in
            monRow(mon, accessibility: mon.nickname.isEmpty ? "Box mon" : mon.nickname, editable: false)
          }
        }
      }
    }
    .padding(16)
    .onAppear {
      if let first = session.boxes().first { boxFilter = first.index }
    }
  }

  private var bagBody: some View {
    let _ = session.revision
    let items = session.bag()
    let pockets = BagPocket.allCases.filter { p in items.contains { $0.pocket == p.id } }
    return LazyVStack(alignment: .leading, spacing: 16) {
      if session.generation == .gen3, !session.readOnly {
        Button {
          showAddItem = true
        } label: {
          HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(CETheme.crystal)
            VStack(alignment: .leading, spacing: 2) {
              Text("Add item")
                .font(CETheme.sans(15, weight: .semibold))
                .foregroundStyle(CETheme.text)
              Text("Pick a pocket, item, and quantity")
                .font(CETheme.sans(12))
                .foregroundStyle(CETheme.muted)
            }
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(CETheme.muted)
          }
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 14).stroke(CETheme.crystal.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
      }

      if items.isEmpty {
        Text(session.generation == .gen3
             ? "Bag is empty — use Add item to stock potions, balls, TMs, or berries."
             : "Bag is empty or this layout doesn't expose items yet.")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .padding(.top, 8)
      }

      ForEach(pockets) { pocket in
        let stacks = items.filter { $0.pocket == pocket.id }
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            Image(systemName: pocket.symbol)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(CETheme.crystal)
            Text(pocket.title)
              .font(CETheme.sans(12, weight: .bold))
              .foregroundStyle(CETheme.muted)
              .textCase(.uppercase)
              .tracking(0.4)
            Spacer()
            Text("\(stacks.count)")
              .font(CETheme.mono(11))
              .foregroundStyle(CETheme.muted)
          }
          ForEach(Array(stacks.enumerated()), id: \.element.id) { idx, stack in
            bagStackRow(stack, pocket: pocket, indexInPocket: idx)
          }
        }
      }
    }
    .padding(16)
  }

  private func bagStackRow(_ stack: SaveItemStack, pocket: BagPocket, indexInPocket: Int) -> some View {
    HStack(spacing: 12) {
      ItemIconView(itemId: stack.item, tables: tablesForSession, size: 32)
        .padding(4)
        .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(itemName(stack.item))
          .font(CETheme.sans(15, weight: .medium))
          .foregroundStyle(CETheme.text)
          .lineLimit(1)
        if session.generation == .gen3, !session.readOnly, pocket != .key {
          HStack(spacing: 10) {
            Button {
              try? session.setBagQuantity(
                pocket: pocket, index: indexInPocket,
                quantity: max(0, stack.quantity - 1)
              )
            } label: {
              Image(systemName: "minus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(CETheme.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            Text("×\(stack.quantity)")
              .font(CETheme.sans(14, weight: .semibold))
              .foregroundStyle(CETheme.accent)
              .frame(minWidth: 36)
            Button {
              let cap = session.gen3Editor.map { $0.file.format.stackMax(pocket: pocket, item: stack.item) } ?? 999
              try? session.setBagQuantity(
                pocket: pocket, index: indexInPocket,
                quantity: min(cap, stack.quantity + 1)
              )
            } label: {
              Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(CETheme.elevated, in: Circle())
            }
            .buttonStyle(.plain)
          }
        } else {
          Text("×\(stack.quantity)")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(CETheme.accent)
        }
      }
      Spacer(minLength: 0)
      if session.generation == .gen3, !session.readOnly, pocket != .key {
        Menu {
          Button("Set to 99") {
            try? session.setBagQuantity(pocket: pocket, index: indexInPocket, quantity: 99)
          }
          Button("Set to max") {
            let cap = session.gen3Editor.map { $0.file.format.stackMax(pocket: pocket, item: stack.item) } ?? 999
            try? session.setBagQuantity(pocket: pocket, index: indexInPocket, quantity: cap)
          }
          Button("Remove", role: .destructive) {
            try? session.setBagQuantity(pocket: pocket, index: indexInPocket, quantity: 0)
          }
        } label: {
          Image(systemName: "ellipsis.circle")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(CETheme.muted)
        }
      }
    }
    .padding(12)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(CETheme.border, lineWidth: 1))
  }

  private var trainerBody: some View {
    let _ = session.revision
    let t = session.trainer()
    return VStack(alignment: .leading, spacing: 16) {
      if let t {
        trainerCard("Identity") {
          VStack(alignment: .leading, spacing: 12) {
            if session.generation == .gen3 || session.generation == .gen4 || session.generation == .gen5 {
              Text("Name")
                .font(CETheme.sans(11, weight: .semibold))
                .foregroundStyle(CETheme.muted)
              TextField("Trainer name", text: $trainerNameText)
                .textInputAutocapitalization(.characters)
                .font(CETheme.sans(16, weight: .semibold))
                .padding(12)
                .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(session.readOnly)
              Button("Apply name") { applyTrainerName() }
                .font(CETheme.sans(14, weight: .semibold))
                .disabled(session.readOnly)
            } else {
              labeled("Name", t.name.isEmpty ? "—" : t.name)
            }

            if session.generation == .gen3, !session.readOnly {
              Text("Gender")
                .font(CETheme.sans(11, weight: .semibold))
                .foregroundStyle(CETheme.muted)
              Picker("Gender", selection: $trainerFemale) {
                Text("Boy").tag(false)
                Text("Girl").tag(true)
              }
              .pickerStyle(.segmented)
              .onChange(of: trainerFemale) { female in
                try? session.setTrainerFemale(female)
              }
            } else {
              labeled("Gender", t.isFemale ? "Girl" : "Boy")
            }

            HStack(spacing: 16) {
              labeled("Trainer ID", "\(t.trainerId)")
              if t.secretId > 0 { labeled("Secret ID", "\(t.secretId)") }
            }
            labeled("Play time", t.playTime.isEmpty ? "—" : t.playTime)
          }
        }

        trainerCard("Money") {
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              TextField("0", text: $moneyText)
                .keyboardType(.numberPad)
                .font(CETheme.mono(18))
                .foregroundStyle(CETheme.text)
                .padding(12)
                .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(session.readOnly)
              Button("Apply") { applyMoney() }
                .font(CETheme.sans(14, weight: .semibold))
                .disabled(session.readOnly)
            }
            HStack(spacing: 8) {
              ForEach([0, 50_000, 100_000, 999_999], id: \.self) { amount in
                Button(amount == 0 ? "0" : (amount >= 999_999 ? "Max" : "\(amount / 1000)k")) {
                  moneyText = "\(amount)"
                  applyMoney()
                }
                .font(CETheme.sans(12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(CETheme.elevated, in: Capsule())
                .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
                .foregroundStyle(CETheme.text)
                .disabled(session.readOnly)
              }
            }
          }
        }

        if session.generation == .gen1 || session.generation == .gen2 || session.generation == .gen3
            || session.generation == .gen4 {
          trainerCard("Coins") {
            HStack {
              TextField("0", text: $coinsText)
                .keyboardType(.numberPad)
                .font(CETheme.mono(16))
                .padding(12)
                .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .disabled(session.readOnly)
              Button("Apply") { applyCoins() }
                .font(CETheme.sans(14, weight: .semibold))
                .disabled(session.readOnly)
            }
          }
        }
      } else {
        Text("No trainer block on this save.")
          .foregroundStyle(CETheme.muted)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onAppear { syncTrainerFields() }
    .onChange(of: session.revision) { _ in syncTrainerFields() }
  }

  private func trainerCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(CETheme.sans(12, weight: .semibold))
        .foregroundStyle(CETheme.muted)
        .textCase(.uppercase)
        .tracking(0.5)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))
  }

  private func syncTrainerFields() {
    guard let t = session.trainer() else { return }
    moneyText = "\(t.money)"
    coinsText = "\(t.coins)"
    trainerNameText = t.name
    trainerFemale = t.isFemale
  }

  private var dexBody: some View {
    let _ = session.revision
    return VStack(alignment: .leading, spacing: 14) {
      if let d = session.dex() {
        labeled("Owned", "\(d.owned) / \(d.max)")
        labeled("Seen", "\(d.seen) / \(d.max)")
        if let nat = d.nationalEnabled {
          labeled("National Dex", nat ? "On" : "Off")
        }
        if session.generation == .gen3, !session.readOnly {
          VStack(alignment: .leading, spacing: 8) {
            Text("Mark caught")
              .font(CETheme.sans(12, weight: .semibold))
              .foregroundStyle(CETheme.muted)
            SaveEditorCatalogPicker(
              title: "Pokémon",
              selection: Binding(
                get: { Int(markSpeciesText) ?? 0 },
                set: { markSpeciesText = $0 > 0 ? "\($0)" : "" }
              ),
              entries: SaveEditorCatalog.species(tables: tablesForSession),
              allowNone: true,
              showSprites: true,
              tables: tablesForSession
            )
            Button("Mark Caught") {
              if let sp = Int(markSpeciesText), sp > 0 {
                do { try session.markDexCaught(sp) }
                catch { alertMessage = "\(error)" }
              }
            }
            .font(CETheme.sans(14, weight: .semibold))
            .disabled((Int(markSpeciesText) ?? 0) <= 0)
          }
        }
      } else {
        Text("Pokédex flags aren't exposed for this format yet.")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func monRow(_ mon: SaveMon, accessibility: String, editable: Bool = true) -> some View {
    Button {
      if editable { editingMon = mon }
    } label: {
      HStack(spacing: 12) {
        SpeciesIconView(
          nationalDex: Gen3Names.nationalNumber(species: mon.species, tables: tablesForSession),
          size: 36
        )
        VStack(alignment: .leading, spacing: 2) {
          Text(mon.nickname.isEmpty ? Gen3Names.species(mon.species, tables: tablesForSession) : mon.nickname)
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(CETheme.text)
          Text(monRowSubtitle(mon))
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
            .lineLimit(1)
        }
        Spacer()
        if mon.shiny {
          Text("✦").foregroundStyle(CETheme.crystal)
        }
        if editable {
          Image(systemName: "pencil")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CETheme.muted)
        }
      }
      .padding(12)
      .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(CETheme.border, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .disabled(session.readOnly || !editable)
    .opacity(session.readOnly ? 0.7 : 1)
    .accessibilityLabel(accessibility)
  }

  private var tablesForSession: Gen3Tables { session.nameTables }

  private func labeled(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(CETheme.sans(12, weight: .semibold))
        .foregroundStyle(CETheme.muted)
      Text(value)
        .font(CETheme.sans(16, weight: .medium))
        .foregroundStyle(CETheme.text)
    }
  }

  private func itemName(_ id: Int) -> String {
    Gen3Names.item(id, tables: tablesForSession)
  }

  private func monRowSubtitle(_ mon: SaveMon) -> String {
    let moveNames = mon.moves.filter { $0 > 0 }.prefix(2).map { Gen3Names.move($0, tables: tablesForSession) }
    let moves = moveNames.isEmpty ? "No moves" : moveNames.joined(separator: " · ")
    return "Lv \(mon.level) · \(moves)"
  }

  private func applyMoney() {
    guard let v = Int(moneyText.filter(\.isNumber)) else {
      alertMessage = "Enter a whole number for money."
      return
    }
    do {
      try session.setMoney(v)
    } catch {
      alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }

  private func applyCoins() {
    guard let v = Int(coinsText.filter(\.isNumber)) else {
      alertMessage = "Enter a whole number for coins."
      return
    }
    do {
      try session.setCoins(v)
    } catch {
      alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }

  private func applyTrainerName() {
    do {
      try session.setTrainerName(trainerNameText)
    } catch {
      alertMessage = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
  }

  private func commit() {
    do {
      try session.commit()
      withAnimation { showSavedToast = true }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        withAnimation { showSavedToast = false }
      }
    } catch {
      alertMessage = (error as? LocalizedError)?.errorDescription
        ?? (error as? CustomStringConvertible)?.description
        ?? "\(error)"
    }
  }
}

// MARK: - Same-gen trade (Gen 3 PC)

struct SaveTradeView: View {
  @ObservedObject var primary: SaveSession
  let primaryRomURL: URL

  @State private var partnerRoms: [RomItem] = []
  @State private var partner: SaveSession?
  @State private var partnerURL: URL?
  @State private var fromBox = 0
  @State private var fromSlot = 0
  @State private var toBox = 0
  @State private var toSlot = 0
  @State private var message: String?
  @State private var engineStem: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Same-generation trade")
        .font(CETheme.sans(16, weight: .semibold))
        .foregroundStyle(CETheme.text)

      if primary.generation != .gen3 {
        Text("Full trade rules are Gen 3 for now. Open two GBA saves to move PC Pokémon between them.")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
      } else if primary.readOnly {
        Text("This save is read-only — close the game or fix the layout before trading.")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
      } else {
        Text("Pick another Gen 3 save, choose a filled PC slot here and an empty slot there, then Send. Both saves get .sav.bak on Save.")
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)

        Picker("Partner", selection: Binding(
          get: { partnerURL?.path ?? "" },
          set: { path in
            partnerURL = path.isEmpty ? nil : URL(fileURLWithPath: path)
            openPartner()
          }
        )) {
          Text("Choose…").tag("")
          ForEach(partnerRoms) { rom in
            Text(rom.name).tag(rom.url.path)
          }
        }
        .pickerStyle(.menu)

        if let partner {
          HStack {
            VStack(alignment: .leading) {
              Text("From \(primary.gameLabel)")
                .font(CETheme.sans(12, weight: .semibold))
              Stepper("Box \(fromBox + 1)", value: $fromBox, in: 0...13)
              Stepper("Slot \(fromSlot + 1)", value: $fromSlot, in: 0...29)
            }
            Spacer()
            VStack(alignment: .leading) {
              Text("To \(partner.gameLabel)")
                .font(CETheme.sans(12, weight: .semibold))
              Stepper("Box \(toBox + 1)", value: $toBox, in: 0...13)
              Stepper("Slot \(toSlot + 1)", value: $toSlot, in: 0...29)
            }
          }

          Button("Send →") { sendTrade() }
            .font(CETheme.sans(15, weight: .semibold))
            .disabled(partner.readOnly)

          Button("Save both") { saveBoth() }
            .font(CETheme.sans(14, weight: .semibold))
            .disabled((!primary.hasChanges && !(partner.hasChanges)) || primary.readOnly || partner.readOnly)
        }

        if let message {
          Text(message)
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
        }
      }
    }
    .padding(16)
    .onAppear(perform: loadPartners)
  }

  private func loadPartners() {
    partnerRoms = RomLibrary.listRoms()
      .filter {
        $0.url.pathExtension.lowercased() == "gba"
          && $0.url != primaryRomURL
          && FileManager.default.fileExists(atPath: RomLibrary.savePath(forRom: $0.url).path)
      }
  }

  private func openPartner() {
    guard let url = partnerURL else { partner = nil; return }
    partner = SaveSession.open(rom: url, engineLoadedStem: engineStem)
    if partner?.generation != .gen3 {
      message = "Partner isn't a Gen 3 save."
      partner = nil
    } else {
      message = nil
    }
  }

  private func sendTrade() {
    guard let partner,
          let aEd = primary.gen3Editor,
          let bEd = partner.gen3Editor else { return }
    let a = Gen3TradeSide(label: primary.gameLabel, editor: aEd, gameCode: gameCode(primaryRomURL) ?? "BPRE")
    let b = Gen3TradeSide(label: partner.gameLabel, editor: bEd, gameCode: gameCode(partnerURL!) ?? "BPRE")
    do {
      try Gen3Trade.send(
        src: a, at: BoxSlot(box: fromBox, slot: fromSlot),
        dest: b, to: BoxSlot(box: toBox, slot: toSlot)
      )
      primary.noteMutated()
      partner.noteMutated()
      message = "Trade applied in memory — tap Save both."
    } catch {
      message = "\(error)"
    }
  }

  private func saveBoth() {
    do {
      try primary.commit()
      try partner?.commit()
      message = "Both saves written (.sav.bak kept)."
    } catch {
      message = "\(error)"
    }
  }

  private func gameCode(_ rom: URL) -> String? {
    guard let fh = try? FileHandle(forReadingFrom: rom) else { return nil }
    defer { try? fh.close() }
    try? fh.seek(toOffset: 0xAC)
    guard let d = try? fh.read(upToCount: 4), d.count == 4 else { return nil }
    return String(bytes: d, encoding: .ascii)
  }
}

// MARK: - Catalog helpers

enum SaveEditorCatalog {
  struct Entry: Identifiable, Hashable {
    let id: Int
    let name: String
  }

  private static func sorted(_ map: [Int: String], maxId: Int, skipZero: Bool = true) -> [Entry] {
    map
      .filter { (!skipZero || $0.key > 0) && $0.key <= maxId }
      .map { Entry(id: $0.key, name: $0.value) }
      .sorted {
        let a = $0.name.localizedCaseInsensitiveCompare($1.name)
        if a != .orderedSame { return a == .orderedAscending }
        return $0.id < $1.id
      }
  }

  static func species(tables: Gen3Tables) -> [Entry] {
    let maxId = Gen3SaveData.MAX_SPECIES
    switch tables {
    case .retail: return sorted(Gen3Names.speciesRetail, maxId: min(maxId, 412))
    case .unbound: return sorted(Gen3Names.speciesUnbound, maxId: maxId)
    case .national, .yellow, .crystal, .polished: return sorted(Gen3Names.speciesNational, maxId: maxId)
    }
  }

  static func moves(tables: Gen3Tables) -> [Entry] {
    // Per-game move lists (Gen 1 Yellow … Gen 5 / Seaglass), not a single Unbound table.
    let names = Gen3BattleData.moveNames(tables: tables)
    let maxId: Int
    switch tables {
    case .yellow: maxId = 165
    case .crystal: maxId = 251
    case .polished: maxId = 255
    case .retail: maxId = Gen3SaveData.LAST_MOVE_RETAIL
    case .unbound: maxId = Gen3SaveData.LAST_MOVE_EXPANDED
    case .national: maxId = Gen45Personal.gen5MaxMove
    }
    return sorted(names, maxId: maxId)
  }

  static func items(tables: Gen3Tables) -> [Entry] {
    let maxId = Gen3SaveData.MAX_ITEM
    switch tables {
    case .unbound: return sorted(Gen3Names.itemsUnbound, maxId: maxId)
    case .national: return sorted(Gen3Names.itemsSeaglass, maxId: maxId)
    default: return sorted(Gen3Names.itemsRetail, maxId: maxId)
    }
  }

  static let statLabels = ["HP", "Atk", "Def", "Spe", "SpA", "SpD"]
}

/// Searchable name picker (no raw ids in the label).
struct SaveEditorCatalogPicker: View {
  let title: String
  @Binding var selection: Int
  let entries: [SaveEditorCatalog.Entry]
  var allowNone: Bool = false
  var showSprites: Bool = false
  var showItemIcons: Bool = false
  /// Species / item name tables for this ROM (Unbound vs retail vs National).
  var tables: Gen3Tables = .retail
  /// When set (move pickers), ids this species can normally learn are listed first.
  var compatibleIds: Set<Int>? = nil
  var compatibleSectionTitle: String = "Can learn"
  var otherSectionTitle: String = "Not on learnset"

  @State private var showSheet = false

  private var selectedName: String {
    if selection <= 0 { return allowNone ? "None" : "Choose…" }
    if let named = entries.first(where: { $0.id == selection })?.name { return named }
    if showSprites { return Gen3Names.species(selection, tables: tables) }
    if showItemIcons { return Gen3Names.item(selection, tables: tables) }
    return Gen3Names.move(selection, tables: tables)
  }

  private var selectedIsOffLearnset: Bool {
    guard let compatibleIds, selection > 0, !compatibleIds.isEmpty else { return false }
    return !compatibleIds.contains(selection)
  }

  var body: some View {
    Button { showSheet = true } label: {
      HStack(spacing: 10) {
        if showSprites {
          SpeciesIconView(
            nationalDex: selection > 0
              ? Gen3Names.nationalNumber(species: selection, tables: tables)
              : nil,
            size: 28
          )
        } else if showItemIcons {
          ItemIconView(itemId: selection, tables: tables, size: 28)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(CETheme.sans(11, weight: .semibold))
            .foregroundStyle(CETheme.muted)
          Text(selectedName)
            .font(CETheme.sans(15, weight: .medium))
            .foregroundStyle(selectedIsOffLearnset ? Color.orange.opacity(0.95) : CETheme.text)
            .lineLimit(1)
          if selectedIsOffLearnset {
            Text("Not on learnset")
              .font(CETheme.sans(10, weight: .semibold))
              .foregroundStyle(Color.orange.opacity(0.85))
          }
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(CETheme.muted)
      }
      .padding(12)
      .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(CETheme.border, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .sheet(isPresented: $showSheet) {
      SaveEditorCatalogSheet(
        title: title,
        selection: $selection,
        entries: entries,
        allowNone: allowNone,
        showSprites: showSprites,
        showItemIcons: showItemIcons,
        tables: tables,
        compatibleIds: compatibleIds,
        compatibleSectionTitle: compatibleSectionTitle,
        otherSectionTitle: otherSectionTitle
      )
      .presentationDetents([.medium, .large])
    }
  }
}

private struct SaveEditorCatalogSheet: View {
  let title: String
  @Binding var selection: Int
  let entries: [SaveEditorCatalog.Entry]
  var allowNone: Bool
  var showSprites: Bool
  var showItemIcons: Bool
  var tables: Gen3Tables
  var compatibleIds: Set<Int>?
  var compatibleSectionTitle: String
  var otherSectionTitle: String
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  private var filtered: [SaveEditorCatalog.Entry] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty else { return entries }
    return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
  }

  private var compatibleEntries: [SaveEditorCatalog.Entry] {
    guard let compatibleIds, !compatibleIds.isEmpty else { return [] }
    return filtered.filter { compatibleIds.contains($0.id) }
  }

  private var otherEntries: [SaveEditorCatalog.Entry] {
    guard let compatibleIds, !compatibleIds.isEmpty else { return filtered }
    return filtered.filter { !compatibleIds.contains($0.id) }
  }

  private var useSections: Bool {
    guard let compatibleIds, !compatibleIds.isEmpty else { return false }
    return !compatibleEntries.isEmpty || !otherEntries.isEmpty
  }

  var body: some View {
    NavigationStack {
      List {
        if allowNone {
          Button {
            selection = 0
            dismiss()
          } label: {
            Text("None")
              .foregroundStyle(CETheme.text)
          }
        }
        if useSections {
          if !compatibleEntries.isEmpty {
            Section {
              ForEach(compatibleEntries) { entry in
                entryRow(entry, offLearnset: false)
              }
            } header: {
              Text(compatibleSectionTitle)
            }
          }
          if !otherEntries.isEmpty {
            Section {
              ForEach(otherEntries) { entry in
                entryRow(entry, offLearnset: true)
              }
            } header: {
              Text(otherSectionTitle)
            } footer: {
              Text("Still selectable — this species does not normally learn these moves.")
                .font(CETheme.sans(11))
            }
          }
        } else {
          ForEach(filtered) { entry in
            entryRow(entry, offLearnset: false)
          }
        }
      }
      .searchable(text: $query, prompt: "Search \(title.lowercased())")
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  @ViewBuilder
  private func entryRow(_ entry: SaveEditorCatalog.Entry, offLearnset: Bool) -> some View {
    Button {
      selection = entry.id
      dismiss()
    } label: {
      HStack(spacing: 12) {
        if showSprites {
          SpeciesIconView(
            nationalDex: Gen3Names.nationalNumber(species: entry.id, tables: tables),
            size: 32
          )
        } else if showItemIcons {
          ItemIconView(itemId: entry.id, tables: tables, size: 32)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text(entry.name)
            .font(CETheme.sans(15, weight: .medium))
            .foregroundStyle(offLearnset ? Color.orange.opacity(0.95) : CETheme.text)
          if offLearnset {
            Text("Not on learnset")
              .font(CETheme.sans(11))
              .foregroundStyle(CETheme.muted)
          }
        }
        Spacer()
        if entry.id == selection {
          Image(systemName: "checkmark")
            .foregroundStyle(CETheme.crystal)
        }
      }
    }
  }
}

// MARK: - Mon editor sheet

struct SaveMonEditorSheet: View {
  @ObservedObject var session: SaveSession
  let mon: SaveMon
  let onClose: () -> Void

  @State private var speciesId: Int
  @State private var level: Int
  @State private var heldItem: Int
  @State private var moveIds: [Int]
  @State private var nicknameText: String
  @State private var evs: [Int]
  @State private var ivs: [Int]
  @State private var shiny: Bool
  @State private var gender: Gen3MonGender
  @State private var nature: Int
  @State private var errorText: String?

  init(session: SaveSession, mon: SaveMon, onClose: @escaping () -> Void) {
    self.session = session
    self.mon = mon
    self.onClose = onClose
    _speciesId = State(initialValue: mon.species)
    _level = State(initialValue: mon.level)
    _heldItem = State(initialValue: mon.heldItem)
    _nicknameText = State(initialValue: mon.nickname)
    let moves = Array((mon.moves + [0, 0, 0, 0]).prefix(4))
    _moveIds = State(initialValue: moves)
    let e = (mon.evs + Array(repeating: 0, count: 6)).prefix(6)
    let i = (mon.ivs + Array(repeating: 0, count: 6)).prefix(6)
    _evs = State(initialValue: Array(e))
    _ivs = State(initialValue: Array(i))
    _shiny = State(initialValue: mon.shiny)
    let tables = session.nameTables
    _gender = State(initialValue: mon.gender
      ?? Gen3Gender.gender(species: mon.species, personality: 0, tables: tables))
    _nature = State(initialValue: mon.nature ?? 0)
  }

  private var slotIndex: Int? {
    Int(mon.id.split(separator: "-").last ?? "")
  }

  private var tables: Gen3Tables { session.nameTables }

  private var canEditSpeciesLevel: Bool {
    session.generation != .gen3
  }

  private var canEditEVsIVs: Bool {
    session.generation == .gen3 || session.generation == .gen4 || session.generation == .gen5
  }

  private var canEditShiny: Bool { session.generation == .gen3 }
  private var canEditNature: Bool {
    session.generation == .gen3 || session.generation == .gen4 || session.generation == .gen5
  }
  private var canEditGender: Bool {
    session.generation == .gen2 || session.generation == .gen3
      || session.generation == .gen4 || session.generation == .gen5
  }
  private var genderOptions: [Gen3MonGender] {
    if session.generation == .gen2 {
      return Gen2Gender.options(species: speciesId)
    }
    return Gen3Gender.options(species: speciesId, tables: tables)
  }

  private var nationalDex: Int? {
    Gen3Names.nationalNumber(species: speciesId, tables: tables) ?? speciesId
  }

  private var evTotal: Int { evs.reduce(0, +) }

  private var smartProfiles: [SmartEVProfile] {
    SmartEVProfiles.profiles(species: speciesId, nature: nature, tables: tables)
  }

  private var matchedSmartProfileId: String? {
    smartProfiles.first(where: { $0.evs == evs })?.id
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          heroCard
          identityCard
          if session.generation != .gen1 {
            heldItemCard
          }
          movesCard
          if canEditEVsIVs {
            smartEVCard
            statsCard(title: "IVs", values: $ivs, range: 0...31, footer: "0–31 each")
          }
          if let errorText {
            Text(errorText)
              .font(CETheme.sans(13))
              .foregroundStyle(Color.red.opacity(0.9))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(16)
      }
      .background(CETheme.bg)
      .navigationTitle(mon.nickname.isEmpty ? "Edit Pokémon" : mon.nickname)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onClose)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") { apply() }
            .fontWeight(.semibold)
            .disabled(session.readOnly)
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  private var heroCard: some View {
    HStack(spacing: 14) {
      SpeciesIconView(nationalDex: nationalDex, size: 64)
        .padding(10)
        .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))
      VStack(alignment: .leading, spacing: 6) {
        Text(Gen3Names.species(speciesId, tables: tables))
          .font(CETheme.sans(20, weight: .bold))
          .foregroundStyle(CETheme.text)
        Text("Level \(level)")
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.crystal)
        if shiny {
          Text("Shiny")
            .font(CETheme.sans(11, weight: .semibold))
            .foregroundStyle(CETheme.accent)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))
  }

  private var identityCard: some View {
    editorCard("Identity") {
      VStack(alignment: .leading, spacing: 10) {
        Text("Nickname")
          .font(CETheme.sans(11, weight: .semibold))
          .foregroundStyle(CETheme.muted)
        TextField("Nickname", text: $nicknameText)
          .textInputAutocapitalization(.characters)
          .font(CETheme.sans(16, weight: .medium))
          .padding(12)
          .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(CETheme.border, lineWidth: 1))

        if canEditShiny {
          Toggle(isOn: $shiny) {
            Text("Shiny")
              .font(CETheme.sans(15, weight: .medium))
          }
          .tint(CETheme.crystal)
          .padding(12)
          .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }

        if canEditGender {
          VStack(alignment: .leading, spacing: 8) {
            Text("Gender")
              .font(CETheme.sans(11, weight: .semibold))
              .foregroundStyle(CETheme.muted)
            Picker("Gender", selection: $gender) {
              ForEach(genderOptions) { g in
                Text(g.label).tag(g)
              }
            }
            .pickerStyle(.segmented)
            .disabled(genderOptions.count <= 1)
          }
          .padding(12)
          .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .onChange(of: speciesId) { _ in
            let opts = genderOptions
            if !opts.contains(gender), let first = opts.first { gender = first }
          }
        }

        if canEditNature {
          naturePicker(selection: $nature, species: speciesId, tables: tables)
        }

        if canEditSpeciesLevel {
          SaveEditorCatalogPicker(
            title: "Species",
            selection: $speciesId,
            entries: SaveEditorCatalog.species(tables: tables),
            showSprites: true,
            tables: tables
          )
          HStack {
            Text("Level")
              .font(CETheme.sans(14, weight: .medium))
              .foregroundStyle(CETheme.text)
            Spacer()
            Stepper(value: $level, in: 1...100) {
              Text("\(level)")
                .font(CETheme.sans(15, weight: .semibold))
                .foregroundStyle(CETheme.crystal)
                .frame(minWidth: 36, alignment: .trailing)
            }
          }
          .padding(12)
          .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
          HStack(spacing: 10) {
            SpeciesIconView(nationalDex: nationalDex, size: 28)
            VStack(alignment: .leading, spacing: 2) {
              Text("Species")
                .font(CETheme.sans(11, weight: .semibold))
                .foregroundStyle(CETheme.muted)
              Text(Gen3Names.species(speciesId, tables: tables))
                .font(CETheme.sans(15, weight: .medium))
            }
            Spacer()
            Text("Lv \(level)")
              .font(CETheme.sans(13, weight: .semibold))
              .foregroundStyle(CETheme.muted)
          }
          .padding(12)
          .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
      }
    }
  }

  private var heldItemCard: some View {
    editorCard("Held Item") {
      SaveEditorCatalogPicker(
        title: "Item",
        selection: $heldItem,
        entries: SaveEditorCatalog.items(tables: tables),
        allowNone: true,
        showItemIcons: true,
        tables: tables
      )
    }
  }

  private var learnableMoves: Set<Int> {
    Gen3Learnsets.learnableMoveIds(species: speciesId, tables: tables)
  }

  private var movesCard: some View {
    editorCard("Moves") {
      VStack(spacing: 10) {
        ForEach(0..<4, id: \.self) { i in
          SaveEditorCatalogPicker(
            title: "Move \(i + 1)",
            selection: Binding(
              get: { moveIds[i] },
              set: { moveIds[i] = $0 }
            ),
            entries: SaveEditorCatalog.moves(tables: tables),
            allowNone: true,
            tables: tables,
            compatibleIds: learnableMoves,
            compatibleSectionTitle: "Can learn",
            otherSectionTitle: "Not on learnset"
          )
        }
      }
    }
  }

  private var smartEVCard: some View {
    editorCard("Effort Values") {
      VStack(alignment: .leading, spacing: 14) {
        HStack(alignment: .firstTextBaseline) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Smart profiles")
              .font(CETheme.sans(13, weight: .semibold))
              .foregroundStyle(CETheme.text)
            Text("Built for \(Gen3Natures.name(nature)) · \(Gen3Names.species(speciesId, tables: tables))")
              .font(CETheme.sans(11))
              .foregroundStyle(CETheme.muted)
              .lineLimit(2)
          }
          Spacer()
          Text("\(evTotal)/510")
            .font(CETheme.mono(12))
            .foregroundStyle(evTotal > 510 ? Color.red.opacity(0.9) : CETheme.accent)
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(smartProfiles) { profile in
              Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                  evs = profile.evs
                }
              } label: {
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 4) {
                    Text(profile.title)
                      .font(CETheme.sans(12, weight: .bold))
                      .foregroundStyle(CETheme.text)
                    if profile.natureAligned {
                      Text("NATURE")
                        .font(CETheme.sans(8, weight: .bold))
                        .foregroundStyle(CETheme.crystal)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(CETheme.crystal.opacity(0.18), in: Capsule())
                    }
                  }
                  Text(profile.subtitle)
                    .font(CETheme.sans(10))
                    .foregroundStyle(CETheme.muted)
                    .lineLimit(2)
                    .frame(maxWidth: 150, alignment: .leading)
                }
                .padding(10)
                .frame(width: 168, alignment: .leading)
                .background(
                  matchedSmartProfileId == profile.id
                    ? CETheme.crystal.opacity(0.16)
                    : CETheme.elevated,
                  in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                      matchedSmartProfileId == profile.id
                        ? CETheme.crystal.opacity(0.7)
                        : CETheme.border,
                      lineWidth: 1
                    )
                )
              }
              .buttonStyle(.plain)
            }
          }
        }

        Divider().overlay(CETheme.border)

        Text("Custom EVs")
          .font(CETheme.sans(12, weight: .semibold))
          .foregroundStyle(CETheme.muted)

        ForEach(0..<6, id: \.self) { i in
          evStatRow(index: i)
        }

        if let up = Gen3Natures.raises(nature), let down = Gen3Natures.lowers(nature) {
          Text("+\(SaveEditorCatalog.statLabels[up])  ·  −\(SaveEditorCatalog.statLabels[down])")
            .font(CETheme.sans(11, weight: .semibold))
            .foregroundStyle(CETheme.crystal.opacity(0.9))
        } else {
          Text("Neutral nature — no stat boost")
            .font(CETheme.sans(11))
            .foregroundStyle(CETheme.muted)
        }
      }
    }
  }

  private func evStatRow(index i: Int) -> some View {
    let up = Gen3Natures.raises(nature)
    let down = Gen3Natures.lowers(nature)
    let tint: Color = {
      if up == i { return Color(red: 0.35, green: 0.85, blue: 0.45) }
      if down == i { return Color(red: 1.0, green: 0.4, blue: 0.38) }
      return CETheme.crystal
    }()
    return HStack {
      Text(SaveEditorCatalog.statLabels[i])
        .font(CETheme.sans(14, weight: .semibold))
        .foregroundStyle(up == i || down == i ? tint : CETheme.text)
        .frame(width: 40, alignment: .leading)
      Slider(
        value: Binding(
          get: { Double(evs[i]) },
          set: { evs[i] = min(255, max(0, Int($0.rounded()))) }
        ),
        in: 0...255,
        step: 1
      )
      .tint(tint)
      Text("\(evs[i])")
        .font(CETheme.sans(13, weight: .semibold))
        .foregroundStyle(CETheme.muted)
        .frame(width: 32, alignment: .trailing)
    }
  }

  private func statsCard(title: String, values: Binding<[Int]>, range: ClosedRange<Int>, footer: String) -> some View {
    editorCard(title) {
      VStack(spacing: 10) {
        ForEach(0..<6, id: \.self) { i in
          HStack {
            Text(SaveEditorCatalog.statLabels[i])
              .font(CETheme.sans(14, weight: .semibold))
              .foregroundStyle(CETheme.text)
              .frame(width: 40, alignment: .leading)
            Slider(
              value: Binding(
                get: { Double(values.wrappedValue[i]) },
                set: { values.wrappedValue[i] = Int($0.rounded()) }
              ),
              in: Double(range.lowerBound)...Double(range.upperBound),
              step: 1
            )
            .tint(CETheme.crystal)
            Text("\(values.wrappedValue[i])")
              .font(CETheme.sans(13, weight: .semibold))
              .foregroundStyle(CETheme.muted)
              .frame(width: 32, alignment: .trailing)
          }
        }
        Text(footer)
          .font(CETheme.sans(11))
          .foregroundStyle(CETheme.muted)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func editorCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(CETheme.sans(12, weight: .semibold))
        .foregroundStyle(CETheme.muted)
        .textCase(.uppercase)
        .tracking(0.5)
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))
  }

  private func apply() {
    guard let slot = slotIndex, mon.id.hasPrefix("party-") else {
      errorText = "Only party slots are editable here."
      return
    }
    let nick = nicknameText.trimmingCharacters(in: .whitespacesAndNewlines)
    let moves = moveIds.filter { $0 > 0 }
    // Gen 3 requires unique non-empty moves when writing.
    if session.generation == .gen3, Set(moves).count != moves.count {
      errorText = "Each move must be different."
      return
    }
    do {
      try session.editParty(
        slot: slot,
        species: canEditSpeciesLevel ? speciesId : nil,
        level: canEditSpeciesLevel ? level : nil,
        moves: moves.isEmpty ? nil : moves,
        heldItem: session.generation == .gen1 ? nil : heldItem,
        nickname: nick.isEmpty ? nil : nick,
        evs: canEditEVsIVs ? evs : nil,
        ivs: canEditEVsIVs ? ivs : nil,
        shiny: canEditShiny ? shiny : nil,
        gender: canEditGender ? gender : nil,
        nature: canEditNature ? nature : nil
      )
      onClose()
    } catch {
      errorText = (error as? CustomStringConvertible)?.description ?? "\(error)"
    }
  }
}

/// Nature picker shared by Edit / Add — font color from the species' base stats (green / gray / red).
private struct NaturePickerControl: View {
  @Binding var selection: Int
  let species: Int
  let tables: Gen3Tables
  @State private var showList = false

  private var ranked: [Int] {
    species > 0
      ? Gen3NatureAdvice.rankedNatures(species: species, tables: tables)
      : Array(0..<25)
  }

  private var selectedGrade: Gen3NatureGrade {
    species > 0
      ? Gen3NatureAdvice.grade(nature: selection, species: species, tables: tables)
      : .neutral
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Nature")
        .font(CETheme.sans(11, weight: .semibold))
        .foregroundStyle(CETheme.muted)

      Button { showList = true } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(Gen3Natures.name(selection))
              .font(CETheme.sans(15, weight: .medium))
              .foregroundStyle(natureGradeColor(selectedGrade))
            Text(natureEffectHint(selection))
              .font(CETheme.sans(11))
              .foregroundStyle(CETheme.muted)
          }
          Spacer()
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(CETheme.muted)
        }
        .padding(12)
        .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CETheme.border, lineWidth: 1))
      }
      .buttonStyle(.plain)
    }
    .padding(12)
    .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .sheet(isPresented: $showList) {
      NavigationStack {
        List {
          ForEach(ranked, id: \.self) { n in
            let grade: Gen3NatureGrade = species > 0
              ? Gen3NatureAdvice.grade(nature: n, species: species, tables: tables)
              : .neutral
            Button {
              selection = n
              showList = false
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(Gen3Natures.name(n))
                    .font(CETheme.sans(16, weight: .semibold))
                    .foregroundStyle(natureGradeColor(grade))
                  Text(natureEffectHint(n))
                    .font(CETheme.sans(12))
                    .foregroundStyle(CETheme.muted)
                }
                Spacer()
                if n == selection {
                  Image(systemName: "checkmark")
                    .foregroundStyle(natureGradeColor(grade))
                }
              }
            }
          }
        }
        .scrollContentBackground(.hidden)
        .background(CETheme.bg)
        .navigationTitle("Nature")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { showList = false }
          }
        }
      }
      .preferredColorScheme(.dark)
      .presentationDetents([.medium, .large])
    }
  }
}

private func naturePicker(selection: Binding<Int>, species: Int, tables: Gen3Tables) -> some View {
  NaturePickerControl(selection: selection, species: species, tables: tables)
}

private func natureGradeColor(_ grade: Gen3NatureGrade) -> Color {
  switch grade {
  case .best: return Color(red: 0.35, green: 0.78, blue: 0.45)
  case .neutral: return CETheme.muted
  case .poor: return Color(red: 0.92, green: 0.38, blue: 0.38)
  }
}

private func natureEffectHint(_ n: Int) -> String {
  let names = Gen3Stat.names
  guard let up = Gen3Natures.raises(n), let down = Gen3Natures.lowers(n),
        names.indices.contains(up), names.indices.contains(down) else {
    return "Neutral"
  }
  return "+\(names[up]) / −\(names[down])"
}

// MARK: - Add Pokémon to party (Gen 3)

struct SaveAddMonSheet: View {
  @ObservedObject var session: SaveSession
  let onClose: () -> Void

  @State private var speciesId: Int = 0
  @State private var level: Int = 5
  @State private var heldItem: Int = 0
  @State private var moveIds: [Int] = [33, 0, 0, 0] // Tackle
  @State private var nicknameText = ""
  @State private var evs: [Int] = Array(repeating: 0, count: 6)
  @State private var ivs: [Int] = Array(repeating: 20, count: 6)
  @State private var shiny = false
  @State private var gender: Gen3MonGender = .male
  @State private var nature: Int = 0
  @State private var errorText: String?

  private var tables: Gen3Tables { session.nameTables }
  private var genderOptions: [Gen3MonGender] {
    speciesId > 0 ? Gen3Gender.options(species: speciesId, tables: tables) : [.male, .female]
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          SaveEditorCatalogPicker(
            title: "Species",
            selection: $speciesId,
            entries: SaveEditorCatalog.species(tables: tables),
            showSprites: true,
            tables: tables
          )

          VStack(alignment: .leading, spacing: 8) {
            Text("Nickname")
              .font(CETheme.sans(11, weight: .semibold))
              .foregroundStyle(CETheme.muted)
            TextField("Optional", text: $nicknameText)
              .textInputAutocapitalization(.characters)
              .padding(12)
              .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10))
          }
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16))

          HStack {
            Text("Level")
              .font(CETheme.sans(14, weight: .medium))
            Spacer()
            Stepper(value: $level, in: 1...100) {
              Text("\(level)")
                .font(CETheme.sans(15, weight: .semibold))
                .foregroundStyle(CETheme.crystal)
            }
          }
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16))

          Toggle("Shiny", isOn: $shiny)
            .tint(CETheme.crystal)
            .padding(14)
            .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16))

          VStack(alignment: .leading, spacing: 8) {
            Text("Gender")
              .font(CETheme.sans(11, weight: .semibold))
              .foregroundStyle(CETheme.muted)
            Picker("Gender", selection: $gender) {
              ForEach(genderOptions) { g in
                Text(g.label).tag(g)
              }
            }
            .pickerStyle(.segmented)
            .disabled(genderOptions.count <= 1)
          }
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16))
          .onChange(of: speciesId) { _ in
            let opts = genderOptions
            if !opts.contains(gender), let first = opts.first { gender = first }
          }

          naturePicker(selection: $nature, species: speciesId, tables: tables)
            .padding(.horizontal, 2)

          SaveEditorCatalogPicker(
            title: "Held Item",
            selection: $heldItem,
            entries: SaveEditorCatalog.items(tables: tables),
            allowNone: true,
            showItemIcons: true,
            tables: tables
          )

          VStack(spacing: 10) {
            ForEach(0..<4, id: \.self) { i in
              SaveEditorCatalogPicker(
                title: "Move \(i + 1)",
                selection: Binding(
                  get: { moveIds[i] },
                  set: { moveIds[i] = $0 }
                ),
                entries: SaveEditorCatalog.moves(tables: tables),
                allowNone: i > 0,
                tables: tables,
                compatibleIds: Gen3Learnsets.learnableMoveIds(species: speciesId, tables: tables),
                compatibleSectionTitle: "Can learn",
                otherSectionTitle: "Not on learnset"
              )
            }
          }
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16))

          statsBlock(title: "EVs", values: $evs, range: 0...255)
          statsBlock(title: "IVs", values: $ivs, range: 0...31)

          if let errorText {
            Text(errorText).font(CETheme.sans(13)).foregroundStyle(.red)
          }
        }
        .padding(16)
      }
      .background(CETheme.bg)
      .navigationTitle("Add Pokémon")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") { add() }.fontWeight(.semibold)
        }
      }
    }
    .preferredColorScheme(.dark)
    .onAppear {
      if speciesId == 0, let first = SaveEditorCatalog.species(tables: tables).first {
        speciesId = first.id
      }
    }
  }

  private func statsBlock(title: String, values: Binding<[Int]>, range: ClosedRange<Int>) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(CETheme.sans(12, weight: .semibold))
        .foregroundStyle(CETheme.muted)
      ForEach(0..<6, id: \.self) { i in
        HStack {
          Text(SaveEditorCatalog.statLabels[i])
            .font(CETheme.sans(14, weight: .semibold))
            .frame(width: 40, alignment: .leading)
          Slider(
            value: Binding(
              get: { Double(values.wrappedValue[i]) },
              set: { values.wrappedValue[i] = Int($0.rounded()) }
            ),
            in: Double(range.lowerBound)...Double(range.upperBound),
            step: 1
          )
          .tint(CETheme.crystal)
          Text("\(values.wrappedValue[i])")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(CETheme.muted)
            .frame(width: 32, alignment: .trailing)
        }
      }
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16))
  }

  private func add() {
    guard speciesId > 0 else {
      errorText = "Pick a Pokémon."
      return
    }
    let moves = moveIds.filter { $0 > 0 }
    guard !moves.isEmpty else {
      errorText = "Pick at least one move."
      return
    }
    if Set(moves).count != moves.count {
      errorText = "Each move must be different."
      return
    }
    let nick = nicknameText.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      try session.addPartyMon(
        species: speciesId,
        level: level,
        moves: moves,
        heldItem: heldItem,
        nickname: nick.isEmpty ? Gen3Names.species(speciesId, tables: tables) : nick,
        evs: evs,
        ivs: ivs,
        shiny: shiny,
        gender: gender,
        nature: nature
      )
      onClose()
    } catch {
      errorText = (error as? CustomStringConvertible)?.description ?? "\(error)"
    }
  }
}

// MARK: - Add bag item

private struct SaveAddItemSheet: View {
  @ObservedObject var session: SaveSession
  let onClose: () -> Void

  @State private var pocket: BagPocket = .items
  @State private var itemId: Int = 0
  @State private var quantity: Int = 1
  @State private var errorText: String?

  private var tables: Gen3Tables { session.nameTables }

  private var stackCap: Int {
    session.gen3Editor?.file.format.stackMax(pocket: pocket, item: max(1, itemId)) ?? 99
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 16) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Pocket")
              .font(CETheme.sans(12, weight: .semibold))
              .foregroundStyle(CETheme.muted)
              .textCase(.uppercase)
              .tracking(0.5)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
              ForEach(BagPocket.editableCases) { p in
                Button {
                  pocket = p
                } label: {
                  HStack(spacing: 8) {
                    Image(systemName: p.symbol)
                      .font(.system(size: 13, weight: .semibold))
                    Text(p.title)
                      .font(CETheme.sans(13, weight: .semibold))
                      .lineLimit(1)
                    Spacer(minLength: 0)
                  }
                  .foregroundStyle(CETheme.text)
                  .padding(12)
                  .background(
                    pocket == p ? CETheme.crystal.opacity(0.18) : CETheme.elevated,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                  )
                  .overlay(
                    RoundedRectangle(cornerRadius: 12)
                      .stroke(pocket == p ? CETheme.crystal.opacity(0.65) : CETheme.border, lineWidth: 1)
                  )
                }
                .buttonStyle(.plain)
              }
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))

          VStack(alignment: .leading, spacing: 12) {
            Text("Item")
              .font(CETheme.sans(12, weight: .semibold))
              .foregroundStyle(CETheme.muted)
              .textCase(.uppercase)
              .tracking(0.5)
            SaveEditorCatalogPicker(
              title: "Choose item",
              selection: $itemId,
              entries: SaveEditorCatalog.items(tables: tables),
              allowNone: false,
              showItemIcons: true,
              tables: tables
            )
            if itemId > 0 {
              HStack(spacing: 12) {
                ItemIconView(itemId: itemId, tables: tables, size: 40)
                  .padding(6)
                  .background(CETheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                  Text(Gen3Names.item(itemId, tables: tables))
                    .font(CETheme.sans(16, weight: .semibold))
                  Text(pocket.title)
                    .font(CETheme.sans(12))
                    .foregroundStyle(CETheme.muted)
                }
                Spacer()
              }
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))

          VStack(alignment: .leading, spacing: 12) {
            Text("Quantity")
              .font(CETheme.sans(12, weight: .semibold))
              .foregroundStyle(CETheme.muted)
              .textCase(.uppercase)
              .tracking(0.5)
            Stepper(value: $quantity, in: 1...max(1, stackCap)) {
              Text("×\(quantity)")
                .font(CETheme.sans(18, weight: .bold))
                .foregroundStyle(CETheme.crystal)
            }
            HStack(spacing: 8) {
              ForEach([1, 5, 10, 99].filter { $0 <= stackCap }, id: \.self) { q in
                Button("\(q)") {
                  quantity = q
                }
                .font(CETheme.sans(13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(CETheme.elevated, in: Capsule())
                .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
                .foregroundStyle(CETheme.text)
              }
              if stackCap > 99 {
                Button("Max") { quantity = stackCap }
                  .font(CETheme.sans(13, weight: .semibold))
                  .padding(.horizontal, 12)
                  .padding(.vertical, 8)
                  .background(CETheme.elevated, in: Capsule())
                  .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
                  .foregroundStyle(CETheme.text)
              }
            }
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))

          if let errorText {
            Text(errorText)
              .font(CETheme.sans(13))
              .foregroundStyle(Color.red.opacity(0.9))
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(16)
      }
      .background(CETheme.bg)
      .navigationTitle("Add Item")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onClose)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") { add() }
            .fontWeight(.semibold)
            .disabled(itemId <= 0 || session.readOnly)
        }
      }
      .onChange(of: pocket) { _ in
        quantity = min(quantity, stackCap)
      }
      .onChange(of: itemId) { _ in
        quantity = min(max(1, quantity), stackCap)
      }
    }
    .preferredColorScheme(.dark)
  }

  private func add() {
    guard itemId > 0 else {
      errorText = "Pick an item."
      return
    }
    do {
      try session.addBagItem(pocket: pocket, item: itemId, quantity: quantity)
      onClose()
    } catch {
      errorText = (error as? CustomStringConvertible)?.description ?? "\(error)"
    }
  }
}

