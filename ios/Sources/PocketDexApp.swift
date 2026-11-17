import SwiftUI

@main
struct PocketDexApp: App {
  @StateObject private var engine = EmulatorEngine()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(engine)
        .environmentObject(AppSettings.shared)
    }
  }
}

enum AppRoute: Hashable {
  case game(RomItem)
  case rom(RomItem)
  case saveEditor(RomItem)
  case settings
}

struct RootView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @EnvironmentObject private var settings: AppSettings
  @State private var path = NavigationPath()
  @State private var didLaunchCloudSync = false

  private var engineLoadedStem: String? {
    engine.loadedRomURL?.deletingPathExtension().lastPathComponent
  }

  var body: some View {
    NavigationStack(path: $path) {
      LibraryView(
        onPlay: { rom in
          // Navigate first — never wait on emu boot (main used to freeze on sync).
          path.append(AppRoute.rom(rom))
          engine.play(rom: rom)
        },
        onOpenGame: { rom in
          path.append(AppRoute.game(rom))
        },
        onEditSave: { rom in
          path.append(AppRoute.saveEditor(rom))
        }
      )
      .navigationDestination(for: AppRoute.self) { route in
        switch route {
        case .game(let rom):
          GameDetailView(
            rom: rom,
            onPlay: { playRom in
              path.append(AppRoute.rom(playRom))
              engine.play(rom: playRom)
            },
            onEditSave: { editRom in
              path.append(AppRoute.saveEditor(editRom))
            }
          )
        case .rom(let rom):
          PlayView(rom: rom)
        case .saveEditor(let rom):
          SaveEditorHostView(rom: rom, engineLoadedStem: engineLoadedStem)
        case .settings:
          SettingsView()
        }
      }
    }
    .background(CETheme.bg.ignoresSafeArea())
    .preferredColorScheme(settings.appearanceMode.preferredColorScheme)
    .task {
      guard !didLaunchCloudSync else { return }
      didLaunchCloudSync = true
      guard settings.googleDriveAutoSync, GoogleDriveAuth.shared.isSignedIn else { return }
      await GoogleDriveSync.shared.syncNow()
    }
  }
}
