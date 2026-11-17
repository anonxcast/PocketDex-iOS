import Foundation
import QuartzCore
import SwiftUI
import UIKit

/// App-wide preferences (Delta-style categories: Controls, Audio, Display, Skins).
@MainActor
final class AppSettings: ObservableObject {
  static let shared = AppSettings()

  private enum Key {
    static let haptics = "settings.hapticsEnabled"
    /// Softer D-pad path for phones that hitch while sliding (iPhone 16). Off = Duo-responsive.
    static let dpadLite = "settings.dpadLiteMode"
    static let audio = "settings.audioEnabled"
    static let keepAwake = "settings.keepScreenAwake"
    static let skins = "deltaSkinsEnabled"
    static let aspect = "settings.gameAspect"
    static let zoom = "settings.zoomLevel"
    static let autoZoom = "settings.autoZoomIn"
    static let statusBar = "settings.statusBarMode"
    static let showFps = "settings.showFps"
    static let filter = "settings.screenFilter"
    static let grid = "settings.gridStrength"
    static let smoothing = "settings.smoothing"
    static let gbaColors = "settings.gbaColors"
    static let unlit = "settings.unlitScreen"
    static let folder = "settings.folderLayout"
    static let dsLayout = "settings.dsLayout"
    static let driveAutoSync = "settings.googleDriveAutoSync"
    static let libraryOpen = "settings.libraryOpenMode"
    static let appearance = "settings.appearanceMode"
  }

  @Published var hapticsEnabled: Bool {
    didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Key.haptics) }
  }

  /// When on: softer D-pad ticks + pad glow once per frame (helps iPhone 16).
  /// When off (default): full medium haptics and instant pad glow (Duo).
  @Published var dpadLiteMode: Bool {
    didSet { UserDefaults.standard.set(dpadLiteMode, forKey: Key.dpadLite) }
  }

  @Published var audioEnabled: Bool {
    didSet { UserDefaults.standard.set(audioEnabled, forKey: Key.audio) }
  }

  @Published var keepScreenAwake: Bool {
    didSet {
      UserDefaults.standard.set(keepScreenAwake, forKey: Key.keepAwake)
      applyIdleTimer()
    }
  }

  @Published var skinsEnabled: Bool {
    didSet {
      // Keep the manager flag in sync; do not clear per-console selections so
      // re-enabling skins restores the last checked skin.
      DeltaSkinManager.isSkinEnabled = skinsEnabled
    }
  }

  // MARK: Display (PokeDaisy Screen / Display Options)

  @Published var gameAspect: GameAspectMode {
    didSet { UserDefaults.standard.set(gameAspect.rawValue, forKey: Key.aspect) }
  }

  @Published var zoomLevel: ZoomLevel {
    didSet { UserDefaults.standard.set(zoomLevel.rawValue, forKey: Key.zoom) }
  }

  @Published var autoZoomIn: Bool {
    didSet { UserDefaults.standard.set(autoZoomIn, forKey: Key.autoZoom) }
  }

  @Published var statusBarMode: StatusBarMode {
    didSet { UserDefaults.standard.set(statusBarMode.rawValue, forKey: Key.statusBar) }
  }

  /// Play top-bar FPS readout (Companion › Settings).
  @Published var showFps: Bool {
    didSet { UserDefaults.standard.set(showFps, forKey: Key.showFps) }
  }

  @Published var screenFilter: ScreenFilter {
    didSet { UserDefaults.standard.set(screenFilter.rawValue, forKey: Key.filter) }
  }

  @Published var gridStrength: GridStrength {
    didSet { UserDefaults.standard.set(gridStrength.rawValue, forKey: Key.grid) }
  }

  @Published var smoothing: SmoothingMode {
    didSet { UserDefaults.standard.set(smoothing.rawValue, forKey: Key.smoothing) }
  }

  @Published var gbaColors: Bool {
    didSet { UserDefaults.standard.set(gbaColors, forKey: Key.gbaColors) }
  }

  @Published var unlitScreen: Bool {
    didSet { UserDefaults.standard.set(unlitScreen, forKey: Key.unlit) }
  }

  /// Book / tabletop play: game on the top pane, controls under the fold (Delta Duo style).
  @Published var folderLayout: Bool {
    didSet { UserDefaults.standard.set(folderLayout, forKey: Key.folder) }
  }

  /// DS LAYOUT (PokeDaisy): One Screen floats the touch LCD; Stacked shows both.
  @Published var dsLayout: DsLayoutMode {
    didSet { UserDefaults.standard.set(dsLayout.rawValue, forKey: Key.dsLayout) }
  }

  /// After import / when opening the library, push/pull Drive if signed in.
  @Published var googleDriveAutoSync: Bool {
    didSet { UserDefaults.standard.set(googleDriveAutoSync, forKey: Key.driveAutoSync) }
  }

  /// Tap a library game → full game page (default) or the quick Play bubble.
  @Published var libraryOpenMode: LibraryOpenMode {
    didSet { UserDefaults.standard.set(libraryOpenMode.rawValue, forKey: Key.libraryOpen) }
  }

  /// Library / Settings chrome: System (default), Light, or Dark.
  @Published var appearanceMode: AppAppearanceMode {
    didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: Key.appearance) }
  }

  private init() {
    let d = UserDefaults.standard
    hapticsEnabled = d.object(forKey: Key.haptics) as? Bool ?? true
    dpadLiteMode = d.object(forKey: Key.dpadLite) as? Bool ?? false
    audioEnabled = d.object(forKey: Key.audio) as? Bool ?? true
    keepScreenAwake = d.object(forKey: Key.keepAwake) as? Bool ?? true
    skinsEnabled = DeltaSkinManager.isSkinEnabled
    // Default Expand (not Original). A reinstall wiped prefs earlier and silently
    // disabled Expand / zoom / auto-zoom for every ROM.
    gameAspect = GameAspectMode(rawValue: d.string(forKey: Key.aspect) ?? "") ?? .expand
    zoomLevel = ZoomLevel(rawValue: d.object(forKey: Key.zoom) as? Int ?? 0) ?? .x1
    autoZoomIn = d.object(forKey: Key.autoZoom) as? Bool ?? true
    statusBarMode = StatusBarMode(rawValue: d.string(forKey: Key.statusBar) ?? "") ?? .off
    showFps = d.object(forKey: Key.showFps) as? Bool ?? true
    screenFilter = ScreenFilter(rawValue: d.string(forKey: Key.filter) ?? "") ?? .none
    gridStrength = GridStrength(rawValue: d.string(forKey: Key.grid) ?? "") ?? .medium
    smoothing = SmoothingMode(rawValue: d.string(forKey: Key.smoothing) ?? "") ?? .off
    gbaColors = d.object(forKey: Key.gbaColors) as? Bool ?? false
    unlitScreen = d.object(forKey: Key.unlit) as? Bool ?? false
    // Off by default; Duo hinge auto-splits. Toggle forces a book split when flat.
    folderLayout = d.object(forKey: Key.folder) as? Bool ?? false
    dsLayout = DsLayoutMode(rawValue: d.string(forKey: Key.dsLayout) ?? "") ?? .oneScreen
    googleDriveAutoSync = d.object(forKey: Key.driveAutoSync) as? Bool ?? true
    libraryOpenMode = LibraryOpenMode(rawValue: d.string(forKey: Key.libraryOpen) ?? "") ?? .gamePage
    appearanceMode = AppAppearanceMode(rawValue: d.string(forKey: Key.appearance) ?? "") ?? .system

    // One-shot: restore the play stack after prefs reset to Original.
    let migrateKey = "settings.restoredExpandPlayStack_v014"
    if d.object(forKey: migrateKey) == nil {
      gameAspect = .expand
      autoZoomIn = true
      d.set(true, forKey: migrateKey)
      d.set(GameAspectMode.expand.rawValue, forKey: Key.aspect)
      d.set(true, forKey: Key.autoZoom)
    }
  }

  func reloadSkinsFlag() {
    skinsEnabled = DeltaSkinManager.isSkinEnabled
  }

  func applyIdleTimer(playing: Bool = false) {
    UIApplication.shared.isIdleTimerDisabled = playing && keepScreenAwake
  }
}

