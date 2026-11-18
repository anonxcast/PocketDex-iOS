import SwiftUI
import UniformTypeIdentifiers

/// Local drill-in screens — no nested NavigationStack (library already has one).
private enum SettingsScreen: Equatable {
  case categories
  case category(SettingsCategory)
  case shaders
  case padEditor
}

/// Delta-inspired settings: category list with leading icons, then toggles inside.
struct SettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dismiss) private var dismiss
  /// When embedded in the library (side-rail / tab), hide the back chevron.
  var showsBackButton: Bool = true
  /// Jump straight into a category (e.g. Artwork from SteamGridDB gate).
  var initialCategory: SettingsCategory? = nil

  @State private var screen: SettingsScreen = .categories
  @State private var hingeClosed = false

  var body: some View {
    Group {
      switch screen {
      case .categories:
        categoriesRoot
      case .category(let category):
        SettingsCategoryDetail(
          category: category,
          onBack: { screen = .categories },
          onOpenShaders: { screen = .shaders },
          onOpenPadEditor: { screen = .padEditor }
        )
      case .shaders:
        ShadersSettingsView(onBack: {
          screen = .category(.display)
        })
      case .padEditor:
        PadLayoutEditorView(
          coverFace: hingeClosed,
          isPresented: Binding(
            get: { screen == .padEditor },
            set: { if !$0 { screen = .category(.controllers) } }
          )
        )
      }
    }
    .modifier(DuoHingeClosedObserver { closed in
      hingeClosed = closed
    })
    .onAppear {
      if let initialCategory, screen == .categories {
        screen = .category(initialCategory)
      }
    }
  }

  private var categoriesRoot: some View {
    ZStack {
      CETheme.bg.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 10) {
          ForEach(SettingsCategory.allCases) { category in
            Button {
              screen = .category(category)
            } label: {
              categoryRow(category)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(16)
      }
    }
    .navigationBarHidden(true)
    .safeAreaInset(edge: .top) {
      settingsChrome
    }
  }

  private var settingsChrome: some View {
    HStack(spacing: 12) {
      if showsBackButton {
        Button {
          dismiss()
        } label: {
          Image(systemName: "chevron.left")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(CETheme.accent)
            .frame(width: 36, height: 36)
            .background(CETheme.card, in: Circle())
            .overlay(Circle().stroke(CETheme.border, lineWidth: 1))
        }
      }
      Text("Settings")
        .font(CETheme.sans(20, weight: .bold))
        .foregroundStyle(CETheme.text)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .background(CETheme.elevated)
    .overlay(alignment: .bottom) {
      Rectangle().fill(CETheme.border).frame(height: 1)
    }
  }

  private func categoryRow(_ category: SettingsCategory) -> some View {
    HStack(spacing: 14) {
      categoryIcon(category)
      VStack(alignment: .leading, spacing: 3) {
        Text(category.title)
          .font(CETheme.sans(16, weight: .semibold))
          .foregroundStyle(CETheme.text)
        Text(category.subtitle)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
          .lineLimit(2)
      }
      Spacer(minLength: 8)
      Image(systemName: "chevron.right")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(CETheme.muted.opacity(0.7))
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
  }

  private func categoryIcon(_ category: SettingsCategory) -> some View {
    Image(systemName: category.systemImage)
      .font(.system(size: 15, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 32, height: 32)
      .background(category.tint, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
  case controllers
  case audio
  case display
  case artwork
  case achievements
  case cloud
  case skins
  case support
  case about

  var id: String { rawValue }

  var title: String {
    switch self {
    case .controllers: return "Controllers"
    case .audio: return "Audio"
    case .display: return "Display"
    case .artwork: return "Artwork"
    case .achievements: return "Achievements"
    case .cloud: return "Cloud"
    case .skins: return "Skins"
    case .support: return "Support"
    case .about: return "About"
    }
  }

  var subtitle: String {
    switch self {
    case .controllers: return "Touch controls & haptics"
    case .audio: return "Game sound output"
    case .display: return "Screen, library tap & playback"
    case .artwork: return "Covers, banners, fonts & SteamGridDB"
    case .achievements: return "RetroAchievements sign-in & tracking"
    case .cloud: return "Google Drive ROMs, saves & covers"
    case .skins: return "Controller skin overlays"
    case .support: return "ROM companion queue & Expand status"
    case .about: return "Version & credits"
    }
  }

  var systemImage: String {
    switch self {
    case .controllers: return "gamecontroller.fill"
    case .audio: return "speaker.wave.2.fill"
    case .display: return "rectangle.inset.filled"
    case .artwork: return "photo.on.rectangle.angled"
    case .achievements: return "trophy.fill"
    case .cloud: return "externaldrive.fill.badge.icloud"
    case .skins: return "paintbrush.fill"
    case .support: return "wrench.and.screwdriver.fill"
    case .about: return "info.circle.fill"
    }
  }

  /// Colored tile behind the SF Symbol (iOS Settings–style; white glyph on top).
  var tint: Color {
    switch self {
    case .controllers: return Color(red: 0.90, green: 0.28, blue: 0.34) // PocketDex red
    case .audio: return Color(red: 0.95, green: 0.55, blue: 0.18) // amber
    case .display: return Color(red: 0.28, green: 0.52, blue: 0.96) // display blue
    case .artwork: return Color(red: 0.92, green: 0.38, blue: 0.58) // rose
    case .achievements: return Color(red: 0.95, green: 0.75, blue: 0.22) // gold
    case .cloud: return Color(red: 0.22, green: 0.62, blue: 0.95) // Drive sky
    case .skins: return Color(red: 0.22, green: 0.72, blue: 0.58) // mint
    case .support: return Color(red: 0.95, green: 0.68, blue: 0.20) // tools gold
    case .about: return Color(red: 0.42, green: 0.78, blue: 0.92) // crystal
    }
  }
}

struct SettingsCategoryDetail: View {
  @EnvironmentObject private var settings: AppSettings
  let category: SettingsCategory
  var onBack: () -> Void
  var onOpenShaders: (() -> Void)? = nil
  var onOpenPadEditor: (() -> Void)? = nil
  @State private var showOptimizedRoms = false

  var body: some View {
    ZStack {
      CETheme.bg.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 12) {
          switch category {
          case .controllers:
            settingsCard {
              toggleRow(
                title: "Touch Haptics",
                subtitle: "Subtle vibration when pressing buttons or sliding the D-pad",
                systemImage: "waveform",
                isOn: $settings.hapticsEnabled
              )
              toggleRow(
                title: "Lighter D-pad",
                subtitle: "Turn this on if the game lags or acts weird while sliding the D-pad. Leave off for the fullest haptics and pad response.",
                systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                isOn: $settings.dpadLiteMode
              )
            }
            Button {
              onOpenPadEditor?()
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundStyle(CETheme.accent)
                  .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                  Text("Customize Button Layout")
                    .font(CETheme.sans(15, weight: .semibold))
                    .foregroundStyle(CETheme.text)
                  Text("Drag Start, Select, A/B, L/R, and the D-pad. Portrait and landscape are saved separately.")
                    .font(CETheme.sans(12))
                    .foregroundStyle(CETheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(CETheme.muted.opacity(0.7))
              }
              .padding(14)
              .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
              .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button {
              TouchPadLayoutStore.shared.resetAll()
            } label: {
              Text("Reset layouts to default")
                .font(CETheme.sans(13, weight: .semibold))
                .foregroundStyle(CETheme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }
            hint("Four separate profiles: Front/Inner × Portrait/Landscape. Editing on the Duo cover never changes the open-phone pads.")

          case .audio:
            settingsCard {
              toggleRow(
                title: "Game Audio",
                subtitle: "Play sound from GB, GBC, and GBA games",
                systemImage: "speaker.wave.2",
                isOn: $settings.audioEnabled
              )
            }

          case .artwork:
            SteamGridDBSettingsCard()
            LibraryFontSettingsCard()
            hint("Long-press a game in the library to set cover, banner, or icon from Photos, Files, or SteamGridDB.")

          case .achievements:
            RetroAchievementsSettingsCard()
            hint("Paste your RetroAchievements username and web API key from the site control panel. Game pages show earned / remaining achievements for matching ROMs.")

          case .cloud:
            GoogleDriveSettingsCard()
            hint("Sign in with Google to back up ROMs, Saves, and States to Drive. After reinstall, sign in again and PocketDex restores everything automatically.")

          case .display:
            settingsCard {
              VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                  .font(CETheme.sans(15, weight: .semibold))
                  .foregroundStyle(CETheme.text)
                Text("System follows iOS Light / Dark. Light and Dark lock the library chrome.")
                  .font(CETheme.sans(12))
                  .foregroundStyle(CETheme.muted)
                  .fixedSize(horizontal: false, vertical: true)
                Picker("Appearance", selection: $settings.appearanceMode) {
                  ForEach(AppAppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                  }
                }
                .pickerStyle(.segmented)
              }
            }
            settingsCard {
              VStack(alignment: .leading, spacing: 10) {
                Text("When tapping a game")
                  .font(CETheme.sans(15, weight: .semibold))
                  .foregroundStyle(CETheme.text)
                Text("Game Page opens art, summary, and achievements. Quick Play keeps the finger bubble.")
                  .font(CETheme.sans(12))
                  .foregroundStyle(CETheme.muted)
                  .fixedSize(horizontal: false, vertical: true)
                Picker("Library tap", selection: $settings.libraryOpenMode) {
                  ForEach(LibraryOpenMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                  }
                }
                .pickerStyle(.segmented)
              }
            }
            settingsCard {
              toggleRow(
                title: "Keep Screen Awake",
                subtitle: "Prevent sleep while a game is running",
                systemImage: "sun.max",
                isOn: $settings.keepScreenAwake
              )
            }
            settingsCard {
              cycleRow(
                title: "Aspect",
                value: settings.gameAspect.title,
                subtitle: settings.gameAspect.subtitle,
                systemImage: "aspectratio"
              ) { settings.gameAspect.cycle() }
              Divider().background(CETheme.border)
              cycleRow(
                title: "Zoom",
                value: settings.zoomLevel.title,
                subtitle: "Expand only — cycle in-game; 3×/4× need a large enough play area",
                systemImage: "plus.magnifyingglass",
                enabled: settings.gameAspect == .expand
              ) { settings.zoomLevel.cycle() }
              Divider().background(CETheme.border)
              toggleRow(
                title: "Auto Zoom In",
                subtitle: "Pull zoom in for battles (and keep text readable)",
                systemImage: "arrow.down.right.and.arrow.up.left",
                isOn: $settings.autoZoomIn
              )
            }
            hint("Expand rebuilds the overworld past the console frame (PokeDaisy WIDE) — Zoom steps out to show more map, not a smaller stretch.")

            settingsCard {
              cycleRow(
                title: "Status Bar",
                value: settings.statusBarMode.title,
                subtitle: "Game name, location, money, clock",
                systemImage: "menubar.rectangle"
              ) { settings.statusBarMode.cycle() }
              Divider().background(CETheme.border)
              toggleRow(
                title: "Folder Layout",
                subtitle: "Game on top, controls under the fold (Duo book / tabletop)",
                systemImage: "rectangle.split.1x2",
                isOn: $settings.folderLayout
              )
              Divider().background(CETheme.border)
              cycleRow(
                title: "DS Layout",
                value: settings.dsLayout.title,
                subtitle: settings.dsLayout.subtitle,
                systemImage: "rectangle.on.rectangle"
              ) { settings.dsLayout.cycle() }
            }

            Button {
              onOpenShaders?()
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "camera.filters")
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundStyle(CETheme.accent)
                  .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 4) {
                  Text("Shaders")
                    .font(CETheme.sans(15, weight: .semibold))
                    .foregroundStyle(CETheme.text)
                  Text("LCD, CRT, scanlines, GBA Colors, Unlit")
                    .font(CETheme.sans(12))
                    .foregroundStyle(CETheme.muted)
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(CETheme.muted.opacity(0.7))
              }
              .padding(14)
              .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
              .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

          case .skins:
            settingsCard {
              toggleRow(
                title: "Enable Skins",
                subtitle: "Use Delta skins when one is selected for the console",
                systemImage: "paintbrush",
                isOn: $settings.skinsEnabled
              )
            }
            hint("Manage imported .deltaskin files from the Skins tab in the library.")

          case .support:
            SupportQueuePanel()

          case .about:
            settingsCard {
              infoRow(title: "Version", value: appVersion)
              Divider().background(CETheme.border)
              infoRow(title: "Build", value: appBuild)
              Divider().background(CETheme.border)
              infoRow(title: "Core", value: "mGBA · melonDS")
            }

            aboutSectionLabel("Credits")
            settingsCard {
              creditRow(
                title: "PokeDaisy",
                body: "Based on PokeDaisy by Lidor Itzhari — https://github.com/lidor30/pokedaisy (GNU GPLv3 with additional credit term)."
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "mGBA",
                body: "Game Boy, Game Boy Color, and Game Boy Advance core by Vicki Pfau (endrift) and contributors (Mozilla Public License 2.0) — https://mgba.io"
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "melonDS",
                body: "Nintendo DS core by the melonDS team and contributors (GNU GPLv3) — https://melonds.kuribo64.net"
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "RetroAchievements",
                body: "Achievement sets and optional in-game tracking via the RetroAchievements Web API / rcheevos (MIT) — https://retroachievements.org"
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "Libretro thumbnails",
                body: "Free box art, titles, and logos from the Libretro thumbnails CDN — https://thumbnails.libretro.com"
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "SteamGridDB",
                body: "Optional community covers and banners when you add your own API key — https://www.steamgriddb.com"
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "Delta",
                body: "Controller skins use the .deltaskin format popularized by Delta (Riley Testut). Console tab silhouettes are from Delta’s open-source Controller Icons. PocketDex is not affiliated with Delta — https://github.com/rileytestut/Delta"
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "pret & expansions",
                body: "Companion maps, save layouts, and hack support were checked against the pret decompilations (pokeemerald, pokefirered, pokecrystal, and related projects) and community expansions such as pokeemerald-expansion."
              )
              Divider().background(CETheme.border)
              creditRow(
                title: "Console wordmarks",
                body: "Library system logos are public-domain text logos (PD-textlogo) sourced from Wikimedia Commons. Game Boy, Game Boy Color, Game Boy Advance, Nintendo DS, and related marks are trademarks of Nintendo."
              )
            }

            aboutSectionLabel("Optimized")
            Button {
              showOptimizedRoms = true
            } label: {
              HStack(spacing: 12) {
                ZStack {
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(red: 0.22, green: 0.42, blue: 0.48))
                  Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                  Text("Optimized ROMs")
                    .font(CETheme.sans(15, weight: .semibold))
                    .foregroundStyle(CETheme.text)
                  Text("\(OptimizedRomCatalog.all.count) games with Expand, companion & save editor")
                    .font(CETheme.sans(12))
                    .foregroundStyle(CETheme.muted)
                    .lineLimit(2)
                }
                Spacer(minLength: 8)
                Image(systemName: "info.circle")
                  .font(.system(size: 18, weight: .semibold))
                  .foregroundStyle(CETheme.crystal)
                Image(systemName: "chevron.right")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(CETheme.muted.opacity(0.7))
              }
              .padding(14)
              .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
              .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            hint("PocketDex is a fan project, not affiliated with or endorsed by Nintendo, Game Freak, Creatures, or The Pokémon Company. Pokémon and all related names are trademarks of their respective owners. Use your own legally obtained ROM dumps — no games or BIOS are included.")
          }
        }
        .padding(16)
      }
    }
    .navigationBarHidden(true)
    .safeAreaInset(edge: .top) {
      detailChrome
    }
    .sheet(isPresented: $showOptimizedRoms) {
      OptimizedRomsInfoView()
    }
    .onAppear {
      settings.reloadSkinsFlag()
      if category == .controllers { InputHaptics.prepare() }
    }
  }

  private var detailChrome: some View {
    HStack(spacing: 12) {
      Button(action: onBack) {
        Image(systemName: "chevron.left")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(CETheme.accent)
          .frame(width: 36, height: 36)
          .background(CETheme.card, in: Circle())
          .overlay(Circle().stroke(CETheme.border, lineWidth: 1))
      }
      Image(systemName: category.systemImage)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
        .background(category.tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      Text(category.title)
        .font(CETheme.sans(18, weight: .bold))
        .foregroundStyle(CETheme.text)
      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.top, 10)
    .padding(.bottom, 12)
    .background(CETheme.elevated)
    .overlay(alignment: .bottom) {
      Rectangle().fill(CETheme.border).frame(height: 1)
    }
  }

  private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) {
      content()
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
  }

  private func toggleRow(
    title: String,
    subtitle: String,
    systemImage: String,
    isOn: Binding<Bool>
  ) -> some View {
    Toggle(isOn: Binding(
      get: { isOn.wrappedValue },
      set: { newValue in
        isOn.wrappedValue = newValue
        if title == "Touch Haptics", newValue {
          InputHaptics.buttonPress()
        }
      }
    )) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(CETheme.accent)
          .frame(width: 22, height: 22)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(CETheme.text)
          Text(subtitle)
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .tint(CETheme.accent)
  }

  private func cycleRow(
    title: String,
    value: String,
    subtitle: String,
    systemImage: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(enabled ? CETheme.accent : CETheme.muted.opacity(0.4))
          .frame(width: 22, height: 22)
          .padding(.top, 2)
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(title)
              .font(CETheme.sans(15, weight: .semibold))
              .foregroundStyle(enabled ? CETheme.text : CETheme.muted)
            Spacer()
            Text(value)
              .font(CETheme.sans(13, weight: .medium))
              .foregroundStyle(CETheme.muted)
          }
          Text(subtitle)
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
        }
      }
      .padding(.vertical, 4)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.55)
  }

  private func infoRow(title: String, value: String) -> some View {
    HStack {
      Text(title)
        .font(CETheme.sans(15, weight: .medium))
        .foregroundStyle(CETheme.text)
      Spacer()
      Text(value)
        .font(CETheme.mono(13))
        .foregroundStyle(CETheme.muted)
    }
    .padding(.vertical, 6)
  }

  private func aboutSectionLabel(_ title: String) -> some View {
    Text(title.uppercased())
      .font(CETheme.sans(11, weight: .semibold))
      .tracking(0.8)
      .foregroundStyle(CETheme.muted)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
      .padding(.top, 8)
  }

  private func creditRow(title: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(CETheme.sans(15, weight: .semibold))
        .foregroundStyle(CETheme.text)
      Text(body)
        .font(CETheme.sans(12))
        .foregroundStyle(CETheme.muted)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
  }

  private func hint(_ text: String) -> some View {
    Text(text)
      .font(CETheme.sans(12))
      .foregroundStyle(CETheme.muted)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
  }

  private var appBuild: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
  }
}

