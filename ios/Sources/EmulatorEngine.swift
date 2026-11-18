import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class EmulatorEngine: ObservableObject {
  @Published private(set) var isRunning = false
  /// Core is loaded but the run loop is stopped (Back from play). Tap the same game to resume.
  @Published private(set) var isPaused = false
  /// ROM currently loaded in the core (set while running or paused).
  @Published private(set) var loadedRomURL: URL?
  /// Stable identity for pause/resume matching (`RomItem.sessionKey`).
  @Published private(set) var loadedRomKey: String?
  /// Last presented frame (screenshots / freeze). Not `@Published` — CALayer presents.
  private(set) var frameImage: CGImage?
  /// NDS touch-LCD when Expand shows a wide top only.
  private(set) var ndsNativeFrame: CGImage?
  /// CALayer LCD presenters — updates do not invalidate PlayView’s SwiftUI tree.
  let lcdTop = LCDPresenter()
  let lcdBottom = LCDPresenter()
  /// Separate hosts for the ONE SCREEN touch popup (one presenter → one CALayer).
  let lcdTouchTop = LCDPresenter()
  let lcdTouchBottom = LCDPresenter()
  @Published private(set) var statusText = "Idle"
  /// Mirrored on `CompanionLiveStore` so HUD/drawer updates do not rebuild PlayView.
  var companionHint: String {
    get { CompanionLiveStore.shared.hint }
    set { CompanionLiveStore.shared.setHint(newValue) }
  }
  var companion: CompanionSnapshot? {
    get { CompanionLiveStore.shared.snapshot }
    set { CompanionLiveStore.shared.setSnapshot(newValue) }
  }
  var companionGameName: String? {
    get { CompanionLiveStore.shared.gameName }
    set { CompanionLiveStore.shared.setGameName(newValue) }
  }
  var companionMatch: Gen3Config.MatchKind? {
    get { CompanionLiveStore.shared.match }
    set { CompanionLiveStore.shared.setMatch(newValue) }
  }

  private var displayLink: CADisplayLink?
  private var keyMask: UInt32 = 0
  private var dpadMask: UInt32 = 0
  private var buttonMask: UInt32 = 0
  /// Last absolute skin mask — used for haptic edge detection.
  private var lastSkinMask: UInt32 = 0
  private let emuQueue = DispatchQueue(label: "com.anonxcast.pocketdex.emu", qos: .userInteractive)
  private let dpadBits: UInt32 = (1 << 4) | (1 << 5) | (1 << 6) | (1 << 7)
  private let audio = EmulatorAudio()

  // Companion sampling: detected once after load, sampled ~4 Hz on emuQueue.
  private var companionSampler: (any CompanionSampling)?
  private var companionFrameCount = 0
  private var companionGeneration = 0
  private let companionSampleEveryFrames = 15
  /// NDS frames are heavier (dual LCD); keep companion light so present stays smooth.
  private let companionSampleEveryFramesNDS = 60
  /// When the companion drawer is open, sample less often so SwiftUI redraws
  /// don't stall CADisplayLink (which underruns audio and sounds slow/poppy).
  var companionDrawerOpen = false
  /// Set while Exit Completely tears down — PlayView.onDisappear must not pause.
  private(set) var isQuitting = false
  private var pendingQuitSave: (
    statePath: URL,
    thumbPath: URL?,
    artworkKey: String?,
    thumbCG: CGImage?
  )?
  private var lastAudioEnabled: Bool?
  /// Last NDS field bits — used to skip unused touch-LCD copies next tick.
  private var lastNdsFieldBits: Int32 = 0
  /// Skip CGImage publish when the last emu tick ran long (audio already drained).
  private var skipPresentStreak = 0
  /// Never emuQueue.sync from CADisplayLink — a long NDS frame froze Play.
  private var frameInFlight = false
  private var frameInFlightSince = 0.0
  /// Display-link ticks that arrived while emu was busy — drained as audio catch-up.
  private var pendingEmuTicks = 0
  private var fpsWindowStart = CACurrentMediaTime()
  private var fpsWindowCount = 0
  /// Gen 5 (IRA/IRB/IRD/IRE) — Expand caps depend on JIT.
  private var ndsGen5Session = false
  private var ndsJitSession = false
  /// Cached on the emu queue — never call pk_ios_* from main for these (g_lock stalls Play).
  private var cachedCoreW = 0
  private var cachedCoreH = 0
  private var cachedPlatform = 0
  private var cachedWideScene = 0

  /// Last play-area size used to compute the WIDE window (points).
  private var lastWideDisplay: CGSize = .zero
  /// Portrait / Duo cover: Expand only left/right (no top/bottom fill bars).
  private var wideSidesOnly = false
  /// Eased Expand zoom (PokeDaisy WideCamera tween).
  private let wideZoom = WideZoomTween()
  private var lastWideApplied: (x: Int32, y: Int32, w: Int32, h: Int32)?
  @Published private(set) var wideSupported = false
  /// How many distinct Expand zoom steps the current play area supports (1…4).
  @Published private(set) var zoomStepCount = 1
  /// Live zoom label (“1× (close)”, “2× out”, …) from actual WIDE math.
  @Published private(set) var zoomStepTitle = "1× (close)"
  /// Expand placement pushed to CALayer only — not `@Published` (tween floats
  /// republishing this every frame rebuilt PlayView and held GB ~45 FPS).
  private(set) var widePlacement: WideCameraMath.Placement?
  /// Emulation speed: 1× / 2× / 3× (extra frames per display tick).
  @Published private(set) var speedMultiplier: Int = 1
  /// FPS lives on `FpsBadge` (isolated chip) — never `@Published` here.
  var fps: Int { FpsBadge.shared.value }
  /// Brief HUD toast after quick save / load (“Saved”, “Loaded”, …).
  @Published private(set) var actionToast: String?
  /// Top-chrome auto-save banner text (animated in / out).
  @Published private(set) var autoSaveNotice: String?
  /// True when any numbered save state exists for the loaded ROM.
  @Published private(set) var hasAnySaveState = false
  /// DS LAYOUT: game wants its touch screen floated in (PokeDaisy ONE SCREEN).
  @Published private(set) var dsTouchWanted = false
  /// Dual-content menu page (party summary, bag, …): show both LCDs side by side.
  @Published private(set) var dsMenuScreen = false
  /// Touch LCD is one solid colour (fade / blank) — hide the popup contents.
  @Published private(set) var dsTouchBlank = false
  /// Triple-buffered present slots (stable pointers for no-copy CGImage).
  private let presentRing = FramePresentRing(slots: 3)
  private var ndsBottomScratch: [UInt8] = []
  /// Shader path still needs a Swift Array.
  private var shaderScratch: [UInt8] = []
  private var toastClearTask: Task<Void, Never>?
  private var autoSaveNoticeTask: Task<Void, Never>?
  private var autoSaveTimer: Timer?
  private var wasInBattle = false
  private var autoSaveInFlight = false
  /// Periodic auto-save while playing (~3 minutes).
  private static let autoSaveInterval: TimeInterval = 180

  // MARK: DS touch-wanted settle (PokeDaisy EmulatorEngine)
  private var dsTouchFrames = 0
  private var dsMenuFrames = 0
  private var dsDarkBefore = false
  private var dsFadeSeen = false
  private var dsFadeFrames = 0
  private var dsLitFrames = 0
  private static let dsTouchOnFrames = 2
  private static let dsTouchOffFrames = 6
  private static let dsFadeWaitFrames = 90
  private static let dsFadeLitFrames = 12
  private static let fieldTouch: Int32 = 2048
  private static let fieldMenu: Int32 = 512
  private static let fieldBattle: Int32 = 4
  private static let fieldTouchOnly: Int32 = 8192
  private static let fieldTopOnly: Int32 = 131_072
  private static let fieldTouchFades: Int32 = 16_384
  private static let fieldTouchBattleMenu: Int32 = 4096
  private static let fieldDarkTop: Int32 = 32_768
  private static let fieldDarkBottom: Int32 = 65_536

  private func romTitle(for url: URL) -> String {
    url.deletingPathExtension().lastPathComponent
  }

  /// Resume a paused session for this ROM, or load fresh (replacing any other session).
  /// Matching uses `RomItem.sessionKey` so Unicode / path variants of the same file still resume.
  func play(rom: RomItem) {
    RecentlyPlayedStore.shared.markPlayed(rom)
    let key = rom.sessionKey
    if loadedRomKey == key, isPaused {
      resume()
      return
    }
    if loadedRomKey == key, isRunning {
      return
    }
    load(rom: rom)
  }

  func isPausedRom(_ rom: RomItem) -> Bool {
    isPaused && loadedRomKey == rom.sessionKey
  }

  func load(rom: RomItem) {
    load(romURL: rom.url, key: rom.sessionKey)
  }

  func load(romURL: URL, key: String? = nil) {
    let sessionKey = key ?? {
      let stem = romURL.deletingPathExtension().lastPathComponent
        .precomposedStringWithCanonicalMapping
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
      let size = (try? romURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return "\(stem)_\(size)"
    }()

    let save = RomLibrary.savePath(forRom: romURL)
    let romPath = romURL.path
    let savePath = save.path
    let title = romTitle(for: romURL)

    // Never emuQueue.sync from main — a stuck NDS frame (Expand/JIT) froze Play forever.
    tearDownSessionUI(clearIdentity: true)
    statusText = "Loading \(title)…"
    companionHint = "Loading ROM…"

    let generation = companionGeneration
    frameInFlight = false
    frameInFlightSince = 0
    let q = emuQueue
    // Plain async (not barrier): a wedged prior frame must not block boot forever.
    q.async { [weak self] in
      pk_ios_deinit()
      let ok = romPath.withCString { rp in
        savePath.withCString { sp in
          pk_ios_init(rp, sp)
        }
      }
      Task { @MainActor [weak self] in
        guard let self else { return }
        // A newer load superseded this one — drop the result.
        guard self.companionGeneration == generation else { return }
        self.isRunning = ok
        self.isPaused = false
        self.loadedRomURL = ok ? romURL.standardizedFileURL : nil
        self.loadedRomKey = ok ? sessionKey : nil
        self.statusText = ok ? "Playing \(title)" : "Failed to load ROM"
        self.companionHint = ok
          ? "PocketDex companion is ready."
          : "Load a GB/GBC/GBA/NDS ROM to begin."
        self.frameInFlight = false
        if ok {
          self.wideSupported = pk_ios_wide_supported()
          self.cachedPlatform = Int(pk_ios_platform())
          self.cachedCoreW = Int(pk_ios_core_width())
          self.cachedCoreH = Int(pk_ios_core_height())
          self.cachedWideScene = Int(pk_ios_wide_scene())
          self.ndsGen5Session = false
          self.ndsJitSession = pk_ios_jit_ready() != 0
          self.speedMultiplier = 1
          self.refreshSaveStateFlag()
          self.configureCompanion()
          // Gen 5 Soft Expand uses the tighter no-JIT window until A64 JIT is safe.
          if self.cachedPlatform == 3, self.companionSampler is Gen5Sampler {
            self.ndsGen5Session = true
          }
          self.startLoop()
          if self.lastWideDisplay.width > 0 {
            self.updateWideView(forDisplay: self.lastWideDisplay)
          }
        }
      }
    }
  }

  /// Freeze emulation and return to the library without unloading the core.
  func pause() {
    guard loadedRomKey != nil, isRunning || isPaused else { return }
    // Stop the display link before any save — never call pk_ios_* on main while
    // a frame still holds g_lock (that froze Exit Completely).
    haltPlayLoop()
    if loadedRomKey != nil {
      writeAutoSave(showBanner: false)
    }
    // Release held inputs so nothing sticks across resume.
    buttonMask = 0
    dpadMask = 0
    keyMask = 0
    lastSkinMask = 0
    PadPressedStore.shared.clear()
    let q = emuQueue
    q.async(flags: .barrier) {
      pk_ios_set_keys(0)
      pk_ios_set_touch(false, 0, 0)
    }
    isRunning = false
    isPaused = true
    if let url = loadedRomURL {
      statusText = "Paused · \(romTitle(for: url))"
    } else {
      statusText = "Paused"
    }
  }

  /// Stop CADisplayLink + mute audio without blocking on AVAudioEngine / g_lock.
  private func haltPlayLoop() {
    stopAutoSaveTimer()
    displayLink?.invalidate()
    displayLink = nil
    frameInFlight = false
    pendingEmuTicks = 0
    audio.mute()
    AppSettings.shared.applyIdleTimer(playing: false)
  }

  /// Continue a paused session from the frozen frame.
  func resume() {
    guard isPaused, loadedRomURL != nil, loadedRomKey != nil else {
      if let url = loadedRomURL {
        load(romURL: url, key: loadedRomKey)
      }
      return
    }
    // Don't pk_ios_is_running() on main — g_lock can stall behind a long NDS frame.
    isPaused = false
    isRunning = true
    if let url = loadedRomURL {
      statusText = "Playing \(romTitle(for: url))"
    }
    refreshSaveStateFlag()
    startLoop()
    if lastWideDisplay.width > 0 {
      updateWideView(forDisplay: lastWideDisplay)
    }
  }

  /// Drive PokeDaisy WIDE / EXPAND: larger window = more map (not a UI stretch).
  /// Auto zoom eases in/out (WideZoomTween) so battle pull-in isn't a hard cut.
  /// `sidesOnly`: legacy width-only Expand (shrinks on-screen height while zooming —
  /// leave false so GB matches normal GBA auto-zoom).
  func updateWideView(forDisplay size: CGSize, sidesOnly: Bool? = nil) {
    lastWideDisplay = size
    if let sidesOnly { wideSidesOnly = sidesOnly }
    let sides = wideSidesOnly
    let settings = AppSettings.shared
    // No WIDE row / Aspect≠Expand: skip camera work (no zoom spam).
    guard isRunning, settings.gameAspect == .expand, wideSupported else {
      wideZoom.reset()
      if widePlacement != nil { widePlacement = nil }
      lcdTop.setExpandPlacement(nil)
      // Only clear native Expand once — every-tick clear starved the emu thread.
      if lastWideApplied != nil {
        lastWideApplied = nil
        let q = emuQueue
        q.async { pk_ios_set_wide_view(0, 0, 0, 0) }
      }
      return
    }
    // Use emu-thread caches only — never take g_lock on main (Play freeze).
    let fw = cachedCoreW
    let fh = cachedCoreH
    let isNds = cachedPlatform == 3
    let maxW: Int = {
      if !isNds { return WideCameraMath.maxViewW }
      if ndsGen5Session && !ndsJitSession { return WideCameraMath.ndsGen5NoJitMaxViewW }
      return WideCameraMath.ndsMaxViewW
    }()
    let maxH: Int = {
      if !isNds { return WideCameraMath.maxViewH }
      if ndsGen5Session && !ndsJitSession { return WideCameraMath.ndsGen5NoJitMaxViewH }
      return WideCameraMath.ndsMaxViewH
    }()
    // WideCamera math is in screen pixels (Android view size), not SwiftUI points.
    let px = WideCameraMath.pixels(fromPoints: size)
    if fw > 0, fh > 0, px.width > 0, px.height > 0 {
      let steps = WideCameraMath.levelCount(
        viewW: px.width, viewH: px.height, frameW: fw, frameH: fh,
        maxW: maxW, maxH: maxH, sidesOnly: sides
      )
      if zoomStepCount != steps { zoomStepCount = steps }
      let title = WideCameraMath.title(
        level: settings.zoomLevel.rawValue,
        displayPoints: size,
        frameW: fw,
        frameH: fh,
        maxW: maxW,
        maxH: maxH,
        sidesOnly: sides
      )
      if zoomStepTitle != title { zoomStepTitle = title }
      // Clamp stored zoom if this display supports fewer steps.
      if settings.zoomLevel.rawValue >= zoomStepCount {
        let clamped = ZoomLevel(rawValue: max(0, zoomStepCount - 1)) ?? .x1
        if settings.zoomLevel != clamped {
          settings.zoomLevel = clamped
        }
      }
    }
    guard fw > 0, fh > 0, px.width > 0, px.height > 0 else { return }

    let steps = WideCameraMath.levels(
      viewW: px.width, viewH: px.height, frameW: fw, frameH: fh,
      maxW: maxW, maxH: maxH, sidesOnly: sides
    )
    guard !steps.isEmpty else { return }

    let scene = cachedWideScene
    // Match PokeDaisy WideCamera: zoom from scene only (not wants_close — that folds TEXT in
    // even when AUTO ZOOM IN is off). FIELD stays out; TEXT respects the setting; OVERLAY/FADE hold.
    let wantsClose: Bool = {
      switch scene {
      case 0: return false // FIELD
      case 1: return settings.autoZoomIn // TEXT
      case 2, 5: return false // OVERLAY / FADE — hold
      default: return true // BATTLE / MENU / OFF
      }
    }()
    let holdZoom = (scene == 2 || scene == 5)

    let now = CACurrentMediaTime()
    let scale = wideZoom.tick(
      now: now,
      steps: steps,
      level: settings.zoomLevel.rawValue,
      wantsClose: wantsClose,
      holdZoom: holdZoom
    )

    guard let place = WideCameraMath.placement(
      scale: scale,
      viewW: px.width,
      viewH: px.height,
      frameW: fw,
      frameH: fh,
      maxW: maxW,
      maxH: maxH,
      sidesOnly: sides
    ) else {
      if widePlacement != nil { widePlacement = nil }
      lcdTop.setExpandPlacement(nil)
      let q = emuQueue
      q.async { pk_ios_set_wide_view(0, 0, 0, 0) }
      return
    }
    if widePlacement != place {
      widePlacement = place
      // Only re-layout the CALayer when the window actually moves.
      lcdTop.setExpandPlacement(place)
    }
    let vx = Int32(place.x)
    let vy = Int32(place.y)
    let vw = Int32(place.w)
    let vh = Int32(place.h)
    // Skip redundant native calls when the integer window hasn't moved.
    if lastWideApplied?.x == vx, lastWideApplied?.y == vy,
       lastWideApplied?.w == vw, lastWideApplied?.h == vh {
      return
    }
    lastWideApplied = (vx, vy, vw, vh)
    let q = emuQueue
    q.async { pk_ios_set_wide_view(vx, vy, vw, vh) }
  }

  /// Cycle Expand zoom through only the steps this play area can actually show.
  func cycleZoom() {
    AppSettings.shared.zoomLevel.cycle(available: max(1, zoomStepCount))
    if lastWideDisplay.width > 0 {
      updateWideView(forDisplay: lastWideDisplay)
    }
  }

  /// Cycle emulation speed 1× → 2× → 3× → 1×.
  func cycleSpeed() {
    speedMultiplier = speedMultiplier >= 3 ? 1 : speedMultiplier + 1
    InputHaptics.buttonPress()
    showToast(speedMultiplier == 1 ? "Speed 1×" : "Speed \(speedMultiplier)×")
  }

  func listSaveStateSlots() -> [SaveStateSlotInfo] {
    let order = [RomLibrary.autoSaveSlot] + Array(1...RomLibrary.saveStateSlotCount)
    guard let url = loadedRomURL else {
      return order.map { SaveStateSlotInfo(slot: $0, exists: false, modified: nil, thumbURL: nil) }
    }
    let fm = FileManager.default
    return order.map { slot in
      let state = RomLibrary.statePath(forRom: url, slot: slot)
      let thumb = RomLibrary.stateThumbPath(forRom: url, slot: slot)
      let exists = fm.fileExists(atPath: state.path)
      let modified = exists
        ? (try? state.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        : nil
      let thumbOK = fm.fileExists(atPath: thumb.path)
      return SaveStateSlotInfo(
        slot: slot,
        exists: exists,
        modified: modified,
        thumbURL: thumbOK ? thumb : nil
      )
    }
  }

  /// Write current state + screenshot into `slot` (0 = Auto, 1…N = manual).
  /// - Parameters:
  ///   - quiet: skip the generic toast + haptic
  ///   - banner: show the top-chrome “Auto-saved” animation
  func saveState(to slot: Int, quiet: Bool = false, banner: Bool = false, completion: ((Bool) -> Void)? = nil) {
    // Never pk_ios_is_running() on main — it takes g_lock and freezes behind Expand frames.
    guard RomLibrary.isValidSaveSlot(slot),
          let url = loadedRomURL,
          loadedRomKey != nil else {
      if !quiet { showToast("Nothing to save") }
      completion?(false)
      return
    }
    let statePath = RomLibrary.statePath(forRom: url, slot: slot)
    let thumbPath = RomLibrary.stateThumbPath(forRom: url, slot: slot)
    let artworkKey = Self.artworkKey(forRomURL: url)
    let gbaColors = AppSettings.shared.gbaColors
    let unlit = AppSettings.shared.unlitScreen
    let q = emuQueue
    q.async {
      guard pk_ios_is_running() else {
        Task { @MainActor in completion?(false) }
        return
      }
      let ok = statePath.path.withCString { pk_ios_save_state($0) }
      // Capture on the emu queue from the live video buffer — never from
      // frameImage (aliases the present ring; A=0 + premultiplied → black/white).
      var thumbData: Data?
      if ok, let thumbPixels = Self.capturePresentThumbPixels(gbaColors: gbaColors, unlit: unlit) {
        thumbData = Self.jpegThumb(from: thumbPixels)
        if let thumbData {
          try? thumbData.write(to: thumbPath, options: [.atomic])
        }
      }
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.refreshSaveStateFlag()
        // Harvest real in-game frames for the game page (hacks included).
        if ok, let thumbData {
          RomArtworkStore.shared.appendScreenshot(imageData: thumbData, forKey: artworkKey)
        }
        if ok {
          if banner {
            self.flashAutoSaveNotice()
          } else if !quiet {
            let label = slot == RomLibrary.autoSaveSlot ? "Auto" : "slot \(slot)"
            self.showToast("Saved to \(label)")
            InputHaptics.buttonPress()
          }
        } else if !quiet {
          self.showToast("Save failed")
        }
        completion?(ok)
      }
    }
  }

  /// Matches `RomItem.artworkKey` so play captures land in the same Artwork folder.
  private static func artworkKey(forRomURL url: URL) -> String {
    let stem = url.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return "\(stem)_\(size)"
  }

  /// Load state from `slot`.
  func loadState(from slot: Int, completion: ((Bool) -> Void)? = nil) {
    guard RomLibrary.isValidSaveSlot(slot),
          let url = loadedRomURL,
          loadedRomKey != nil else {
      showToast("Nothing to load")
      completion?(false)
      return
    }
    let path = RomLibrary.statePath(forRom: url, slot: slot)
    guard FileManager.default.fileExists(atPath: path.path) else {
      let label = slot == RomLibrary.autoSaveSlot ? "Auto" : "Slot \(slot)"
      showToast("\(label) empty")
      completion?(false)
      return
    }
    let q = emuQueue
    q.async {
      guard pk_ios_is_running() else {
        Task { @MainActor [weak self] in
          self?.showToast("Nothing to load")
          completion?(false)
        }
        return
      }
      let ok = path.path.withCString { pk_ios_load_state($0) }
      Task { @MainActor [weak self] in
        guard let self else { return }
        let label = slot == RomLibrary.autoSaveSlot ? "Auto" : "slot \(slot)"
        self.showToast(ok ? "Loaded \(label)" : "Load failed")
        if ok { InputHaptics.buttonPress() }
        completion?(ok)
      }
    }
  }

  func deleteState(slot: Int) {
    guard RomLibrary.isValidSaveSlot(slot), let url = loadedRomURL else { return }
    let fm = FileManager.default
    let state = RomLibrary.statePath(forRom: url, slot: slot)
    let thumb = RomLibrary.stateThumbPath(forRom: url, slot: slot)
    try? fm.removeItem(at: state)
    try? fm.removeItem(at: thumb)
    refreshSaveStateFlag()
    let label = slot == RomLibrary.autoSaveSlot ? "Auto" : "slot \(slot)"
    showToast("Deleted \(label)")
  }

  /// Periodic / event-driven auto-save into slot 0.
  func writeAutoSave(showBanner: Bool = true, completion: ((Bool) -> Void)? = nil) {
    guard loadedRomKey != nil, !autoSaveInFlight else {
      completion?(false)
      return
    }
    autoSaveInFlight = true
    saveState(to: RomLibrary.autoSaveSlot, quiet: true, banner: showBanner) { [weak self] ok in
      self?.autoSaveInFlight = false
      completion?(ok)
    }
  }

  private func startAutoSaveTimer() {
    stopAutoSaveTimer()
    let timer = Timer(timeInterval: Self.autoSaveInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self, self.isRunning else { return }
        self.writeAutoSave(showBanner: true)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    autoSaveTimer = timer
  }

  private func stopAutoSaveTimer() {
    autoSaveTimer?.invalidate()
    autoSaveTimer = nil
  }

  private func refreshSaveStateFlag() {
    hasAnySaveState = listSaveStateSlots().contains(where: \.exists)
  }

  private func uiImage(from cg: CGImage) -> UIImage? {
    UIImage(cgImage: cg)
  }

  /// Owned RGBA copy of a present frame (safe after the present ring advances).
  private struct FrozenThumbPixels: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]
  }

  /// Snapshot `pk_ios_video_buffer` on the emu queue into opaque RGBA for JPEG thumbs.
  /// Cores often leave A=0; treating that as premultipliedLast made game-page snaps
  /// come out pure black (or washed-out white after a bad redraw).
  private static func capturePresentThumbPixels(gbaColors: Bool, unlit: Bool) -> FrozenThumbPixels? {
    let w = Int(pk_ios_video_width())
    let h = Int(pk_ios_video_height())
    guard w > 0, h > 0, let buf = pk_ios_video_buffer() else { return nil }
    // NDS stacked buffer is top+bottom; prefer the top LCD for the game page.
    let outH: Int = {
      if pk_ios_platform() == 3, h >= (w * 3) / 2 { return h / 2 }
      return h
    }()
    let count = w * outH * 4
    var bytes = [UInt8](repeating: 0, count: count)
    bytes.withUnsafeMutableBytes { raw in
      guard let dst = raw.baseAddress else { return }
      memcpy(dst, buf, count)
    }
    // Match the play surface (shaders run on the present ring, not the core buffer).
    if gbaColors || unlit {
      FrameShaders.apply(rgba: &bytes, width: w, height: outH, gbaColors: gbaColors, unlit: unlit)
    }
    // Force opaque RGB — ignore whatever the core left in A.
    for i in stride(from: 3, to: bytes.count, by: 4) {
      bytes[i] = 255
    }
    // Mild LCD darken so JPEGs don't look hotter than the play chrome.
    let gain = 0.92
    let lift = 0.02
    for i in stride(from: 0, to: bytes.count, by: 4) {
      for c in 0..<3 {
        let v = Double(bytes[i + c]) / 255.0
        let shaped = min(1, max(0, (v - lift) * gain))
        bytes[i + c] = UInt8(shaped * 255.0 + 0.5)
      }
    }
    return FrozenThumbPixels(width: w, height: outH, bytes: bytes)
  }

  private static func jpegThumb(from pixels: FrozenThumbPixels) -> Data? {
    let bpr = pixels.width * 4
    return pixels.bytes.withUnsafeBytes { raw -> Data? in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
      guard let data = CFDataCreate(nil, base, pixels.bytes.count),
            let provider = CGDataProvider(data: data),
            let cg = CGImage(
              width: pixels.width,
              height: pixels.height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: bpr,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
            ) else { return nil }
      return UIImage(cgImage: cg).jpegData(compressionQuality: 0.82)
    }
  }

  private func showToast(_ text: String) {
    actionToast = text
    toastClearTask?.cancel()
    toastClearTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_400_000_000)
      guard !Task.isCancelled else { return }
      if actionToast == text { actionToast = nil }
    }
  }

  private func flashAutoSaveNotice() {
    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
      autoSaveNotice = "Auto-saved"
    }
    autoSaveNoticeTask?.cancel()
    autoSaveNoticeTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 2_200_000_000)
      guard !Task.isCancelled else { return }
      withAnimation(.easeOut(duration: 0.28)) {
        if autoSaveNotice != nil { autoSaveNotice = nil }
      }
    }
  }

  /// Reads the cart header once and picks Gen 1 / Gen 2 / Gen 3 companion config.
  private func configureCompanion() {
    companionGeneration += 1
    companionFrameCount = 0
    companionSampler = nil
    companion = nil
    companionGameName = nil
    companionMatch = nil

    switch pk_ios_platform() {
    case 1:
      configureGen3Companion()
    case 2:
      configureGBCompanion()
    case 3:
      configureGen4Companion()
    default:
      companionHint = "PocketDex plays GB, GBC, GBA, and DS."
    }
  }

  private func configureGen4Companion() {
    var code = [CChar](repeating: 0, count: 5)
    guard pk_ios_rom_code(&code) else {
      companionHint = "Nintendo DS is running. Load HeartGold, SoulSilver, Platinum, Black / White, or B2 / W2 for Smart Battle Island."
      return
    }
    let codeStr = String(cString: code)
    if let g5 = Gen5ConfigStore.detect(code: codeStr) {
      companionSampler = Gen5Sampler(config: g5)
      companionGameName = g5.displayName
      companionHint = "\(g5.displayName) — companion connected (party · bag · dex · battle)."
      ndsGen5Session = true
      return
    }
    ndsGen5Session = false
    guard let config = Gen4ConfigStore.detect(code: codeStr) else {
      companionHint = "DS companion: HG/SS, Platinum, Black / White, B2 / W2 (\(codeStr)). Play works."
      return
    }
    companionSampler = Gen4Sampler(config: config)
    companionGameName = config.displayName
    companionHint = "\(config.displayName) — companion connected (party · bag · dex · battle)."
  }

  private func configureGen3Companion() {
    var code = [CChar](repeating: 0, count: 5)
    var title = [CChar](repeating: 0, count: 13)
    guard pk_ios_rom_code(&code) else {
      companionHint = "Load a Pokémon GBA ROM for companion (Emerald, FireRed, LeafGreen, Ruby/Sapphire, Unbound, Seaglass, …)."
      return
    }
    _ = pk_ios_rom_title(&title)
    let codeStr = String(cString: code)
    let titleStr = String(cString: title)
    let revision = Int(pk_ios_rom_revision())
    let romSize = pk_ios_rom_size()
    let romURL = loadedRomURL
    let gen = companionGeneration

    // Companion must never take down play: unknown / unpinned hacks just skip the sampler.
    // Header-only first so play never blocks on hashing a 16–32 MB ROM on the main thread.
    let fileName = romURL?.lastPathComponent ?? ""
    let headerDetect = Gen3Config.detectDetailed(
      code: codeStr, title: titleStr, revision: revision, romSize: romSize, sha1: nil, fileName: fileName
    )
    applyGen3Detection(
      headerDetect,
      fileName: fileName,
      code: codeStr,
      title: titleStr,
      revision: revision,
      romSize: romSize,
      sha1: nil
    )

    guard let url = romURL else { return }
    Task.detached(priority: .utility) { [weak self] in
      let sha1 = RomSHA1.hex(of: url)
      await MainActor.run {
        guard let self, self.companionGeneration == gen else { return }
        let detected = Gen3Config.detectDetailed(
          code: codeStr, title: titleStr, revision: revision, romSize: romSize, sha1: sha1, fileName: fileName
        )
        self.applyGen3Detection(
          detected,
          fileName: fileName,
          code: codeStr,
          title: titleStr,
          revision: revision,
          romSize: romSize,
          sha1: sha1
        )
      }
    }
  }

  private func applyGen3Detection(
    _ detected: Gen3Config.Detection,
    fileName: String,
    code: String,
    title: String,
    revision: Int,
    romSize: UInt32,
    sha1: String?
  ) {
    companionMatch = detected.config == nil ? .none : detected.match
    CompanionRomIdentity.write(
      record: CompanionRomIdentity.Record(
        fileName: fileName,
        code: code,
        title: title.trimmingCharacters(in: .whitespaces),
        revision: revision,
        romSize: romSize,
        sha1: sha1,
        configId: detected.config?.id,
        displayName: detected.config?.displayName,
        match: detected.match.rawValue,
        updatedAt: CompanionRomIdentity.isoNow(),
        wideSupported: wideSupported
      )
    )
    let expandNote: String = {
      if wideSupported {
        return " Expand ready — set Aspect to Expand for zoom / auto-zoom."
      }
      return " Expand not available for this ROM yet."
    }()
    guard let config = detected.config else {
      companionSampler = nil
      companionGameName = nil
      if let sha1, Gen3Config.blockedSha1s.contains(sha1.lowercased())
          || title.uppercased().contains("GHOST GREY") || title.uppercased().contains("GHOSTGREY") {
        companionHint = "Ghost Grey isn’t supported in companion (developer request). The game still plays."
        return
      }
      let short = sha1.map { String($0.prefix(12)) } ?? "pending"
      companionHint = "Companion needs a profile for this ROM (\(code), sha1 \(short)…). Play works — queued in Settings › Support.\(expandNote)"
      return
    }
    companionSampler = Gen3Sampler(config: config)
    companionGameName = config.displayName
    switch detected.match {
    case .sha1:
      companionHint = "\(config.displayName) — companion connected.\(expandNote) Waiting for save data…"
    case .header:
      companionHint = "\(config.displayName) — companion connected (header match).\(expandNote) Waiting for save data…"
    case .bestEffort:
      companionHint = "\(config.displayName) — best-effort companion (unverified). Queued in Settings › Support.\(expandNote)"
    case .none:
      companionHint = "\(config.displayName) — companion connected.\(expandNote) Waiting for save data…"
    }
  }

  private func configureGBCompanion() {
    var title = [CChar](repeating: 0, count: 17)
    var mfr = [CChar](repeating: 0, count: 5)
    guard pk_ios_gb_title(&title) else {
      companionHint = "Load a Pokémon GB/GBC ROM for companion (Red/Blue/Yellow, Gold/Silver/Crystal, …)."
      return
    }
    _ = pk_ios_gb_manufacturer(&mfr)
    let titleStr = String(cString: title)
    let mfrStr = String(cString: mfr)
    // GB/GBC: plain SHA-1 — never apply the GBA GPIO mask (it breaks Polished Crystal, etc.).
    let sha1 = loadedRomURL.flatMap { RomSHA1.hexPlain(of: $0) }

    var g2 = Gen2ConfigStore.detect(title: titleStr, manufacturer: mfrStr, sha1: sha1)
    // Filename soft-map when the header title is blank / odd (device dumps named pokeprism.gbc).
    if g2 == nil, let name = loadedRomURL?.lastPathComponent.uppercased(),
       name.contains("PRISM") || name.contains("POKEPRISM") {
      g2 = Gen2ConfigStore.prism
    }
    if let g2 {
      companionSampler = Gen2Sampler(config: g2)
      companionGameName = g2.displayName
      companionHint = "\(g2.displayName) — companion connected. Waiting for save data…"
      return
    }
    if let g1 = Gen1ConfigStore.detect(title: titleStr, manufacturer: mfrStr) {
      companionSampler = Gen1Sampler(config: g1)
      companionGameName = g1.displayName
      companionHint = "\(g1.displayName) — companion connected. Waiting for save data…"
      return
    }
    companionHint = "Companion doesn't recognise this GB/GBC title yet (\(titleStr)). It still plays fine."
  }

  /// Companion samples steal the emu thread — keep them rare while playing.
  private func sampleCompanionIfNeeded() {
    guard let sampler = companionSampler else { return }
    companionFrameCount += 1
    let fastCatch = SmartIslandMemory.shared.wantsFastCompanionPoll
    let base: Int = {
      if companionSampler is Gen4Sampler || companionSampler is Gen5Sampler {
        // Catch shake window — poll faster so Gotcha FX isn't a second late.
        if fastCatch { return companionDrawerOpen ? 30 : 12 }
        return companionSampleEveryFramesNDS
      }
      if fastCatch {
        // ~5–6 Hz while a ball is unresolved (normal is ~1–1.5 Hz).
        return companionDrawerOpen ? 20 : 10
      }
      // GB/GBA Expand is tight on budget; ~1 Hz closed, slower if drawer open.
      return companionDrawerOpen ? 90 : 45
    }()
    let every = companionDrawerOpen && (companionSampler is Gen4Sampler || companionSampler is Gen5Sampler)
      && !fastCatch
      ? base * 4
      : base
    guard companionFrameCount >= every else { return }
    companionFrameCount = 0
    let generation = companionGeneration
    let drawerOpen = companionDrawerOpen
    if let g5 = sampler as? Gen5Sampler {
      g5.lightSample = !drawerOpen
    }
    emuQueue.async { [weak self] in
      let snap = sampler.sample()
      Task { @MainActor [weak self] in
        guard let self, self.companionGeneration == generation, self.isRunning else { return }
        self.publishCompanion(snap)
      }
    }
  }

  private func publishCompanion(_ snap: CompanionSnapshot?) {
    guard let snap else { return }
    let battleChanged = companion?.inBattle != snap.inBattle
    if companion != snap { companion = snap }
    // Auto-save when a battle ends (caught / fled / won).
    if wasInBattle && !snap.inBattle {
      writeAutoSave(showBanner: true)
    }
    wasInBattle = snap.inBattle
    if battleChanged, lastWideDisplay.width > 0 {
      updateWideView(forDisplay: lastWideDisplay)
    }
    let hint: String
    if snap.partyCount > 0 {
      hint = "\(snap.gameName) — party \(snap.partyCount)\(snap.inBattle ? " · in battle" : "")"
    } else {
      hint = "\(snap.gameName) — no party yet (start a new game or load your save)"
    }
    if companionHint != hint { companionHint = hint }
  }

  /// Step 1 of Exit Completely: stop the play loop only.
  /// Do **not** touch `@Published` here — device logs showed AttributeGraph thrashing
  /// (watchdog `0x8BADF00D`) when identity publishes raced the nav-pop animation.
  func beginQuit() {
    isQuitting = true
    stopAutoSaveTimer()
    displayLink?.invalidate()
    displayLink = nil
    frameInFlight = false
    pendingEmuTicks = 0
    autoSaveInFlight = false
    companionGeneration += 1
    audio.mute()
    if let url = loadedRomURL {
      pendingQuitSave = (
        statePath: RomLibrary.statePath(forRom: url, slot: RomLibrary.autoSaveSlot),
        thumbPath: RomLibrary.stateThumbPath(forRom: url, slot: RomLibrary.autoSaveSlot),
        artworkKey: Self.artworkKey(forRomURL: url),
        thumbCG: frameImage
      )
    } else {
      pendingQuitSave = nil
    }
  }

  /// Step 2 (after PlayView has left): publish teardown + save/deinit off-screen.
  func finishQuit() {
    let save = pendingQuitSave
    pendingQuitSave = nil
    tearDownSessionUI(clearIdentity: true)
    statusText = "Idle"
    isQuitting = false
    // Stop audio now (tear-down is already deferred inside EmulatorAudio). An extra
    // main.async here raced the next Play session and left games permanently silent.
    audio.stop()
    emuQueue.async {
      if let save, pk_ios_is_running() {
        _ = save.statePath.path.withCString { pk_ios_save_state($0) }
        // Skip JPEG + artwork bump on quit — that republished LibraryView mid-pop.
      }
      pk_ios_deinit()
    }
  }

  /// Auto-save then unload (legacy single-shot). Prefer beginQuit → leave → finishQuit.
  func quitSession(completion: (() -> Void)? = nil) {
    beginQuit()
    completion?()
    DispatchQueue.main.async { [weak self] in
      self?.finishQuit()
    }
  }

  func stop() {
    haltPlayLoop()
    tearDownSessionUI(clearIdentity: true)
    // Async so a wedged emu frame can't block Play / navigation on main.
    emuQueue.async { pk_ios_deinit() }
    statusText = "Idle"
    audio.stop()
  }

  /// Clear play UI / session flags without waiting on the emu queue.
  private func tearDownSessionUI(clearIdentity: Bool) {
    stopAutoSaveTimer()
    autoSaveNoticeTask?.cancel()
    displayLink?.invalidate()
    displayLink = nil
    // Audio: caller mutes / stops separately — never engine.stop() here.
    AppSettings.shared.applyIdleTimer(playing: false)
    buttonMask = 0
    dpadMask = 0
    keyMask = 0
    lastSkinMask = 0
    PadPressedStore.shared.clear()
    companionGeneration += 1
    companionSampler = nil
    companionDrawerOpen = false
    lastAudioEnabled = nil
    wasInBattle = false
    autoSaveInFlight = false
    frameInFlight = false
    pendingEmuTicks = 0
    pendingQuitSave = nil
    fpsWindowStart = CACurrentMediaTime()
    fpsWindowCount = 0
    FpsBadge.shared.reset()
    cachedCoreW = 0
    cachedCoreH = 0
    cachedPlatform = 0
    cachedWideScene = 0
    ndsGen5Session = false
    ndsJitSession = false
    isRunning = false
    isPaused = false
    if clearIdentity {
      loadedRomURL = nil
      loadedRomKey = nil
    }
    frameImage = nil
    ndsNativeFrame = nil
    lcdTop.clear()
    lcdBottom.clear()
    lcdTouchTop.clear()
    lcdTouchBottom.clear()
    lcdTop.setExpandPlacement(nil)
    lastNdsFieldBits = 0
    skipPresentStreak = 0
    frameInFlight = false
    ndsGen5Session = false
    CompanionLiveStore.shared.clear()
    wideSupported = false
    wideZoom.reset()
    lastWideApplied = nil
    widePlacement = nil
    speedMultiplier = 1
    hasAnySaveState = false
    actionToast = nil
    autoSaveNotice = nil
    resetDsTouchState()
  }

  func setKey(_ bit: UInt32, down: Bool) {
    let wasDown = (buttonMask & bit) != 0
    if down {
      guard !wasDown else { return }
      buttonMask |= bit
      InputHaptics.buttonPress()
    } else {
      guard wasDown else { return }
      buttonMask &= ~bit
    }
    publishKeys()
  }

  func applyDpadMask(_ mask: UInt32) {
    let next = mask & dpadBits
    guard next != dpadMask else { return }
    // Tick on every direction change (left ↔ right ↔ up…), rate-limited in InputHaptics.
    if next != 0 { InputHaptics.dpadChange() }
    dpadMask = next
    publishKeys()
  }

  func setMask(_ mask: UInt32) {
    // Absolute mask from skin touch layer (owns all bits).
    guard mask != lastSkinMask else { return }
    let newlyPressed = mask & ~lastSkinMask
    let dpadChanged = (mask & dpadBits) != (lastSkinMask & dpadBits)
    lastSkinMask = mask
    buttonMask = mask
    dpadMask = 0
    if newlyPressed & ~dpadBits != 0 {
      InputHaptics.buttonPress()
    } else if dpadChanged, (mask & dpadBits) != 0 {
      InputHaptics.dpadChange()
    }
    publishKeys()
  }

  /// Latch keys for the next emu frame. Full D-pad mode updates pad glow immediately;
  /// lite mode defers glow to the display tick (see `tick`).
  private func publishKeys() {
    let mask = buttonMask | dpadMask
    keyMask = mask
    if !AppSettings.shared.dpadLiteMode {
      PadPressedStore.shared.setMask(mask)
    }
  }

  /// Stylus on the DS bottom LCD. `point` is local to the bottom screen view (maps to 0…255 / 0…191).
  func setTouch(down: Bool, inBottomScreen point: CGPoint, screenSize: CGSize) {
    guard screenSize.width > 0, screenSize.height > 0 else {
      emuQueue.async(flags: .barrier) { pk_ios_set_touch(false, 0, 0) }
      return
    }
    let nx = point.x / screenSize.width
    let ny = point.y / screenSize.height
    let x = Int(max(0, min(255, floor(nx * 256))))
    let y = Int(max(0, min(191, floor(ny * 192))))
    emuQueue.async(flags: .barrier) { pk_ios_set_touch(down, Int32(x), Int32(y)) }
  }

  func releaseTouch() {
    emuQueue.async(flags: .barrier) { pk_ios_set_touch(false, 0, 0) }
  }

  /// Brief B press — PokeDaisy dismisses the floating touch window this way.
  func tapB() {
    setKey(1 << 1, down: true)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      self?.setKey(1 << 1, down: false)
    }
  }

  private func resetDsTouchState() {
    dsTouchWanted = false
    dsMenuScreen = false
    dsTouchBlank = false
    dsTouchFrames = 0
    dsMenuFrames = 0
    dsDarkBefore = false
    dsFadeSeen = false
    dsFadeFrames = 0
    dsLitFrames = 0
  }

  /// Settle DS LAYOUT floats from `pk_nds_field` bits (same rules as Android PokeDaisy).
  private func updateDsTouchState(bits: Int32) {
    // Parentheses required: `bits & FLAG != 0` parses as `bits & (FLAG != 0)` in Swift.
    let darkTop = (bits & Self.fieldDarkTop) != 0
    let darkBottom = (bits & Self.fieldDarkBottom) != 0
    let dark = darkTop && darkBottom
    if dsTouchBlank != darkBottom { dsTouchBlank = darkBottom }
    let afterDark = dsDarkBefore && !dark
    dsDarkBefore = dark
    guard !dark else { return }

    var want = (bits & Self.fieldTouch) != 0 || (bits & Self.fieldTouchBattleMenu) != 0
    let fades = (bits & Self.fieldTouchFades) != 0
    if fades && dsTouchWanted && darkBottom {
      if dsTouchWanted { dsTouchWanted = false }
      dsTouchFrames = 0
      dsFadeSeen = true
      dsFadeFrames = 0
      dsLitFrames = 0
    }
    if want && !dsTouchWanted && fades {
      if darkBottom {
        dsFadeSeen = true
        dsLitFrames = 0
      } else {
        dsLitFrames += 1
      }
      dsFadeFrames += 1
      if !(dsFadeSeen && dsLitFrames >= Self.dsFadeLitFrames) && dsFadeFrames < Self.dsFadeWaitFrames {
        want = false
      }
    } else if !want {
      dsFadeSeen = false
      dsFadeFrames = 0
      dsLitFrames = 0
    }

    let menu = (bits & Self.fieldMenu) != 0
      && (bits & (Self.fieldBattle | Self.fieldTouchOnly | Self.fieldTopOnly)) == 0

    func settle(_ current: Bool, _ target: Bool, frames: inout Int) -> Bool {
      if target == current {
        frames = 0
        return current
      }
      frames += 1
      let need = target ? Self.dsTouchOnFrames : Self.dsTouchOffFrames
      if afterDark || frames >= need {
        frames = 0
        return target
      }
      return current
    }

    let nextWant = settle(dsTouchWanted, want, frames: &dsTouchFrames)
    if dsTouchWanted != nextWant { dsTouchWanted = nextWant }
    if nextWant {
      dsFadeSeen = false
      dsFadeFrames = 0
      dsLitFrames = 0
    }
    let nextMenu = settle(dsMenuScreen, menu, frames: &dsMenuFrames)
    if dsMenuScreen != nextMenu { dsMenuScreen = nextMenu }
  }

  private func startLoop() {
    InputHaptics.prepare()
    audio.start()
    audio.setOutputEnabled(AppSettings.shared.audioEnabled)
    lastAudioEnabled = AppSettings.shared.audioEnabled
    AppSettings.shared.applyIdleTimer(playing: true)
    let link = CADisplayLink(target: self, selector: #selector(tick))
    // Duo / ProMotion are 120 Hz — pin 60 so Soft Expand + audio stay 1 game frame / tick
    // (PokeDaisy 1.6.1 took back 120 Hz 1× pacing that stuttered DS).
    link.preferredFramesPerSecond = 60
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
    }
    link.add(to: .main, forMode: .common)
    displayLink = link
    startAutoSaveTimer()
  }

  @objc private func tick() {
    guard isRunning else { return }
    // Never drop a tick's audio: if emu is busy, remember it and catch up next wake.
    // Old path returned while frameInFlight → ring starved → scratchy pops.
    pendingEmuTicks += 1
    if frameInFlight {
      if CACurrentMediaTime() - frameInFlightSince > 2.5 {
        frameInFlight = false
      } else {
        return
      }
    }
    let speed = max(1, min(3, speedMultiplier))
    let wantAudio = AppSettings.shared.audioEnabled
    if lastAudioEnabled != wantAudio {
      lastAudioEnabled = wantAudio
      audio.setOutputEnabled(wantAudio)
    }
    if wantAudio {
      audio.ensureRunning()
    }
    let settings = AppSettings.shared
    let gbaColors = settings.gbaColors
    let unlit = settings.unlitScreen
    let expandOn = settings.gameAspect == .expand && wideSupported
    let keysThisFrame = keyMask
    let priorBits = lastNdsFieldBits
    let wantTouchHint =
      (priorBits & Self.fieldTouch) != 0
      || (priorBits & Self.fieldTouchBattleMenu) != 0
      || (priorBits & Self.fieldMenu) != 0
      || (priorBits & Self.fieldTouchFades) != 0
      || dsTouchWanted
      || dsMenuScreen
    let needNdsBottom = expandOn && wantTouchHint
    if speed > 1 { skipPresentStreak = 0 }
    let deferPresent = speed == 1 && skipPresentStreak > 0 && frameImage != nil
    let generation = companionGeneration
    // Expand camera on the display-link beat (before emu) — doing it after
    // present kept frameInFlight true through main-thread math and missed 60.
    if expandOn, lastWideDisplay.width > 0 {
      updateWideView(forDisplay: lastWideDisplay)
    }
    // DS may coalesce a few pending ticks; GB/GBA must stay 1 frame/tick —
    // multi-frame catch-up flooded the audio ring (pops) and crushed Expand FPS.
    let coalescePending = cachedPlatform == 3 && speed == 1
    let ticks = coalescePending ? min(3, max(1, pendingEmuTicks)) : 1
    pendingEmuTicks = 0
    frameInFlight = true
    frameInFlightSince = CACurrentMediaTime()
    let t0 = frameInFlightSince
    emuQueue.async { [weak self] in
      guard let self else { return }
      pk_ios_set_keys(keysThisFrame)
      let isNdsHint = self.cachedPlatform == 3
      for _ in 0..<ticks {
        for s in 0..<speed {
          // Same contract as original: only the last frame of the burst keeps
          // audio + draws LCDs (drawNext stays armed inside pk_ios for skips).
          let show = (s == speed - 1) && !deferPresent
          let keepAudio = s == speed - 1
          pk_ios_run_frame_present(keepAudio, show)
        }
      }
      // Audio catch-up at 1× when the ring is starving. DS: up to 3 frames.
      // GB/GBA Expand: up to 2 present-skip frames — Prism WIDE can lag the
      // display-link beat; underruns pad silence and kill sustained music while
      // short SFX still poke through.
      if speed == 1 {
        let platNow = isNdsHint ? 3 : Int(pk_ios_platform())
        let catchUp =
          platNow == 3 || (expandOn && (platNow == 1 || platNow == 2))
        if catchUp {
          let target = pk_ios_audio_target()
          let maxGuard = platNow == 3 ? 3 : 2
          var guardFrames = 0
          while pk_ios_audio_queued() < target / 2 && guardFrames < maxGuard {
            pk_ios_run_frame_present(true, false)
            guardFrames += 1
          }
        }
      }
      let isNds = pk_ios_platform() == 3
      let fieldBits: Int32 = isNds ? Int32(pk_ios_nds_field_bits()) : 0
      let coreW = Int(pk_ios_core_width())
      let coreH = Int(pk_ios_core_height())
      let wideScene = Int(pk_ios_wide_scene())
      let plat = Int(pk_ios_platform())
      var topImage: CGImage?
      var botImage: CGImage?
      if !deferPresent,
         let buf = pk_ios_video_buffer() {
        let w = Int(pk_ios_video_width())
        let h = Int(pk_ios_video_height())
        if w > 0, h > 0 {
          let bytes = w * h * 4
          let slot = self.presentRing.next(bytes: bytes)
          memcpy(slot.ptr, buf, bytes)
          if gbaColors || unlit {
            if self.shaderScratch.count != bytes {
              self.shaderScratch = [UInt8](repeating: 0, count: bytes)
            }
            self.shaderScratch.withUnsafeMutableBytes { raw in
              guard let dst = raw.baseAddress else { return }
              memcpy(dst, slot.ptr, bytes)
            }
            FrameShaders.apply(
              rgba: &self.shaderScratch, width: w, height: h, gbaColors: gbaColors, unlit: unlit
            )
            self.shaderScratch.withUnsafeBytes { raw in
              guard let src = raw.baseAddress else { return }
              memcpy(slot.ptr, src, bytes)
            }
          }
          if let data = CFDataCreateWithBytesNoCopy(
            kCFAllocatorDefault, slot.ptr, bytes, kCFAllocatorNull
          ), let provider = CGDataProvider(data: data) {
            // noneSkipLast — core buffers leave A unused/0; premultipliedLast made
            // any CGContext.draw (save thumbs) collapse to black.
            topImage = CGImage(
              width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
          }
          if isNds, needNdsBottom {
            let botBytes = 256 * 192 * 4
            if self.ndsBottomScratch.count != botBytes {
              self.ndsBottomScratch = [UInt8](repeating: 0, count: botBytes)
            }
            let ok = self.ndsBottomScratch.withUnsafeMutableBytes { raw -> Bool in
              guard let dst = raw.bindMemory(to: UInt32.self).baseAddress else { return false }
              return pk_ios_nds_bottom_rgba(dst)
            }
            if ok {
              if gbaColors || unlit {
                FrameShaders.apply(
                  rgba: &self.ndsBottomScratch, width: 256, height: 192, gbaColors: gbaColors, unlit: unlit
                )
              }
              if let botData = self.ndsBottomScratch.withUnsafeBytes({ raw -> CFData? in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                return CFDataCreate(nil, base, botBytes)
              }), let botProvider = CGDataProvider(data: botData) {
                botImage = CGImage(
                  width: 256, height: 192, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                  provider: botProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
                )
              }
            }
          }
        }
      }
      let dt = CACurrentMediaTime() - t0
      // Open the display-link gate before CALayer/SwiftUI work — emuQueue is
      // serial, so the next GB/GBA frame can start while this one presents.
      DispatchQueue.main.async { [weak self] in
        self?.frameInFlight = false
      }
      if !deferPresent, let topImage {
        if isNds, topImage.height >= (topImage.width * 3) / 2 {
          let half = topImage.height / 2
          let topRect = CGRect(x: 0, y: 0, width: topImage.width, height: half)
          let botRect = CGRect(x: 0, y: half, width: topImage.width, height: half)
          let topCrop = topImage.cropping(to: topRect)
          let botCrop: CGImage? = {
            if needNdsBottom, let botImage { return botImage }
            return topImage.cropping(to: botRect)
          }()
          self.lcdTop.setImage(topCrop)
          self.lcdTouchTop.setImage(topCrop)
          self.lcdBottom.setImage(botCrop)
          self.lcdTouchBottom.setImage(botCrop)
        } else if isNds {
          self.lcdTop.setImage(topImage)
          self.lcdTouchTop.setImage(topImage)
          if needNdsBottom, let botImage {
            self.lcdBottom.setImage(botImage)
            self.lcdTouchBottom.setImage(botImage)
          }
        } else {
          self.lcdTop.setImage(topImage)
        }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.companionGeneration == generation, self.isRunning else { return }
        self.cachedPlatform = plat
        self.cachedCoreW = coreW
        self.cachedCoreH = coreH
        self.cachedWideScene = wideScene
        if !deferPresent, let topImage {
          self.frameImage = topImage
          if isNds {
            if needNdsBottom { self.ndsNativeFrame = botImage }
            else { self.ndsNativeFrame = nil }
          } else {
            self.ndsNativeFrame = nil
          }
        }
        if isNds {
          self.lastNdsFieldBits = fieldBits
          self.updateDsTouchState(bits: fieldBits)
          let slow = 0.022
          self.skipPresentStreak = dt > slow ? min(1, self.skipPresentStreak + 1) : 0
        } else {
          if self.dsTouchWanted || self.dsMenuScreen || self.dsTouchBlank {
            self.lastNdsFieldBits = 0
            self.resetDsTouchState()
          }
          // Soft-skip Expand compose when a GB/GBA frame overruns (~20 ms) so
          // the next tick still feeds audio instead of holding g_lock in WIDE.
          if expandOn {
            let slow = 0.020
            self.skipPresentStreak = dt > slow ? min(1, self.skipPresentStreak + 1) : 0
          } else {
            self.skipPresentStreak = 0
          }
        }
        self.notePresentedFrame()
        if AppSettings.shared.dpadLiteMode {
          PadPressedStore.shared.setMask(self.keyMask)
        }
        self.sampleCompanionIfNeeded()
        if self.pendingEmuTicks > 0 {
          self.tick()
        }
      }
    }
  }

  /// Count completed display ticks; update isolated FPS badge (~4×/s).
  private func notePresentedFrame() {
    fpsWindowCount += 1
    let now = CACurrentMediaTime()
    let elapsed = now - fpsWindowStart
    guard elapsed >= 0.25 else { return }
    let measured = Int((Double(fpsWindowCount) / elapsed).rounded())
    FpsBadge.shared.set(measured)
    fpsWindowCount = 0
    fpsWindowStart = now
  }

  deinit {
    pk_ios_deinit()
  }
}

/// Stable RGBA ring so CGImage can reference pixels without a per-frame CFData copy.
private final class FramePresentRing {
  private var ptrs: [UnsafeMutablePointer<UInt8>?]
  private var caps: [Int]
  private var index = 0

  init(slots: Int) {
    ptrs = Array(repeating: nil, count: slots)
    caps = Array(repeating: 0, count: slots)
  }

  deinit {
    for p in ptrs { p?.deallocate() }
  }

  func next(bytes: Int) -> (ptr: UnsafeMutablePointer<UInt8>, bytes: Int) {
    index = (index + 1) % ptrs.count
    if caps[index] < bytes {
      ptrs[index]?.deallocate()
      ptrs[index] = .allocate(capacity: bytes)
      caps[index] = bytes
    }
    return (ptrs[index]!, bytes)
  }
}
