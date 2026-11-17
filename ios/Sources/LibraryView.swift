import SwiftUI
import UIKit

struct LibraryView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject private var artworkStore = RomArtworkStore.shared
  @ObservedObject private var libraryFonts = LibraryFontStore.shared
  @ObservedObject private var recentlyPlayed = RecentlyPlayedStore.shared
  let onPlay: (RomItem) -> Void
  var onOpenGame: ((RomItem) -> Void)? = nil
  var onEditSave: ((RomItem) -> Void)? = nil
  var onOpenSettings: (() -> Void)? = nil
  @State private var saveMissingAlert = false

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
  /// Prevents overlapping Libretro backfill passes (Drive sync / re-open).
  @State private var isBackfillingArt = false
  /// Splash wordmark for ~3s on launch, then crossfades to the active console/section.
  @State private var showBrandIntro = true
  /// Duo closed / outer front display — compact chrome + cover grid (Apple Duo UX).
  @State private var hingeClosed = false
  /// Viewport of the games ScrollView — read via background GeometryReader (never wraps ScrollView).
  @State private var gamesViewport: CGSize = .zero
  /// Settings opens from the floating gear (own page, no console logo).
  @State private var showSettings = false
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @AppStorage("library.selectedConsole") private var storedConsoleRaw: String = ConsoleKind.gba.rawValue

  private var chromeCompact: Bool { hingeClosed || verticalSizeClass == .compact }

  var body: some View {
    // No shared gray top bar — console logos sit in each tab; settings is a floating gear.
    ZStack(alignment: .topTrailing) {
      // Order: GB → GBC → GBA → DS → Import; Skins / Editor land under system More.
      TabView(selection: tabSelection) {
        libraryPage(active: destination == .console(.gb)) {
          gamesBody(for: .gb)
        }
        .tabItem {
          Label {
            Text(ConsoleKind.gb.shortTitle)
          } icon: {
            Image(uiImage: ConsoleTabIcon.image(for: .gb))
          }
        }
        .tag(LibraryDestination.console(.gb))

        libraryPage(active: destination == .console(.gbc)) {
          gamesBody(for: .gbc)
        }
        .tabItem {
          Label {
            Text(ConsoleKind.gbc.shortTitle)
          } icon: {
            Image(uiImage: ConsoleTabIcon.image(for: .gbc))
          }
        }
        .tag(LibraryDestination.console(.gbc))

        libraryPage(active: destination == .console(.gba)) {
          gamesBody(for: .gba)
        }
        .tabItem {
          Label {
            Text(ConsoleKind.gba.shortTitle)
          } icon: {
            Image(uiImage: ConsoleTabIcon.image(for: .gba))
          }
        }
        .tag(LibraryDestination.console(.gba))

        libraryPage(active: destination == .console(.nds)) {
          gamesBody(for: .nds)
        }
        .tabItem {
          Label {
            Text(ConsoleKind.nds.shortTitle)
          } icon: {
            Image(uiImage: ConsoleTabIcon.image(for: .nds))
          }
        }
        .tag(LibraryDestination.console(.nds))

        libraryPage(active: destination == .importRoms) {
          importBody
        }
        .tabItem { Label("Import", systemImage: "square.and.arrow.down") }
        .tag(LibraryDestination.importRoms)

        libraryPage(active: destination == .skins) {
          skinsBody
        }
        .tabItem { Label("Skins", systemImage: "paintbrush.fill") }
        .tag(LibraryDestination.skins)

        libraryPage(active: destination == .saveEditor) {
          SaveEditorListView(
            roms: roms,
            engineLoadedStem: engine.loadedRomURL?.deletingPathExtension().lastPathComponent
          )
        }
        .tabItem { Label("Editor", systemImage: "square.and.pencil") }
        .tag(LibraryDestination.saveEditor)
      }
      .tint(CETheme.crystal)
      .modifier(CompactTabBarChrome())

      floatingChrome
    }
    .fullScreenCover(isPresented: $showSettings) {
      SettingsView(showsBackButton: true)
        .environmentObject(settings)
        .environmentObject(engine)
        .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
    }
    .modifier(DuoHingeClosedObserver { closed in
      hingeClosed = closed
    })
    .toolbar(.hidden, for: .navigationBar)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbarBackground(.visible, for: .tabBar)
    // Same black through the status-bar safe area — no gray bezel above the console logo.
    .background(CETheme.bg.ignoresSafeArea())
    .onChange(of: destination) { _, newValue in
      if newValue == .importRoms {
        showImporter = true
      }
    }
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
    .alert("No save yet", isPresented: $saveMissingAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Play this game once so PocketDex writes a battery .sav, then Edit Save will open the editor for it.")
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
        // Plain assignment — animating selection made the bottom pill glitch while scrolling.
        destination = newValue
      }
    )
  }

  private func libraryPage<Content: View>(
    active: Bool,
    @ViewBuilder content: () -> Content
  ) -> some View {
    LibraryPageTransition(isActive: active, content: content)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  /// Floating gear + brief PocketDex splash — no full-width gray header bar.
  private var floatingChrome: some View {
    let compact = chromeCompact
    let btn: CGFloat = compact ? 34 : 38
    return VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        if showBrandIntro {
          brandWordmark(compact: compact)
            .transition(.opacity)
        }
        Spacer(minLength: 0)
        Button {
          InputHaptics.selectionChange()
          showSettings = true
        } label: {
          Image(systemName: "gearshape.fill")
            .font(.system(size: compact ? 15 : 17, weight: .semibold))
            .foregroundStyle(CETheme.text)
            .frame(width: btn, height: btn)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(CETheme.border.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
      }
      .padding(.horizontal, 16)
      .padding(.top, compact ? 8 : 10)
      Spacer(minLength: 0)
    }
    .animation(.easeInOut(duration: 0.6), value: showBrandIntro)
    .allowsHitTesting(true)
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
    .accessibilityLabel("PocketDex")
  }

  private func consoleTabLogo(kind: ConsoleKind, compact: Bool) -> some View {
    ConsoleSystemLogo(kind: kind, height: compact ? 26 : 38)
      .frame(maxWidth: compact ? 220 : 360, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.top, compact ? 44 : 52) // Clear the floating gear.
      .padding(.bottom, compact ? 6 : 8)
      .accessibilityLabel(kind.title)
  }

  private func scheduleBrandIntro() {
    guard showBrandIntro else { return }
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      withAnimation(.easeInOut(duration: 0.6)) {
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
    let compact = hingeClosed || verticalSizeClass == .compact
    let list = roms.filter { $0.console == kind }
    let recent = recentlyPlayed.recent(in: list)
    // Prefer measured viewport; fall back via size class (never wrap ScrollView in GeometryReader —
    // TabView landscape + that pair creates an infinite content-size loop while scrolling).
    let viewport = gamesViewport
    let measured = viewport.width > 1 && viewport.height > 1
    let outerLandscape = hingeClosed && (
      verticalSizeClass == .compact
        || (measured && viewport.width > viewport.height * 1.05)
    )
    let shortCanvas = hingeClosed || (measured && viewport.height < 520)
    let useContinueBanners: Bool = {
      guard !hingeClosed else { return false }
      if measured {
        return viewport.width > viewport.height * 1.08 && viewport.height >= 520
      }
      return verticalSizeClass == .compact
    }()
    // Cover landscape is wide+short — smaller poster minimum so the grid fills edge-to-edge
    // instead of two fat columns with empty side margins.
    let posterMin: CGFloat = {
      if outerLandscape { return 88 }
      if shortCanvas { return 108 }
      return 124
    }()
    let gridSpacing: CGFloat = outerLandscape ? 10 : 14
    let columns = [GridItem(.adaptive(minimum: posterMin), spacing: gridSpacing)]
    let hPad: CGFloat = outerLandscape ? 10 : 16
    return VStack(spacing: 0) {
      // Logo lives in-tab so the system More page never inherits a console wordmark.
      consoleTabLogo(kind: kind, compact: compact)
      Group {
        if roms.isEmpty {
          emptyGames
        } else if list.isEmpty {
          emptyConsole
        } else {
          ScrollView {
            LazyVStack(alignment: .leading, spacing: outerLandscape ? 14 : 22) {
              if !recent.isEmpty {
                librarySectionHeader("Continue")
                if useContinueBanners {
                  VStack(spacing: 12) {
                    ForEach(recent) { rom in
                      gameBannerCard(rom)
                    }
                  }
                } else {
                  ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: outerLandscape ? 10 : 14) {
                      ForEach(recent) { rom in
                        continuePoster(rom, width: outerLandscape ? 96 : (shortCanvas ? 112 : 132))
                      }
                    }
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 2)
                  }
                  .padding(.horizontal, -hPad)
                  .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
              }

              librarySectionHeader(recent.isEmpty ? "Games" : "All Games")
              LazyVGrid(columns: columns, spacing: outerLandscape ? 12 : 18) {
                ForEach(list) { rom in
                  gamePosterTile(rom)
                }
              }
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, outerLandscape ? 6 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("\(artworkStore.revision)-\(kind.rawValue)-\(recentlyPlayed.datesByKey.count)-\(hingeClosed)-\(outerLandscape)-\(useContinueBanners)")
          }
          .background {
            GeometryReader { geo in
              Color.clear
                .onAppear { gamesViewport = geo.size }
                .onChange(of: geo.size) { _, newSize in
                  // Ignore tiny inset jitter from the Liquid Glass pill while scrolling —
                  // that was rebuilding the grid and making the tab bar flicker.
                  if abs(newSize.width - gamesViewport.width) > 24
                      || abs(newSize.height - gamesViewport.height) > 48 {
                    gamesViewport = newSize
                  }
                }
            }
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
      .tracking(0.8)
  }

  private func hasBatterySave(_ rom: RomItem) -> Bool {
    FileManager.default.fileExists(atPath: RomLibrary.savePath(forRom: rom.url).path)
  }

  private func openSaveEditor(for rom: RomItem) {
    InputHaptics.selectionChange()
    guard hasBatterySave(rom) else {
      saveMissingAlert = true
      return
    }
    onEditSave?(rom)
  }

  private var importBody: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "square.and.arrow.down")
        .font(.system(size: 40, weight: .semibold))
        .foregroundStyle(CETheme.crystal)
      Text("Import ROMs & Skins")
        .font(CETheme.sans(20, weight: .bold))
        .foregroundStyle(CETheme.text)
      Text("Add GB, GBC, GBA, or DS games, plus Delta / Manic skins. Covers apply automatically when found.")
        .font(CETheme.sans(14))
        .foregroundStyle(CETheme.muted)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
      Button { showImporter = true } label: {
        Text("Choose Files…")
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

  /// Quietly fill missing covers (Libretro CDN — free, no SteamGridDB account).
  /// Re-runs whenever the library gains ROMs without art (import, Drive sync, reopen).
  private func backfillArtworkIfNeeded() {
    guard !isBackfillingArt else { return }
    let missing = roms.filter { rom in
      guard rom.console != nil else { return false }
      let key = rom.artworkKey
      return !artworkStore.hasArtwork(forKey: key, kind: .cover)
        || !artworkStore.hasArtwork(forKey: key, kind: .logo)
    }
    guard !missing.isEmpty else { return }
    isBackfillingArt = true
    Task(priority: .utility) {
      for rom in missing {
        await LibretroArtworkApplier.applyIfNeeded(to: rom)
      }
      await MainActor.run { isBackfillingArt = false }
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

  /// Music/TV poster: cover art with title under, badges on the art.
  private func gamePosterTile(_ rom: RomItem) -> some View {
    let paused = engine.isPausedRom(rom)
    let optimized = OptimizedRomCatalog.isOptimized(
      fileName: rom.url.lastPathComponent,
      displayName: rom.displayName
    )
    return LibraryGameTapButton(action: { handleGameTap(rom, at: $0) }) {
      VStack(alignment: .leading, spacing: 8) {
        coverImage(for: rom)
          .aspectRatio(2.0 / 3.0, contentMode: .fit)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(paused ? CETheme.crystal : CETheme.border, lineWidth: paused ? 2 : 1)
          )
          .overlay(alignment: .topLeading) {
            if paused {
              Text("PAUSED")
                .font(CETheme.mono(8))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(CETheme.crystal.opacity(0.95), in: Capsule())
                .padding(8)
            }
          }
          .overlay(alignment: .bottomLeading) {
            OptimizedStatusBadge(optimized: optimized, compact: true)
              .padding(8)
          }
          .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

        Text(rom.displayName)
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.text)
          .lineLimit(3)
          .minimumScaleFactor(0.8)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .accessibilityLabel(rom.displayName)
    .accessibilityHint(settings.libraryOpenMode == .quickPlay ? "Shows Play confirmation" : "Opens game page")
    .contextMenu { artworkContextMenu(for: rom, landscapeDefault: false) }
  }

  /// Continue shelf poster (horizontal Music rail).
  private func continuePoster(_ rom: RomItem, width: CGFloat) -> some View {
    let paused = engine.isPausedRom(rom)
    let optimized = OptimizedRomCatalog.isOptimized(
      fileName: rom.url.lastPathComponent,
      displayName: rom.displayName
    )
    return LibraryGameTapButton(action: { handleGameTap(rom, at: $0) }) {
      VStack(alignment: .leading, spacing: 8) {
        coverImage(for: rom)
          .aspectRatio(2.0 / 3.0, contentMode: .fill)
          .frame(width: width, height: width * 1.5)
          .clipped()
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(paused ? CETheme.crystal : CETheme.border, lineWidth: paused ? 2 : 1)
          )
          .overlay(alignment: .topLeading) {
            if paused {
              Text("PAUSED")
                .font(CETheme.mono(8))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(CETheme.crystal.opacity(0.95), in: Capsule())
                .padding(7)
            }
          }
          .overlay(alignment: .bottomLeading) {
            OptimizedStatusBadge(optimized: optimized, compact: true)
              .padding(7)
          }
          .shadow(color: .black.opacity(0.4), radius: 12, y: 5)

        Text(rom.displayName)
          .font(CETheme.sans(12, weight: .semibold))
          .foregroundStyle(CETheme.text)
          .lineLimit(3)
          .minimumScaleFactor(0.8)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
          .frame(width: width, alignment: .leading)
      }
      .frame(width: width, alignment: .topLeading)
    }
    .accessibilityLabel(rom.displayName)
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
    return LibraryGameTapButton(action: { handleGameTap(rom, at: $0) }) {
      ZStack {
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
      .clipShape(RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous)
          .stroke(paused ? CETheme.crystal : CETheme.border, lineWidth: paused ? 2 : 1)
      )
    }
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
        .lineLimit(3)
        .minimumScaleFactor(0.55)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
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
    Button { onOpenGame?(rom) } label: {
      Label("Open Game Page", systemImage: "rectangle.stack.fill")
    }
    Button { openSaveEditor(for: rom) } label: {
      Label(
        hasBatterySave(rom) ? "Edit Save" : "Edit Save (needs .sav)",
        systemImage: "externaldrive.fill.badge.pencil"
      )
    }
    Divider()
    Button {
      artworkTarget = ArtworkTarget(rom: rom, kind: landscapeDefault ? .banner : .cover)
    } label: {
      Label("Edit Artwork…", systemImage: "pencil")
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

/// Library pages: consoles + Import / Skins / Save Editor (overflow items appear under system More).
private enum LibraryDestination: Hashable, Identifiable {
  case console(ConsoleKind)
  case importRoms
  case skins
  case saveEditor

  var id: String {
    switch self {
    case .console(let kind): return "console-\(kind.rawValue)"
    case .importRoms: return "import"
    case .skins: return "skins"
    case .saveEditor: return "save-editor"
    }
  }

  var title: String {
    switch self {
    case .console(let kind): return kind.title
    case .importRoms: return "Import"
    case .skins: return "Skins"
    case .saveEditor: return "Save Editor"
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

/// iOS 26+ Liquid Glass tab bars morph on scroll by default — pin them and freeze appearance.
private struct CompactTabBarChrome: ViewModifier {
  func body(content: Content) -> some View {
    Group {
      if #available(iOS 26.0, *) {
        content
          .tabBarMinimizeBehavior(.never)
      } else {
        content
      }
    }
    .onAppear { Self.applyStableAppearance() }
  }

  private static func applyStableAppearance() {
    let appearance = UITabBarAppearance()
    appearance.configureWithDefaultBackground()
    // Keep selected / unselected metrics stable so scroll inset changes don’t restyle the pill.
    let item = UITabBarItemAppearance()
    item.normal.iconColor = UIColor.secondaryLabel
    item.selected.iconColor = UIColor.label
    appearance.stackedLayoutAppearance = item
    appearance.inlineLayoutAppearance = item
    appearance.compactInlineLayoutAppearance = item
    let bar = UITabBar.appearance()
    bar.standardAppearance = appearance
    bar.scrollEdgeAppearance = appearance
    bar.isTranslucent = true
  }
}

/// Subtle fade/slide when a library tab becomes the selected page.
private struct LibraryPageTransition<Content: View>: View {
  let isActive: Bool
  let content: Content
  @State private var visible = false

  init(isActive: Bool, @ViewBuilder content: () -> Content) {
    self.isActive = isActive
    self.content = content()
  }

  var body: some View {
    content
      .opacity(visible ? 1 : 0.001)
      .offset(y: visible ? 0 : 8)
      .onAppear { playEntranceIfNeeded(isActive) }
      .onChange(of: isActive) { _, active in
        playEntranceIfNeeded(active)
      }
  }

  private func playEntranceIfNeeded(_ active: Bool) {
    guard active else {
      visible = false
      return
    }
    visible = false
    withAnimation(.easeOut(duration: 0.26)) {
      visible = true
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