/// PokeDaisy Display Options › Shaders page.
struct ShadersSettingsView: View {
  @EnvironmentObject private var settings: AppSettings
  var onBack: () -> Void

  var body: some View {
    ZStack {
      CETheme.bg.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 12) {
          VStack(spacing: 0) {
            tapRow("Filter", settings.screenFilter.title, "LCD, CRT, scanlines, LCD Paper") {
              settings.screenFilter.cycle()
            }
            Divider().background(CETheme.border)
            tapRow(
              "Grid",
              settings.gridStrength.title,
              "Strength for LCD / LCD Paper",
              enabled: settings.screenFilter.hasGrid
            ) {
              settings.gridStrength.cycle()
            }
            Divider().background(CETheme.border)
            tapRow("Smoothing", settings.smoothing.title, "Softer edges (interpolation)") {
              settings.smoothing.cycle()
            }
            Divider().background(CETheme.border)
            toggle("GBA Colors", "Darker, less saturated LCD palette", $settings.gbaColors)
            Divider().background(CETheme.border)
            toggle("Unlit Screen", "Reflective grey-green backing + soft shadows — original GBA look", $settings.unlitScreen)
          }
          .padding(14)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
          .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))

          Text("Filters stack with GBA Colors and Unlit. Try Unlit + LCD together.")
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .padding(16)
      }
    }
    .navigationBarHidden(true)
    .safeAreaInset(edge: .top) {
      HStack(spacing: 12) {
        Button(action: onBack) {
          Image(systemName: "chevron.left")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(CETheme.accent)
            .frame(width: 36, height: 36)
            .background(CETheme.card, in: Circle())
            .overlay(Circle().stroke(CETheme.border, lineWidth: 1))
        }
        Text("Shaders")
          .font(CETheme.sans(18, weight: .bold))
          .foregroundStyle(CETheme.text)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 10)
      .padding(.bottom, 12)
      .background(CETheme.elevated)
      .overlay(alignment: .bottom) { Rectangle().fill(CETheme.border).frame(height: 1) }
    }
  }

  private func tapRow(_ title: String, _ value: String, _ subtitle: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(enabled ? CETheme.text : CETheme.muted)
          Text(subtitle)
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
        }
        Spacer()
        Text(value)
          .font(CETheme.sans(13, weight: .medium))
          .foregroundStyle(CETheme.muted)
      }
      .padding(.vertical, 8)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.45)
  }

  private func toggle(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
    Toggle(isOn: binding) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(CETheme.text)
        Text(subtitle)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .tint(CETheme.accent)
    .padding(.vertical, 6)
  }
}

