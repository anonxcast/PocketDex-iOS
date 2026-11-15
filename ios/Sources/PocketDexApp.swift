import SwiftUI

@main
struct PocketDexApp: App {
  @StateObject private var engine = EmulatorEngine()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(engine)
        .environmentObject(AppSettings.shared)
        .preferredColorScheme(.dark)
    }
  }
}

enum AppRoute: Hashable {
  case game(RomItem)
  case rom(RomItem)
  case settings
}

struct RootView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @EnvironmentObject private var settings: AppSettings
  @State private var path = NavigationPath()
  @State private var didLaunchCloudSync = false

  var body: some View {
    NavigationStack(path: $path) {
      LibraryView(
        onPlay: { rom in
          // Resume if this ROM is paused; otherwise load (replaces any other session).
          engine.play(rom: rom)
          path.append(AppRoute.rom(rom))
        },
        onOpenGame: { rom in
          path.append(AppRoute.game(rom))
        }
      )
      .navigationDestination(for: AppRoute.self) { route in
        switch route {
        case .game(let rom):
          GameDetailView(rom: rom) { playRom in
            engine.play(rom: playRom)
            path.append(AppRoute.rom(playRom))
          }
        case .rom(let rom):
          PlayView(rom: rom)
        case .settings:
          SettingsView()
        }
      }
    }
    .task {
      guard !didLaunchCloudSync else { return }
      didLaunchCloudSync = true
      guard settings.googleDriveAutoSync, GoogleDriveAuth.shared.isSignedIn else { return }
      await GoogleDriveSync.shared.syncNow()
    }
  }
}
