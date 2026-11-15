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
  @Published private(set) var frameImage: CGImage?
  /// NDS native 256×384 stack (for touch-LCD crop when Expand presents a wide top).
  @Published private(set) var ndsNativeFrame: CGImage?
  @Published private(set) var statusText = "Idle"
  @Published var companionHint = "PocketDex companion will read party / bag / map once a Pokémon game is running."
  /// Live companion snapshot (party / bag / map / battle / dex); nil until a supported ROM has been sampled.
  @Published var companion: CompanionSnapshot?
  /// Game recognised from the cart header (nil = not a supported Pokémon ROM).
  @Published private(set) var companionGameName: String?
  /// How the current GBA companion profile was chosen (nil = none / non-GBA).
  @Published private(set) var companionMatch: Gen3Config.MatchKind?

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

  /// Last play-area size used to compute the WIDE window (points).
  private var lastWideDisplay: CGSize = .zero
  /// Eased Expand zoom (PokeDaisy WideCamera tween).
  private let wideZoom = WideZoomTween()
  private var lastWideApplied: (x: Int32, y: Int32, w: Int32, h: Int32)?
  @Published private(set) var wideSupported = false
  /// How many distinct Expand zoom steps the current play area supports (1…4).
  @Published private(set) var zoomStepCount = 1
  /// Live zoom label (“1× (close)”, “2× out”, …) from actual WIDE math.
  @Published private(set) var zoomStepTitle = "1× (close)"
  /// Emulation speed: 1× / 2× / 3× (extra frames per display tick).
  @Published private(set) var speedMultiplier: Int = 1
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
  /// Reused RGBA scratch for frame copy + shaders (avoids per-frame alloc on large WIDE buffers).
  private var frameScratch: [UInt8] = []
  private var ndsBottomScratch: [UInt8] = []
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
    stop()
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
    statusText = "Loading \(title)…"
    companionHint = "Loading ROM…"
    isPaused = false
    isRunning = false
    loadedRomURL = nil
    loadedRomKey = nil

    // Large NDS carts must not block the main thread (watchdog). Init on the emu queue.
    let q = emuQueue
    q.async { [weak self] in
      let ok = romPath.withCString { rp in
        savePath.withCString { sp in
          pk_ios_init(rp, sp)
        }
      }
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.isRunning = ok
        self.isPaused = false
        self.loadedRomURL = ok ? romURL.standardizedFileURL : nil
        self.loadedRomKey = ok ? sessionKey : nil
        self.statusText = ok ? "Playing \(title)" : "Failed to load ROM"
        self.companionHint = ok
          ? "PocketDex companion is ready."
          : "Load a GB/GBC/GBA/NDS ROM to begin."
        if ok {
          self.wideSupported = pk_ios_wide_supported()
          self.speedMultiplier = 1
          self.refreshSaveStateFlag()
          self.configureCompanion()
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
    if isRunning {
      // Capture progress before leaving play.
      writeAutoSave(showBanner: false)
    }
    stopAutoSaveTimer()
    displayLink?.invalidate()
    displayLink = nil
    audio.stop()
    AppSettings.shared.applyIdleTimer(playing: false)
    // Release held inputs so nothing sticks across resume.
    buttonMask = 0
    dpadMask = 0
    keyMask = 0
    lastSkinMask = 0
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

  /// Continue a paused session from the frozen frame.
  func resume() {
    guard isPaused, loadedRomURL != nil, loadedRomKey != nil, pk_ios_is_running() else {
      // Core gone somehow — fall back to a full reload if we still know the ROM.
      if let url = loadedRomURL {
        load(romURL: url, key: loadedRomKey)
      }
      return
    }
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
  func updateWideView(forDisplay size: CGSize) {
    lastWideDisplay = size
    let settings = AppSettings.shared
    let fw = Int(pk_ios_core_width())
    let fh = Int(pk_ios_core_height())
    // WideCamera math is in screen pixels (Android view size), not SwiftUI points.
    let px = WideCameraMath.pixels(fromPoints: size)
    if fw > 0, fh > 0, px.width > 0, px.height > 0 {
      zoomStepCount = WideCameraMath.levelCount(
        viewW: px.width, viewH: px.height, frameW: fw, frameH: fh
      )
      zoomStepTitle = WideCameraMath.title(
        level: settings.zoomLevel.rawValue,
        displayPoints: size,
        frameW: fw,
        frameH: fh
      )
      // Clamp stored zoom if this display supports fewer steps.
      if settings.zoomLevel.rawValue >= zoomStepCount {
        let clamped = ZoomLevel(rawValue: max(0, zoomStepCount - 1)) ?? .x1
        if settings.zoomLevel != clamped {
          settings.zoomLevel = clamped
        }
      }
    }

    guard isRunning, settings.gameAspect == .expand, pk_ios_wide_supported() else {
      wideZoom.reset()
      lastWideApplied = nil
      let q = emuQueue
      q.async { pk_ios_set_wide_view(0, 0, 0, 0) }
      return
    }
    guard fw > 0, fh > 0, px.width > 0, px.height > 0 else { return }

    let steps = WideCameraMath.levels(viewW: px.width, viewH: px.height, frameW: fw, frameH: fh)
    guard !steps.isEmpty else { return }

    let scene = Int(pk_ios_wide_scene())
    // PokeDaisy: battles / menus / (optional) text pull in to 1×; field keeps the chosen zoom.
    let wantsClose: Bool = {
      if pk_ios_wide_wants_close() { return true }
      switch scene {
      case 0: return false // FIELD
      case 1: return settings.autoZoomIn // TEXT
      case 2, 5: return false // OVERLAY / FADE — hold
      default: return true
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

    guard let win = WideCameraMath.window(
      scale: scale,
      viewW: px.width,
      viewH: px.height,
      frameW: fw,
      frameH: fh
    ) else {
      let q = emuQueue
      q.async { pk_ios_set_wide_view(0, 0, 0, 0) }
      return
    }
    let vx = Int32(win.x)
    let vy = Int32(win.y)
    let vw = Int32(win.w)
    let vh = Int32(win.h)
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
    guard RomLibrary.isValidSaveSlot(slot),
          let url = loadedRomURL,
          pk_ios_is_running() else {
      if !quiet { showToast("Nothing to save") }
      completion?(false)
      return
    }
    let statePath = RomLibrary.statePath(forRom: url, slot: slot)
    let thumbPath = RomLibrary.stateThumbPath(forRom: url, slot: slot)
    let thumbData = frameImage.flatMap { uiImage(from: $0)?.pngData() }
    let artworkKey = Self.artworkKey(forRomURL: url)
    let q = emuQueue
    q.async {
      let ok = statePath.path.withCString { pk_ios_save_state($0) }
      if ok, let thumbData {
        try? thumbData.write(to: thumbPath, options: [.atomic])
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
          pk_ios_is_running() else {
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
    guard pk_ios_is_running(), !autoSaveInFlight else {
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
      companionHint = "Nintendo DS is running. Load HeartGold, SoulSilver, or Platinum for battle move tips."
      return
    }
    let codeStr = String(cString: code)
    guard let config = Gen4ConfigStore.detect(code: codeStr) else {
      companionHint = "DS companion battle tips: HeartGold / SoulSilver / Platinum for now (\(codeStr)). Play works."
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

    if let g2 = Gen2ConfigStore.detect(title: titleStr, manufacturer: mfrStr, sha1: sha1) {
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

  /// Every ~15 frames (~4 Hz) sample the companion on the emulator queue and publish on main.
  private func sampleCompanionIfNeeded() {
    guard let sampler = companionSampler else { return }
    companionFrameCount += 1
    guard companionFrameCount >= companionSampleEveryFrames else { return }
    companionFrameCount = 0
    let generation = companionGeneration
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
    if companion != snap { companion = snap }
    // Auto-save when a battle ends (caught / fled / won).
    if wasInBattle && !snap.inBattle {
      writeAutoSave(showBanner: true)
    }
    wasInBattle = snap.inBattle
    let hint: String
    if snap.partyCount > 0 {
      hint = "\(snap.gameName) — party \(snap.partyCount)\(snap.inBattle ? " · in battle" : "")"
    } else {
      hint = "\(snap.gameName) — no party yet (start a new game or load your save)"
    }
    if companionHint != hint { companionHint = hint }
  }

  /// Auto-save then unload the core so the next open is a fresh load (not a resume).
  func quitSession(completion: (() -> Void)? = nil) {
    guard loadedRomKey != nil else {
      completion?()
      return
    }
    let finish = { [weak self] in
      self?.stop()
      completion?()
    }
    // Core stays up while paused, so pk_ios_is_running() is still true — save first.
    if pk_ios_is_running() {
      writeAutoSave(showBanner: false) { _ in finish() }
    } else {
      finish()
    }
  }

  func stop() {
    stopAutoSaveTimer()
    autoSaveNoticeTask?.cancel()
    displayLink?.invalidate()
    displayLink = nil
    audio.stop()
    AppSettings.shared.applyIdleTimer(playing: false)
    buttonMask = 0
    dpadMask = 0
    keyMask = 0
    lastSkinMask = 0
    companionGeneration += 1
    companionSampler = nil
    wasInBattle = false
    autoSaveInFlight = false
    emuQueue.sync { pk_ios_deinit() }
    isRunning = false
    isPaused = false
    loadedRomURL = nil
    loadedRomKey = nil
    frameImage = nil
    ndsNativeFrame = nil
    companion = nil
    companionGameName = nil
    companionMatch = nil
    wideSupported = false
    wideZoom.reset()
    lastWideApplied = nil
    speedMultiplier = 1
    hasAnySaveState = false
    actionToast = nil
    autoSaveNotice = nil
    resetDsTouchState()
    statusText = "Idle"
  }

  func setKey(_ bit: UInt32, down: Bool) {
    let wasDown = (buttonMask & bit) != 0
    if down {
      buttonMask |= bit
      if !wasDown { InputHaptics.buttonPress() }
    } else {
      buttonMask &= ~bit
    }
    publishKeys()
  }

  func applyDpadMask(_ mask: UInt32) {
    let next = mask & dpadBits
    if next != dpadMask {
      if next != 0 { InputHaptics.dpadChange() }
      dpadMask = next
      publishKeys()
    }
  }

  func setMask(_ mask: UInt32) {
    // Absolute mask from skin touch layer (owns all bits).
    let newlyPressed = mask & ~lastSkinMask
    lastSkinMask = mask
    buttonMask = mask
    dpadMask = 0
    if newlyPressed != 0 {
      if newlyPressed & ~dpadBits != 0 {
        InputHaptics.buttonPress()
      } else {
        InputHaptics.dpadChange()
      }
    }
    publishKeys()
  }

  private func publishKeys() {
    keyMask = buttonMask | dpadMask
    let mask = keyMask
    // Sync so a quick tap can’t lose the press before the next frame samples keys.
    emuQueue.async(flags: .barrier) { pk_ios_set_keys(mask) }
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
      dsTouchWanted = false
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

    dsTouchWanted = settle(dsTouchWanted, want, frames: &dsTouchFrames)
    if dsTouchWanted {
      dsFadeSeen = false
      dsFadeFrames = 0
      dsLitFrames = 0
    }
    dsMenuScreen = settle(dsMenuScreen, menu, frames: &dsMenuFrames)
  }

  private func startLoop() {
    InputHaptics.prepare()
    audio.start()
    audio.setOutputEnabled(AppSettings.shared.audioEnabled)
    AppSettings.shared.applyIdleTimer(playing: true)
    let link = CADisplayLink(target: self, selector: #selector(tick))
    link.preferredFramesPerSecond = 60
    link.add(to: .main, forMode: .common)
    displayLink = link
    startAutoSaveTimer()
  }

  @objc private func tick() {
    guard isRunning else { return }
    let speed = max(1, min(3, speedMultiplier))
    // Keep audio on during FF at normal pitch: only the last frame of each burst
    // feeds the ring; earlier frames discard samples so output stays ~1× rate.
    audio.setOutputEnabled(AppSettings.shared.audioEnabled)
    // Keep WIDE window in sync with battle/text scenes (auto zoom).
    if AppSettings.shared.gameAspect == .expand, lastWideDisplay.width > 0 {
      updateWideView(forDisplay: lastWideDisplay)
    }
    let settings = AppSettings.shared
    let gbaColors = settings.gbaColors
    let unlit = settings.unlitScreen
    // Emulate + copy + shaders on emuQueue so Unlit on large WIDE frames
    // doesn't stall the main run loop (which was causing audio underruns).
    var outW = 0
    var outH = 0
    var fieldBits: Int32 = 0
    var isNds = false
    var gotBottom = false
    emuQueue.sync {
      for i in 0..<speed {
        pk_ios_run_frame_ex(i == speed - 1)
      }
      isNds = pk_ios_platform() == 3
      if isNds { fieldBits = Int32(pk_ios_nds_field_bits()) }
      let w = Int(pk_ios_video_width())
      let h = Int(pk_ios_video_height())
      guard w > 0, h > 0, let buf = pk_ios_video_buffer() else { return }
      let count = w * h
      let bytes = count * 4
      if frameScratch.count != bytes {
        frameScratch = [UInt8](repeating: 0, count: bytes)
      }
      frameScratch.withUnsafeMutableBytes { raw in
        guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for i in 0..<count {
          let px = buf[i]
          let o = i * 4
          dst[o] = UInt8((px >> 0) & 0xFF)
          dst[o + 1] = UInt8((px >> 8) & 0xFF)
          dst[o + 2] = UInt8((px >> 16) & 0xFF)
          dst[o + 3] = 0xFF
        }
      }
      if gbaColors || unlit {
        FrameShaders.apply(
          rgba: &frameScratch,
          width: w,
          height: h,
          gbaColors: gbaColors,
          unlit: unlit
        )
      }
      outW = w
      outH = h

      // Touch LCD while Expand shows a wide top-only present buffer.
      if isNds {
        let botBytes = 256 * 192 * 4
        if ndsBottomScratch.count != botBytes {
          ndsBottomScratch = [UInt8](repeating: 0, count: botBytes)
        }
        gotBottom = ndsBottomScratch.withUnsafeMutableBytes { raw in
          guard let dst = raw.bindMemory(to: UInt32.self).baseAddress else { return false }
          return pk_ios_nds_bottom_rgba(dst)
        }
        if gotBottom, gbaColors || unlit {
          FrameShaders.apply(
            rgba: &ndsBottomScratch,
            width: 256,
            height: 192,
            gbaColors: gbaColors,
            unlit: unlit
          )
        }
      }
    }
    if isNds {
      updateDsTouchState(bits: fieldBits)
    } else if dsTouchWanted || dsMenuScreen || dsTouchBlank {
      resetDsTouchState()
    }
    guard outW > 0, outH > 0, frameScratch.count >= outW * outH * 4 else { return }
    // CFDataCreate copies bytes; safe even though scratch is reused next frame.
    let data: CFData? = frameScratch.withUnsafeBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
      return CFDataCreate(nil, base, outW * outH * 4)
    }
    guard let data, let provider = CGDataProvider(data: data) else { return }
    frameImage = CGImage(
      width: outW,
      height: outH,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: outW * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
    if isNds, gotBottom, ndsBottomScratch.count >= 256 * 192 * 4 {
      let botData: CFData? = ndsBottomScratch.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
        return CFDataCreate(nil, base, 256 * 192 * 4)
      }
      if let botData, let botProvider = CGDataProvider(data: botData) {
        ndsNativeFrame = CGImage(
          width: 256,
          height: 192,
          bitsPerComponent: 8,
          bitsPerPixel: 32,
          bytesPerRow: 256 * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
          provider: botProvider,
          decode: nil,
          shouldInterpolate: false,
          intent: .defaultIntent
        )
      }
    } else if !isNds {
      ndsNativeFrame = nil
    }
    sampleCompanionIfNeeded()
  }

  deinit {
    pk_ios_deinit()
  }
}