/// SteamGridDB API key (Keychain) — paste from steamgriddb.com profile preferences.
struct SteamGridDBSettingsCard: View {
  @State private var keyDraft = ""
  @State private var hasKey = false
  @State private var username: String?
  @State private var status = ""
  @State private var loggedIn = false
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: loggedIn ? "checkmark.seal.fill" : "globe")
          .foregroundStyle(loggedIn ? Color(red: 0.55, green: 0.85, blue: 0.55) : CETheme.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("SteamGridDB")
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(CETheme.text)
          if loggedIn, let username {
            Text("Logged in as \(username)")
              .font(CETheme.sans(12, weight: .medium))
              .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.55))
          } else if hasKey {
            Text("API key saved — tap Test to verify")
              .font(CETheme.sans(12))
              .foregroundStyle(CETheme.muted)
          } else {
            Text("No API key yet")
              .font(CETheme.sans(12))
              .foregroundStyle(CETheme.muted)
          }
        }
        Spacer()
      }

      if loggedIn, let username {
        HStack(spacing: 8) {
          Image(systemName: "person.crop.circle.fill")
            .foregroundStyle(CETheme.crystal)
          Text("Successfully logged in")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(CETheme.text)
          Text("·")
            .foregroundStyle(CETheme.muted)
          Text(username)
            .font(CETheme.sans(13, weight: .bold))
            .foregroundStyle(CETheme.crystal)
          Spacer()
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.18, blue: 0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.30, green: 0.45, blue: 0.30), lineWidth: 1))
      }

      SecureField("Paste API key", text: $keyDraft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(CETheme.mono(13))
        .foregroundStyle(CETheme.text)
        .padding(12)
        .background(CETheme.hover, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CETheme.border, lineWidth: 1))

      HStack(spacing: 10) {
        Button {
          Task { await saveKey() }
        } label: {
          Text(busy ? "…" : "Save & Log In")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(CETheme.crystal, in: Capsule())
        }
        .disabled(busy || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        Button {
          Task { await testKey() }
        } label: {
          Text("Test")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(CETheme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(CETheme.hover, in: Capsule())
            .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
        }
        .disabled(busy || !hasKey)

        if hasKey {
          Button("Clear") {
            Task {
              await SteamGridDBClient.shared.setAPIKey(nil)
              hasKey = false
              loggedIn = false
              username = nil
              keyDraft = ""
              status = "Logged out"
            }
          }
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.muted)
        }
      }

      Link("Get a free API key", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
        .font(CETheme.sans(12, weight: .semibold))
        .foregroundStyle(CETheme.crystal)

      if !status.isEmpty {
        Text(status)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
      }
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
    .task { await refreshState(autoLogin: true) }
  }

  private func refreshState(autoLogin: Bool) async {
    hasKey = await SteamGridDBClient.shared.hasAPIKey()
    username = await SteamGridDBClient.shared.cachedUsername()
    loggedIn = hasKey && username != nil
    if autoLogin, hasKey, username == nil {
      await testKey()
    }
  }

  private func saveKey() async {
    busy = true
    defer { busy = false }
    await SteamGridDBClient.shared.setAPIKey(keyDraft)
    hasKey = await SteamGridDBClient.shared.hasAPIKey()
    if hasKey {
      keyDraft = ""
      await testKey()
    } else {
      status = "Key was empty"
      loggedIn = false
      username = nil
    }
  }

  private func testKey() async {
    busy = true
    defer { busy = false }
    do {
      let profile = try await SteamGridDBClient.shared.login()
      username = profile.name
      loggedIn = true
      hasKey = true
      status = "Successfully logged in as \(profile.name)"
    } catch {
      loggedIn = false
      username = nil
      status = error.localizedDescription
    }
  }
}

