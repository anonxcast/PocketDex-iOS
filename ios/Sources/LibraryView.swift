import SwiftUI

struct LibraryView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject private var artworkStore = RomArtworkStore.shared
  @ObservedObject private var libraryFonts = LibraryFontStore.shared
  @ObservedObject private var recentlyPlayed = RecentlyPlayedStore.shared
  let onPlay: (RomItem) -> Void
  var onOpenGame: ((RomItem) -> Void)? = nil
  var onOpenSettings: (() -> Void)? = nil

  @State private var roms: [RomItem] = []
  @State private var skins: [DeltaSkinItem] = []
  /// Per-console selected skin directory path (drives checkmark UI).
  @State private var selectedSkinPaths: [ConsoleKind: String] = [:]
  @State private var skinsGloballyEnabled = true
  @State private var showImporter = false
  @State private var importError: String?
  @State private var isImporting = false
  @State private var importStatus = "Copying…"
  @State private var destination: LibraryDestination = .console(.gba)
  @State private var artworkTarget: ArtworkTarget?
  @State private var romPendingDelete: RomItem?
  @State private var playConfirm: PlayConfirmRequest?
  @State private var didBackfillArt = false
  /// Splash wordmark for ~3s on launch, then crossfades to the active console/section.
  @State private var showBrandIntro = true
  /// Duo closed / outer front display — compact chrome + cover grid (Apple Duo UX).
  @State private var hingeClosed = false
  @AppStorage("library.selectedConsole") private var storedConsoleRaw: String = ConsoleKind.gba.rawValue

  var body: some View {
    // System TabView — on iPhone Duo this becomes the vertical bar *under* the status
    // island (Music / Notes pattern). Custom trailing safeAreaBar sat left of that
    // column and left a dead gap; don’t fight the system chrome.
    TabView(selection: tabSelection) {
      ForEach(ConsoleKind.allCases) { kind in
        libraryPage(showsChrome: true) {
          gamesBody(for: kind)
        }
        .tabItem {
          // UIImage template — SwiftUI `tabItem` drops custom Shape views (icons went blank).
          Label {
            Text(kind.shortTitle)
          } icon: {
            Image(uiImage: ConsoleTabIcon.image(for: kind))
          }
        }
        .tag(LibraryDestination.console(kind))
      }

      libraryPage(showsChrome: true) {
        skinsBody
      }
      .tabItem { Label("Skins", systemImage: "paintbrush.fill") }
      .tag(LibraryDestination.skins)

      libraryPage(showsChrome: true) {
        SaveEditorListView(
          roms: roms,
          engineLoadedStem: engine.loadedRomURL?.deletingPathExtension().lastPathComponent
        )
      }
      .tabItem { Label("Editor", systemImage: "square.and.pencil") }
      .tag(LibraryDestination.saveEditor)

      libraryPage(showsChrome: false) {
        SettingsView(showsBackButton: false)
      }
      .tabItem { Label("Settings", systemImage: "gearshape.fill") }
      .tag(LibraryDestination.settings)
    }
    .tint(CETheme.crystal)
    // Keep the Liquid Glass tab chrome compact — scroll morph was ballooning the pill.
    .modifier(CompactTabBarChrome())
    .modifier(DuoHingeClosedObserver { closed in
      hingeClosed = closed
    })
    .toolbar {
      if destination != .settings {
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            showImporter = true
          } label: {
            // Symbol-first — Duo’s vertical side bar is narrow (Apple Duo bar guidance).
            Label("Import", systemImage: "square.and.arrow.down")
              .labelStyle(.iconOnly)
          }
          .accessibilityLabel("Import")
        }
      }
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .background(GlassChrome.canvas.ignoresSafeArea())
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: RomLibrary.contentTypes + DeltaSkinManager.contentTypes,
      allowsMultipleSelection: true
    ) { result in
      handleImport(result)
    }
    .alert("Import failed", isPresented: Binding(
      get: { importError != nil },
      set: { if !$0 { importError = nil } }
    )) {
      Button("OK", role: .cancel) { importError = nil }
    } message: {
      Text(importError ?? "")
    }
    .confirmationDialog(
      "Delete \(romPendingDelete?.displayName ?? "game")?",
      isPresented: Binding(
        get: { romPendingDelete != nil },
        set: { if !$0 { romPendingDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete Game", role: .destructive) {
        if let rom = romPendingDelete {
          deleteGame(rom)
        }
        romPendingDelete = nil
      }
      Button("Cancel", role: .cancel) { romPendingDelete = nil }
    } message: {
      Text("Removes the ROM, battery save, save states, and artwork from this device. Matching Google Drive copies (including scraped covers) are purged on the next sync.")
    }
    .overlay {
      if isImporting {
        ProgressView(importStatus)
          .tint(CETheme.accent)
          .padding(20)
          .pocketGlassCard(cornerRadius: CETheme.radius)
      }
    }
    .overlay {
      if let req = playConfirm {
        PlayConfirmBubble(
          rom: req.rom,
          globalAnchor: req.point,
          onPlay: {
            let rom = req.rom
            playConfirm = nil
            onPlay(rom)
          },
          onDismiss: { playConfirm = nil }
        )
      }
    }
    .onAppear {
      restoreDestination()
      refresh()
      backfillArtworkIfNeeded()
      scheduleBrandIntro()
    }
    .onReceive(NotificationCenter.default.publisher(for: .pocketDexLibraryNeedsReload)) { _ in
      refresh()
      backfillArtworkIfNeeded()
    }
    .sheet(item: $artworkTarget) { target in
      ArtworkPickerSheet(rom: target.rom, initialKind: target.kind)
    }
  }

  private var tabSelection: Binding<LibraryDestination> {
    Binding(
      get: { destination },
      set: { newValue in
        if newValue != destination {
          InputHaptics.selectionChange()
        }
        if case .console(let kind) = newValue {
          storedConsoleRaw = kind.rawValue
        }
        destination = newValue
      }
    )
  }

  @ViewBuilder
  private func libraryPage<Content: View>(
    showsChrome: Bool,
    @ViewBuilder content: () -> Content
  ) -> some View {
    // Avoid GeometryReader wrapping the page — it fights TabView scroll-edge sizing.
    // Compact brand/chrome when Duo is closed (outer display) so content fits the shorter face.
    VStack(spacing: 0) {
      if showsChrome {
        topBar(compact: hingeClosed)
      }
      content()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func topBar(compact: Bool) -> some View {
    HStack(spacing: 12) {
      pocketDexBrand(compact: compact)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.top, compact ? 10 : 14)
    .padding(.bottom, compact ? 10 : 12)
  }

  /// Brand for 3s, then console/section title with icon on the left.
  private func pocketDexBrand(compact: Bool) -> some View {
    ZStack {
      if showBrandIntro {
        brandWordmark(compact: compact)
          .transition(.asymmetric(
            insertion: .opacity,
            removal: .opacity.combined(with: .scale(scale: 0.96))
          ))
      } else {
        destinationHeader(compact: compact)
          .transition(.asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.96)),
            removal: .opacity
          ))
      }
    }
    .animation(.easeInOut(duration: 0.55), value: showBrandIntro)
    .animation(.easeInOut(duration: 0.25), value: destination.title)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(showBrandIntro ? "PocketDex" : destination.title)
  }

  private func brandWordmark(compact: Bool) -> some View {
    HStack(spacing: compact ? 7 : 9) {
      PokeBallMark(size: compact ? 18 : 22)
      HStack(spacing: 0) {
        Text("Pocket")
          .font(CETheme.sans(compact ? 17 : 20, weight: .medium))
          .tracking(0.6)
        Text("Dex")
          .font(CETheme.sans(compact ? 17 : 20, weight: .bold))
          .tracking(1.2)
      }
      .foregroundStyle(CETheme.text)
    }
  }

  private func destinationHeader(compact: Bool) -> some View {
    HStack(spacing: compact ? 8 : 10) {
      destinationHeaderIcon(size: compact ? 22 : 26)
        .foregroundStyle(Color.white)
        .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)

      Text(destinationHeaderTitle)
        .font(CETheme.sans(compact ? 16 : 19, weight: .semibold))
        .tracking(0.4)
        .foregroundStyle(CETheme.text)
        .lineLimit(1)
    }
  }

  private var destinationHeaderTitle: String {
    switch destination {
    case .console(let kind): return kind.title
    case .skins: return "Skins"
    case .saveEditor: return "Save Editor"
    case .settings: return "Settings"
    }
  }

  @ViewBuilder
  private func destinationHeaderIcon(size: CGFloat) -> some View {
    switch destination {
    case .console(let kind):
      ConsoleRailIcon(kind: kind)
        .frame(width: size, height: size)
    case .skins:
      Image(systemName: "paintbrush.fill")
        .font(.system(size: size * 0.72, weight: .semibold))
    case .saveEditor:
      Image(systemName: "square.and.pencil")
        .font(.system(size: size * 0.72, weight: .semibold))
        .foregroundStyle(CETheme.crystal)
    case .settings:
      Image(systemName: "gearshape.fill")
        .font(.system(size: size * 0.72, weight: .semibold))
    }
  }

  private func scheduleBrandIntro() {
    guard showBrandIntro else { return }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      withAnimation(.easeInOut(duration: 0.55)) {
        showBrandIntro = false
      }
    }
  }

  private func restoreDestination() {
    if let kind = ConsoleKind(rawValue: storedConsoleRaw) {
      destination = .console(kind)
    }
  }

  private func gamesBody(for kind: ConsoleKind) -> some View {
    let list = roms.filter { $0.console == kind }
    let recent = recentlyPlayed.recent(in: list)
    return Group {
      if roms.isEmpty {
        emptyGames
      } else if list.isEmpty {
        emptyConsole
      } else {
        GeometryReader { geo in
          // Duo outer is wider/shorter, but content sits left of the vertical system bar —
          // keep a cover grid there (Apple: compact-width outer). Banner rows only when
          // truly landscape on an open / large canvas.
          let outerFace = hingeClosed || geo.size.height < 520
          let useBanners = !outerFace
            && geo.size.width > geo.size.height * 1.08
            && geo.size.height >= 520
          let colCount = max(2, min(4, Int(geo.size.width / (outerFace ? 140 : 160))))
          let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: colCount)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: outerFace ? 14 : 18) {
              if !recent.isEmpty {
                librarySectionHeader("Recently Played")
                if useBanners {
                  LazyVStack(spacing: 12) {
                    ForEach(recent) { rom in
                      gameBannerCard(rom)
                    }
                  }
                } else {
                  LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(recent) { rom in
                      gameCoverTile(rom)
                    }
                  }
                }
              }

              if !recent.isEmpty {
                librarySectionHeader("All Games")
              }
              if useBanners {
                LazyVStack(spacing: 12) {
                  ForEach(list) { rom in
                    gameBannerCard(rom)
                  }
                }
              } else {
                LazyVGrid(columns: columns, spacing: 14) {
                  ForEach(list) { rom in
                    gameCoverTile(rom)
                  }
                }
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, outerFace ? 8 : 12)
            .id("\(artworkStore.revision)-\(kind.rawValue)-\(recentlyPlayed.datesByKey.count)-\(hingeClosed)")
          }
        }
      }
    }
  }

  private func librarySectionHeader(_ title: String) -> some View {
    Text(title)
      .font(CETheme.sans(13, weight: .semibold))
      .foregroundStyle(CETheme.muted)
      .textCase(.uppercase)
      .tracking(0.6)
  }

  private var emptyGames: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "tray.and.arrow.down.fill")
        .font(.system(size: 40))
        .foregroundStyle(CETheme.crystal)
      Text("No ROMs yet")
        .font(CETheme.sans(20, weight: .bold))
        .foregroundStyle(CETheme.text)
      Text("Import one or many ROMs — covers apply automatically when found (Libretro). Long-press a game to change art.")
        .font(CETheme.sans(14))
        .foregroundStyle(CETheme.muted)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
      Button { showImporter = true } label: {
        Text("Import ROMs / Skins")
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(.black)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .background(CETheme.accent, in: Capsule())
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private var emptyConsole: some View {
    let title: String = {
      if case .console(let kind) = destination { return kind.title }
      return "This console"
    }()
    return VStack(spacing: 16) {
      Spacer()
      Image(systemName: "gamecontroller")
        .font(.system(size: 36, weight: .semibold))
        .foregroundStyle(CETheme.muted)
      Text("No \(title) games")
        .font(CETheme.sans(18, weight: .bold))
        .foregroundStyle(CETheme.text)
      Text("Import a \(title) ROM, or pick another console in the tab bar.")
        .font(CETheme.sans(14))
        .foregroundStyle(CETheme.muted)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
      Button { showImporter = true } label: {
        Text("Import ROMs")
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(.black)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .background(CETheme.accent, in: Capsule())
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  private func hintCard(title: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(CETheme.sans(14, weight: .semibold))
        .foregroundStyle(CETheme.crystal)
      Text(body)
        .font(CETheme.sans(13))
        .foregroundStyle(CETheme.muted)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
  }

  private func refresh() {
    roms = RomLibrary.listRoms()
    skins = DeltaSkinManager.listSkins()
    reloadSkinSelectionState()
  }

  /// Quietly fill missing covers for games already in the library (Libretro, no account).
  private func backfillArtworkIfNeeded() {
    guard !didBackfillArt else { return }
    didBackfillArt = true
    let missing = roms.filter { rom in
      guard rom.console != nil else { return false }
      let key = rom.artworkKey
      return !artworkStore.hasArtwork(forKey: key, kind: .cover)
        || !artworkStore.hasArtwork(forKey: key, kind: .logo)
    }
    guard !missing.isEmpty else { return }
    Task(priority: .utility) {
      for rom in missing {
        await LibretroArtworkApplier.applyIfNeeded(to: rom)
      }
    }
  }

  private func handleImport(_ result: Result<[URL], Error>) {
    switch result {
    case .failure(let error):
      importError = error.localizedDescription
    case .success(let urls):
      guard !urls.isEmpty else { return }
      isImporting = true
      importStatus = urls.count == 1 ? "Importing…" : "Importing 0 of \(urls.count)…"
      Task(priority: .userInitiated) {
        var failures: [String] = []
        var imported: [RomItem] = []
        for (i, url) in urls.enumerated() {
          await MainActor.run {
            importStatus = urls.count == 1
              ? "Importing…"
              : "Importing \(i + 1) of \(urls.count)…"
          }
          do {
            let dest = try RomLibrary.importFile(from: url)
            let ext = dest.pathExtension.lowercased()
            if ["gba", "gbc", "gb", "nds"].contains(ext) {
              let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
              imported.append(RomItem(
                id: dest,
                name: dest.deletingPathExtension().lastPathComponent,
                url: dest,
                byteCount: Int64(size)
              ))
            }
          } catch {
            failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
          }
        }

        await MainActor.run { refresh() }

        if !imported.isEmpty {
          await MainActor.run { importStatus = "Fetching covers…" }
          for rom in imported {
            await LibretroArtworkApplier.applyIfNeeded(to: rom)
          }
          await MainActor.run { refresh() }
        }

        await MainActor.run {
          isImporting = false
          if let first = imported.first, let kind = first.console {
            selectDestination(.console(kind))
          }
          if !failures.isEmpty { importError = failures.joined(separator: "\n") }
        }

        if AppSettings.shared.googleDriveAutoSync, GoogleDriveAuth.shared.isSignedIn {
          await GoogleDriveSync.shared.syncNow()
          await MainActor.run { refresh() }
        }
      }
    }
  }

  private func byteString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
  }

  private var skinsBody: some View {
    ScrollView {
      LazyVStack(spacing: 10) {
        hintCard(
          title: "Delta skins (.deltaskin)",
          body: "Import Delta / Manic-compatible skins for GB, GBC, GBA, and DS. Tap a skin to activate it (checkmark). Tap it again to turn it off."
        )

        Toggle(isOn: Binding(
          get: { skinsGloballyEnabled },
          set: { enabled in
            skinsGloballyEnabled = enabled
            settings.skinsEnabled = enabled
            reloadSkinSelectionState()
          }
        )) {
          VStack(alignment: .leading, spacing: 4) {
            Text("Enable skins")
              .font(CETheme.sans(15, weight: .semibold))
              .foregroundStyle(CETheme.text)
            Text(skinsGloballyEnabled ? "Active when a skin is checked" : "Using translucent default pad")
              .font(CETheme.sans(12))
              .foregroundStyle(CETheme.muted)
          }
        }
        .tint(CETheme.accent)
        .padding(14)
        .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
        .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))

        ForEach(ConsoleKind.allCases) { kind in
          VStack(alignment: .leading, spacing: 8) {
            Text(kind.title.uppercased())
              .font(CETheme.sans(11, weight: .bold))
              .tracking(0.8)
              .foregroundStyle(CETheme.muted)
            let items = skins.filter { $0.console == kind }
            if items.isEmpty {
              Text("No skins yet")
                .font(CETheme.sans(13))
                .foregroundStyle(CETheme.muted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
            } else {
              ForEach(items) { skin in
                let path = skin.extractedDirectory.path
                let selected = skinsGloballyEnabled && selectedSkinPaths[kind] == path
                HStack(spacing: 10) {
                  Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                      toggleSkin(skin, for: kind)
                    }
                  } label: {
                    HStack(spacing: 12) {
                      Text(skin.name)
                        .font(CETheme.sans(15, weight: .medium))
                        .foregroundStyle(CETheme.text)
                        .multilineTextAlignment(.leading)
                      Spacer(minLength: 8)
                      SkinCheckmark(isOn: selected)
                    }
                    .padding(14)
                    .background(selected ? CETheme.hover : CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
                    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(selected ? CETheme.accent : CETheme.border, lineWidth: 1))
                  }
                  .buttonStyle(.plain)

                  Button(role: .destructive) {
                    try? DeltaSkinManager.delete(skin)
                    refresh()
                  } label: {
                    Image(systemName: "trash")
                      .foregroundStyle(Color.red.opacity(0.85))
                      .frame(width: 44, height: 44)
                      .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12))
                      .overlay(RoundedRectangle(cornerRadius: 12).stroke(CETheme.border, lineWidth: 1))
                  }
                  .accessibilityLabel("Delete skin")
                }
              }
            }
          }
        }
      }
      .padding(16)
    }
  }

  private func toggleSkin(_ skin: DeltaSkinItem, for kind: ConsoleKind) {
    let path = skin.extractedDirectory.path
    if selectedSkinPaths[kind] == path && skinsGloballyEnabled {
      selectedSkinPaths[kind] = nil
      DeltaSkinManager.clearSelection(for: kind)
      let anySelected = ConsoleKind.allCases.contains { DeltaSkinManager.selectedSkin(for: $0) != nil }
      if !anySelected {
        skinsGloballyEnabled = false
        settings.skinsEnabled = false
      }
    } else {
      selectedSkinPaths[kind] = path
      skinsGloballyEnabled = true
      settings.skinsEnabled = true
      DeltaSkinManager.select(skin)
    }
  }

  private func reloadSkinSelectionState() {
    skinsGloballyEnabled = DeltaSkinManager.isSkinEnabled
    settings.reloadSkinsFlag()
    var map: [ConsoleKind: String] = [:]
    for kind in ConsoleKind.allCases {
      if let skin = DeltaSkinManager.selectedSkin(for: kind) {
        map[kind] = skin.extractedDirectory.path
      }
    }
    selectedSkinPaths = map
  }

  private func selectDestination(_ dest: LibraryDestination) {
    if dest != destination {
      InputHaptics.selectionChange()
    }
    if case .console(let kind) = dest {
      storedConsoleRaw = kind.rawValue
    }
    destination = dest
  }

  private func gameCoverTile(_ rom: RomItem) -> some View {
    let paused = engine.isPausedRom(rom)
    let optimized = OptimizedRomCatalog.isOptimized(
      fileName: rom.url.lastPathComponent,
      displayName: rom.displayName
    )
    // Portrait cover grid: no logo/title overlay — box art already carries the branding.
    return VStack(alignment: .leading, spacing: 8) {
      ZStack(alignment: .topLeading) {
        coverImage(for: rom)
          .aspectRatio(2.0 / 3.0, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(paused ? CETheme.crystal : CETheme.border, lineWidth: paused ? 2 : 1)
          )
        VStack(alignment: .leading, spacing: 4) {
          if paused {
            Text("PAUSED")
              .font(CETheme.mono(8))
              .foregroundStyle(.black)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(CETheme.crystal.opacity(0.95), in: Capsule())
          }
          Spacer(minLength: 0)
          OptimizedStatusBadge(optimized: optimized, compact: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(coordinateSpace: .global) { point in
      handleGameTap(rom, at: point)
    }
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(rom.displayName)
    .accessibilityHint(settings.libraryOpenMode == .quickPlay ? "Shows Play confirmation" : "Opens game page")
    .contextMenu { artworkContextMenu(for: rom, landscapeDefault: false) }
  }

  private func gameBannerCard(_ rom: RomItem) -> some View {
    let paused = engine.isPausedRom(rom)
    let optimized = OptimizedRomCatalog.isOptimized(
      fileName: rom.url.lastPathComponent,
      displayName: rom.displayName
    )
    let hasLogo = artworkStore.hasArtwork(forKey: rom.artworkKey, kind: .logo)
    let cardHeight: CGFloat = hasLogo ? 176 : 132
    let coverH: CGFloat = hasLogo ? 148 : 110
    let coverW: CGFloat = hasLogo ? 99 : 78
    return ZStack {
      bannerImage(for: rom)
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .clipped()
      LinearGradient(
        colors: [.black.opacity(0.55), .black.opacity(0.25), .clear],
        startPoint: .leading,
        endPoint: .trailing
      )
      HStack(alignment: .center, spacing: 14) {
        coverImage(for: rom)
          .aspectRatio(2.0 / 3.0, contentMode: .fill)
          .frame(width: coverW, height: coverH)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(CETheme.border.opacity(0.9), lineWidth: 1.5)
          )
          .shadow(color: .black.opacity(0.45), radius: 8, y: 2)

        VStack(alignment: .leading, spacing: 6) {
          HStack(spacing: 6) {
            if paused {
              Text("PAUSED")
                .font(CETheme.mono(9))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(CETheme.crystal.opacity(0.95), in: Capsule())
            }
            OptimizedStatusBadge(optimized: optimized, compact: true)
          }
          gameTitleLabel(for: rom, baseSize: 20, bold: true, maxHeight: hasLogo ? 96 : 52)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Image(systemName: paused ? "pause.fill" : "play.fill")
          .font(.system(size: 16, weight: .semibold))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(CETheme.crystal.opacity(0.85))
          .padding(.trailing, 4)
          .allowsHitTesting(false)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
    }
    .frame(height: cardHeight)
    .contentShape(Rectangle())
    .clipShape(RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous)
        .stroke(paused ? CETheme.crystal : CETheme.border, lineWidth: paused ? 2 : 1)
    )
    .onTapGesture(coordinateSpace: .global) { point in
      handleGameTap(rom, at: point)
    }
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(rom.displayName)
    .accessibilityHint(settings.libraryOpenMode == .quickPlay ? "Shows Play confirmation" : "Opens game page")
    .contextMenu { artworkContextMenu(for: rom, landscapeDefault: true) }
  }

  private func handleGameTap(_ rom: RomItem, at point: CGPoint) {
    InputHaptics.selectionChange()
    switch settings.libraryOpenMode {
    case .quickPlay:
      playConfirm = PlayConfirmRequest(rom: rom, point: point)
    case .gamePage:
      onOpenGame?(rom)
    }
  }

  @ViewBuilder
  private func gameTitleLabel(
    for rom: RomItem,
    baseSize: CGFloat,
    bold: Bool,
    maxHeight: CGFloat
  ) -> some View {
    if let logo = artworkStore.image(forKey: rom.artworkKey, kind: .logo) {
      Image(uiImage: logo)
        .resizable()
        .interpolation(.high)
        .scaledToFit()
        .frame(maxWidth: .infinity, minHeight: maxHeight * 0.72, maxHeight: maxHeight, alignment: .leading)
        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        .accessibilityLabel(rom.displayName)
    } else {
      Text(rom.displayName)
        .font(libraryFonts.titleFont(
          size: libraryFonts.titleSize(base: baseSize),
          weight: bold ? .bold : .semibold
        ))
        .foregroundStyle(CETheme.text)
        .lineLimit(2)
        .minimumScaleFactor(0.55)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  @ViewBuilder
  private func coverImage(for rom: RomItem) -> some View {
    if let img = artworkStore.displayImage(forKey: rom.artworkKey, preferred: .cover) {
      Image(uiImage: img)
        .resizable()
        .scaledToFill()
    } else {
      CETheme.hover
        .overlay(
          VStack(spacing: 8) {
            Image(systemName: "gamecontroller")
              .font(.system(size: 28, weight: .light))
              .foregroundStyle(CETheme.muted)
            Text((rom.console?.rawValue ?? "rom").uppercased())
              .font(CETheme.mono(11))
              .foregroundStyle(CETheme.crystal)
          }
        )
    }
  }

  @ViewBuilder
  private func bannerImage(for rom: RomItem) -> some View {
    if let img = artworkStore.displayImage(forKey: rom.artworkKey, preferred: .banner) {
      Image(uiImage: img)
        .resizable()
        .scaledToFill()
    } else {
      CETheme.hover
        .overlay(
          HStack {
            Spacer()
            Image(systemName: "rectangle.fill")
              .font(.system(size: 28, weight: .light))
              .foregroundStyle(CETheme.muted.opacity(0.5))
            Spacer()
          }
        )
    }
  }

  @ViewBuilder
  private func artworkContextMenu(for rom: RomItem, landscapeDefault: Bool) -> some View {
    Button { onPlay(rom) } label: {
      Label(
        engine.isPausedRom(rom) ? "Resume" : "Play",
        systemImage: engine.isPausedRom(rom) ? "pause.fill" : "play.fill"
      )
    }
    Button {
      artworkTarget = ArtworkTarget(rom: rom, kind: landscapeDefault ? .banner : .cover)
    } label: {
      Label("Edit Game…", systemImage: "pencil")
    }
    Button {
      artworkTarget = ArtworkTarget(rom: rom, kind: .cover)
    } label: {
      Label("Set Cover", systemImage: "rectangle.portrait")
    }
    Button {
      artworkTarget = ArtworkTarget(rom: rom, kind: .banner)
    } label: {
      Label("Set Banner", systemImage: "rectangle")
    }
    Button {
      artworkTarget = ArtworkTarget(rom: rom, kind: .icon)
    } label: {
      Label("Set Icon", systemImage: "app")
    }
    Button {
      artworkTarget = ArtworkTarget(rom: rom, kind: .logo)
    } label: {
      Label("Set Logo", systemImage: "textformat")
    }
    Divider()
    Button(role: .destructive) {
      artworkStore.clear(forKey: rom.artworkKey, kind: nil)
    } label: {
      Label("Clear Artwork", systemImage: "photo")
    }
    Button(role: .destructive) {
      romPendingDelete = rom
    } label: {
      Label("Delete Game…", systemImage: "trash")
    }
  }

  private func deleteGame(_ rom: RomItem) {
    if engine.loadedRomKey == rom.sessionKey {
      engine.stop()
    }
    RecentlyPlayedStore.shared.remove(sessionKey: rom.sessionKey)
    do {
      try RomLibrary.deleteGame(rom)
      refresh()
    } catch {
      importError = error.localizedDescription
    }
  }
}

private struct SkinCheckmark: View {
  let isOn: Bool

  var body: some View {
    ZStack {
      Circle()
        .stroke(isOn ? CETheme.crystal : CETheme.muted.opacity(0.45), lineWidth: 2)
        .frame(width: 26, height: 26)
      Circle()
        .fill(CETheme.crystal)
        .frame(width: 26, height: 26)
        .scaleEffect(isOn ? 1 : 0.01)
        .opacity(isOn ? 1 : 0)
      Image(systemName: "checkmark")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.black)
        .scaleEffect(isOn ? 1 : 0.01)
        .opacity(isOn ? 1 : 0)
    }
    .frame(width: 28, height: 28)
    .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isOn)
    .accessibilityLabel(isOn ? "Selected" : "Not selected")
  }
}

/// Library pages: one per console, plus Skins / Save Editor / Settings.
private enum LibraryDestination: Hashable, Identifiable {
  case console(ConsoleKind)
  case skins
  case saveEditor
  case settings

  var id: String {
    switch self {
    case .console(let kind): return "console-\(kind.rawValue)"
    case .skins: return "skins"
    case .saveEditor: return "save-editor"
    case .settings: return "settings"
    }
  }

  var title: String {
    switch self {
    case .console(let kind): return kind.title
    case .skins: return "Skins"
    case .saveEditor: return "Save Editor"
    case .settings: return "Settings"
    }
  }
}

struct ArtworkTarget: Identifiable {
  let rom: RomItem
  let kind: RomArtworkKind
  var id: String { "\(rom.artworkKey)-\(kind.rawValue)" }
}

private struct PlayConfirmRequest {
  let rom: RomItem
  /// Touch location in `.global` space.
  let point: CGPoint
}

/// iOS 26+ Liquid Glass tab bars morph/expand on scroll by default — pin them compact.
private struct CompactTabBarChrome: ViewModifier {
  func body(content: Content) -> some View {
    if #available(iOS 26.0, *) {
      content
        .tabBarMinimizeBehavior(.never)
    } else {
      content
    }
  }
}

/// Play confirm — tip is pinned to the press; body flips above/below so it never aims elsewhere.
private struct PlayConfirmBubble: View {
  let rom: RomItem
  let globalAnchor: CGPoint
  let onPlay: () -> Void
  let onDismiss: () -> Void

  private let cardWidth: CGFloat = 220
  private let estimatedHeight: CGFloat = 168
  private let margin: CGFloat = 14
  private let cornerRadius: CGFloat = 36
  private let pointerSize: CGFloat = 12
  /// Matches `SkinCheckmark` / library selection feel.
  private let slime = Animation.spring(response: 0.28, dampingFraction: 0.72)

  @State private var expanded = false

  private struct Placement {
    var origin: CGPoint
    var pointerX: CGFloat
    /// `true` = tip on bottom pointing down at press; `false` = tip on top pointing up.
    var tipOnBottom: Bool
  }

  var body: some View {
    GeometryReader { geo in
      let frame = geo.frame(in: .global)
      let localAnchor = CGPoint(
        x: globalAnchor.x - frame.minX,
        y: globalAnchor.y - frame.minY
      )
      let place = placement(anchor: localAnchor, in: geo.size, safe: geo.safeAreaInsets)
      let shape = PlayConfirmBubbleShape(
        cornerRadius: cornerRadius,
        pointerSize: pointerSize,
        pointerX: place.pointerX,
        tipOnBottom: place.tipOnBottom
      )
      let tipAnchor = UnitPoint(
        x: place.pointerX / cardWidth,
        y: place.tipOnBottom ? 1 : 0
      )
      let topPad = place.tipOnBottom ? 18 : 18 + pointerSize
      let bottomPad = place.tipOnBottom ? 16 + pointerSize : 16
      ZStack(alignment: .topLeading) {
        // Soft full-bleed dim only — no material blur.
        Color.black.opacity(0.22)
          .ignoresSafeArea()
          .opacity(expanded ? 1 : 0)
          .animation(slime, value: expanded)
          .contentShape(Rectangle())
          .onTapGesture { collapse(then: onDismiss) }

        VStack(spacing: 12) {
          Text(rom.displayName)
            .font(CETheme.sans(14, weight: .semibold))
            .foregroundStyle(CETheme.text)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
          Button {
            InputHaptics.selectionChange()
            collapse(then: onPlay)
          } label: {
            Label("Play", systemImage: "play.fill")
              .font(CETheme.sans(16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .padding(.vertical, 11)
          }
          .buttonStyle(.borderedProminent)
          .tint(CETheme.crystal)
        }
        .padding(.horizontal, 18)
        .padding(.top, topPad)
        .padding(.bottom, bottomPad)
        .frame(width: cardWidth, alignment: .center)
        .background {
          shape
            .fill(.ultraThinMaterial)
            .overlay { shape.fill(Color.white.opacity(0.06)) }
            .overlay { shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5) }
        }
        .clipShape(shape)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(expanded ? 0.34 : 0), radius: 18, y: 8)
        // Grow from the tip locked to the press on the game.
        .scaleEffect(expanded ? 1 : 0.01, anchor: tipAnchor)
        .opacity(expanded ? 1 : 0)
        .offset(x: place.origin.x, y: place.origin.y)
        .animation(slime, value: expanded)
      }
    }
    .onAppear {
      expanded = false
      DispatchQueue.main.async {
        expanded = true
      }
    }
  }

  private func collapse(then: @escaping () -> Void) {
    withAnimation(slime) { expanded = false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
      then()
    }
  }

  /// Tip is always at the press. Body goes above when there’s room, otherwise below.
  private func placement(anchor: CGPoint, in size: CGSize, safe: EdgeInsets) -> Placement {
    let tipHalf = pointerSize * 0.85
    let minX = margin + safe.leading
    let maxX = size.width - margin - safe.trailing - cardWidth
    let topBound = margin + safe.top
    let bottomBound = size.height - margin - safe.bottom

    var x = anchor.x - cardWidth / 2
    x = min(max(x, minX), max(minX, maxX))

    let spaceAbove = anchor.y - topBound
    let spaceBelow = bottomBound - anchor.y
    // Prefer tip on bottom (bubble above press). Flip when the press is too high.
    let tipOnBottom = spaceAbove >= estimatedHeight || spaceAbove >= spaceBelow

    let y: CGFloat
    if tipOnBottom {
      // Tip at bottom of bubble == press.
      y = anchor.y - estimatedHeight
    } else {
      // Tip at top of bubble == press; body hangs below.
      y = anchor.y
    }

    let edgePad = cornerRadius + tipHalf + 4
    var pointerX = anchor.x - x
    pointerX = min(max(pointerX, edgePad), cardWidth - edgePad)
    return Placement(origin: CGPoint(x: x, y: y), pointerX: pointerX, tipOnBottom: tipOnBottom)
  }
}

/// One continuous bubble path; tip is pinned to `pointerX` on bottom or top.
private struct PlayConfirmBubbleShape: Shape {
  var cornerRadius: CGFloat
  var pointerSize: CGFloat
  var pointerX: CGFloat
  var tipOnBottom: Bool

  func path(in rect: CGRect) -> Path {
    let tipH = max(0, pointerSize)
    let r = min(cornerRadius, min(rect.width, max(0, rect.height - tipH)) / 2)
    let tipHalf = tipH * 0.85
    let tipX = min(max(pointerX, rect.minX + r + tipHalf), rect.maxX - r - tipHalf)

    let bodyMinY = tipOnBottom ? rect.minY : rect.minY + tipH
    let bodyMaxY = tipOnBottom ? rect.maxY - tipH : rect.maxY

    var path = Path()
    if tipOnBottom {
      // Tip on bottom, pointing down at the press.
      path.move(to: CGPoint(x: rect.minX + r, y: bodyMinY))
      path.addLine(to: CGPoint(x: rect.maxX - r, y: bodyMinY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: bodyMinY + r),
        control: CGPoint(x: rect.maxX, y: bodyMinY)
      )
      path.addLine(to: CGPoint(x: rect.maxX, y: bodyMaxY - r))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX - r, y: bodyMaxY),
        control: CGPoint(x: rect.maxX, y: bodyMaxY)
      )
      path.addLine(to: CGPoint(x: tipX + tipHalf, y: bodyMaxY))
      path.addLine(to: CGPoint(x: tipX, y: rect.maxY))
      path.addLine(to: CGPoint(x: tipX - tipHalf, y: bodyMaxY))
      path.addLine(to: CGPoint(x: rect.minX + r, y: bodyMaxY))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX, y: bodyMaxY - r),
        control: CGPoint(x: rect.minX, y: bodyMaxY)
      )
      path.addLine(to: CGPoint(x: rect.minX, y: bodyMinY + r))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX + r, y: bodyMinY),
        control: CGPoint(x: rect.minX, y: bodyMinY)
      )
    } else {
      // Tip on top, pointing up at the press (game near top of screen).
      path.move(to: CGPoint(x: rect.minX + r, y: bodyMinY))
      path.addLine(to: CGPoint(x: tipX - tipHalf, y: bodyMinY))
      path.addLine(to: CGPoint(x: tipX, y: rect.minY))
      path.addLine(to: CGPoint(x: tipX + tipHalf, y: bodyMinY))
      path.addLine(to: CGPoint(x: rect.maxX - r, y: bodyMinY))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX, y: bodyMinY + r),
        control: CGPoint(x: rect.maxX, y: bodyMinY)
      )
      path.addLine(to: CGPoint(x: rect.maxX, y: bodyMaxY - r))
      path.addQuadCurve(
        to: CGPoint(x: rect.maxX - r, y: bodyMaxY),
        control: CGPoint(x: rect.maxX, y: bodyMaxY)
      )
      path.addLine(to: CGPoint(x: rect.minX + r, y: bodyMaxY))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX, y: bodyMaxY - r),
        control: CGPoint(x: rect.minX, y: bodyMaxY)
      )
      path.addLine(to: CGPoint(x: rect.minX, y: bodyMinY + r))
      path.addQuadCurve(
        to: CGPoint(x: rect.minX + r, y: bodyMinY),
        control: CGPoint(x: rect.minX, y: bodyMinY)
      )
    }
    path.closeSubpath()
    return path
  }
}