enum InputHaptics {
  private static let buttonGen = UIImpactFeedbackGenerator(style: .medium)
  private static let dpadFullGen = UIImpactFeedbackGenerator(style: .medium)
  private static let dpadLiteGen = UIImpactFeedbackGenerator(style: .soft)
  private static let selectionGen = UISelectionFeedbackGenerator()
  private static var lastDpadHapticAt: CFTimeInterval = 0

  static func prepare() {
    buttonGen.prepare()
    dpadFullGen.prepare()
    dpadLiteGen.prepare()
    selectionGen.prepare()
  }

  @MainActor
  static func buttonPress() {
    guard AppSettings.shared.hapticsEnabled else { return }
    buttonGen.impactOccurred(intensity: 0.92)
    buttonGen.prepare()
  }

  @MainActor
  static func dpadChange() {
    guard AppSettings.shared.hapticsEnabled else { return }
    let lite = AppSettings.shared.dpadLiteMode
    let now = CACurrentMediaTime()
    // Full (Duo): every direction change. Lite (iPhone 16): ~22 Hz cap, no re-prepare.
    let minInterval: CFTimeInterval = lite ? 0.045 : 0.012
    guard now - lastDpadHapticAt >= minInterval else { return }
    lastDpadHapticAt = now
    if lite {
      dpadLiteGen.impactOccurred(intensity: 0.62)
    } else {
      dpadFullGen.impactOccurred(intensity: 0.72)
      dpadFullGen.prepare()
    }
  }

  /// Light tick for library rail / tab changes (GB → GBC → GBA…).
  @MainActor
  static func selectionChange() {
    guard AppSettings.shared.hapticsEnabled else { return }
    selectionGen.selectionChanged()
    selectionGen.prepare()
  }
}