struct LibraryFontSettingsCard: View {
  @ObservedObject private var fonts = LibraryFontStore.shared
  @State private var showImporter = false
  @State private var importError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("LIBRARY FONT")
        .font(CETheme.sans(11, weight: .semibold))
        .foregroundStyle(CETheme.muted)

      Text("Game titles")
        .font(fonts.titleFont(size: fonts.titleSize(base: 16), weight: .bold))
        .foregroundStyle(CETheme.text)
        .lineLimit(1)
        .minimumScaleFactor(0.5)

      ForEach(LibraryFontChoice.allCases) { choice in
        Button {
          fonts.choice = choice
        } label: {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(choice.title)
                .font(CETheme.sans(14, weight: .semibold))
                .foregroundStyle(CETheme.text)
              Text(choice.subtitle)
                .font(CETheme.sans(11))
                .foregroundStyle(CETheme.muted)
            }
            Spacer()
            if fonts.choice == choice {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(CETheme.crystal)
            }
          }
          .padding(12)
          .background(fonts.choice == choice ? CETheme.hover : CETheme.card.opacity(0.001), in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(fonts.choice == choice ? CETheme.border : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }

      Button { showImporter = true } label: {
        Label("Import custom font…", systemImage: "doc.badge.plus")
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.accent)
      }

      if let name = fonts.customFontName {
        Text("Custom: \(name)")
          .font(CETheme.mono(11))
          .foregroundStyle(CETheme.muted)
      }
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: UTType.fontFiles,
      allowsMultipleSelection: false
    ) { result in
      switch result {
      case .success(let urls):
        guard let url = urls.first else { return }
        do {
          let name = try fonts.importFont(from: url)
          importError = nil
          _ = name
        } catch {
          importError = error.localizedDescription
        }
      case .failure(let err):
        importError = err.localizedDescription
      }
    }
    .alert("Font", isPresented: Binding(
      get: { importError != nil },
      set: { if !$0 { importError = nil } }
    )) {
      Button("OK", role: .cancel) { importError = nil }
    } message: {
      Text(importError ?? "")
    }
  }
}

// MARK: - Optimized ROMs catalog

struct OptimizedRomsInfoView: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        CETheme.bg.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            headerCard

            ForEach(OptimizedRomCatalog.byFamily, id: \.0) { family, entries in
              familySection(family, entries: entries)
            }
          }
          .padding(16)
          .padding(.bottom, 24)
        }
      }
      .navigationTitle("Optimized ROMs")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
            .font(CETheme.sans(15, weight: .semibold))
        }
      }
    }
    .preferredColorScheme(.dark)
  }

  private var headerCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Image(systemName: "sparkles")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(CETheme.crystal)
        Text("PocketDex play stack")
          .font(CETheme.sans(16, weight: .bold))
          .foregroundStyle(CETheme.text)
      }
      Text("These games have Expand / zoom, companion reads, shaders, and Save Editor wired for PocketDex. Set Aspect → Expand in-game to use ultrawide zoom.")
        .font(CETheme.sans(13))
        .foregroundStyle(CETheme.muted)
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 8) {
        legendChip("Expand / Zoom", color: CETheme.crystal)
        legendChip("Companion · Island", color: Color(red: 0.55, green: 0.72, blue: 0.55))
        legendChip("Save Editor", color: Color(red: 0.72, green: 0.58, blue: 0.42))
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [CETheme.card, CETheme.elevated.opacity(0.9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ),
      in: RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous)
        .stroke(CETheme.border, lineWidth: 1)
    )
  }

  private func legendChip(_ title: String, color: Color) -> some View {
    Text(title)
      .font(CETheme.mono(9))
      .foregroundStyle(color)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(color.opacity(0.12), in: Capsule())
      .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
  }

  private func familySection(_ family: OptimizedRomFamily, entries: [OptimizedRomEntry]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(family.rawValue.uppercased())
          .font(CETheme.mono(11))
          .foregroundStyle(CETheme.crystal)
          .tracking(1.2)
        Text(family.blurb)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
      }
      .padding(.horizontal, 4)

      VStack(spacing: 0) {
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
          if index > 0 {
            Divider().background(CETheme.border)
          }
          romRow(entry)
        }
      }
      .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: CETheme.radius, style: .continuous)
          .stroke(CETheme.border, lineWidth: 1)
      )
    }
  }

  private func romRow(_ entry: OptimizedRomEntry) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(entry.title)
        .font(CETheme.sans(15, weight: .semibold))
        .foregroundStyle(CETheme.text)
      Text(entry.detail)
        .font(CETheme.sans(12))
        .foregroundStyle(CETheme.muted)
        .fixedSize(horizontal: false, vertical: true)
      FlowFeatureChips(labels: entry.features.labels)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Simple wrapping chip row without LazyVGrid stretch.
private struct FlowFeatureChips: View {
  let labels: [String]

  var body: some View {
    // Fixed wrap via flexible HStacks of chips — enough for ≤4 features.
    HStack(spacing: 6) {
      ForEach(labels, id: \.self) { label in
        Text(label)
          .font(CETheme.mono(9))
          .foregroundStyle(CETheme.text.opacity(0.9))
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(CETheme.hover, in: Capsule())
          .overlay(Capsule().stroke(CETheme.border, lineWidth: 1))
      }
      Spacer(minLength: 0)
    }
  }
}

// MARK: - Google Drive

private struct GoogleDriveSettingsCard: View {
  @EnvironmentObject private var settings: AppSettings
  @ObservedObject private var auth = GoogleDriveAuth.shared
  @ObservedObject private var sync = GoogleDriveSync.shared
  @State private var busy = false
  @State private var errorText: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: "externaldrive.fill.badge.icloud")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(CETheme.crystal)
        Text("Google Drive")
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(CETheme.text)
      }

      if auth.isSignedIn {
        Text(auth.email.map { "Signed in as \($0)" } ?? "Signed in")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.crystal)
      } else {
        Text("Sign in with your Google account to back up and restore ROMs, saves, states, scraped covers, and companion pins.")
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let status = auth.statusMessage ?? sync.lastResult {
        Text(status)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      Toggle(isOn: $settings.googleDriveAutoSync) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Auto-sync")
            .font(CETheme.sans(14, weight: .semibold))
            .foregroundStyle(CETheme.text)
          Text("Sync on launch, after sign-in, and when you import ROMs")
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
        }
      }
      .tint(CETheme.accent)

      HStack(spacing: 10) {
        if auth.isSignedIn {
          Button {
            Task {
              busy = true
              await sync.syncNow()
              busy = false
            }
          } label: {
            Label(sync.isSyncing || busy ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
              .font(CETheme.sans(13, weight: .semibold))
          }
          .disabled(sync.isSyncing || busy)
          .buttonStyle(.borderedProminent)
          .tint(CETheme.accent)

          Button("Sign Out") {
            auth.signOut()
          }
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.muted)
        } else {
          Button {
            Task {
              busy = true
              errorText = nil
              do {
                try await auth.signIn()
                await sync.syncNow()
              } catch {
                errorText = error.localizedDescription
              }
              busy = false
            }
          } label: {
            Label(busy ? "Signing in…" : "Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
              .font(CETheme.sans(13, weight: .semibold))
          }
          .disabled(busy)
          .buttonStyle(.borderedProminent)
          .tint(CETheme.accent)
        }
      }

      if let errorText {
        Text(errorText)
          .font(CETheme.sans(12))
          .foregroundStyle(Color(red: 0.95, green: 0.35, blue: 0.35))
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
  }
}
