import SwiftUI

struct PlayView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.dismiss) private var dismiss

  let rom: RomItem
  /// Explicit nav pop — `dismiss()` from a confirmationDialog is unreliable and
  /// left PlayView stuck on a frozen last frame after Exit Completely.
  var onLeave: () -> Void = {}

  @State private var companionOpen = false
  /// Frozen when the companion opens so live geo.size jitter can’t remount / jump the panel.
  @State private var companionPanelSize: CGSize = .zero
  @State private var representation: DeltaSkinRepresentation?
  @State private var transformMap: SkinViewTransform?
  @State private var gameScreenRect: CGRect = .zero
  /// NDS: separate LCDs (Delta / Manic crop the 256×384 buffer into two output frames).
  @State private var topScreenRect: CGRect = .zero
  @State private var bottomScreenRect: CGRect = .zero
  @State private var skinDisplayRect: CGRect = .zero
  @State private var showPadEditor = false
  @State private var showSaveStates = false
  @State private var showLeaveConfirm = false
  /// Fade-to-black before nav pop so Exit/Pause → library doesn’t hard-cut.
  @State private var exitCoverOpacity: Double = 0
  /// Manual DS touch window (PokeDaisy TOUCH / HUD).
  @State private var dsTouchManual = false
  /// User hid the auto touch popup (HIDE) without closing the in-game menu — press TOUCH to bring it back.
  @State private var dsTouchSuppressed = false
  /// Frozen top LCD while a touch-only menu floats (PokeDaisy DsShots field).
  @State private var dsFrozenTop: CGImage?
  /// Mirrors the play canvas orientation for the layout editor (save slot).
  @State private var playLandscape = false
  /// Duo fold division (nil when flat / unavailable).
  @State private var foldDivision: CGRect?
  /// Duo closed → outer/cover skin + single-face play.
  @State private var hingeClosed = false
  /// Top chrome tray: speed / zoom / folder / edit / companion collapsed behind one chevron.
  @State private var chromeActionsExpanded = false
  @ObservedObject private var padLayouts = TouchPadLayoutStore.shared
  @StateObject private var raHUD = RetroAchievementsPlayHUD()

  private var console: ConsoleKind? { rom.console }
  private var skinActive: Bool { representation != nil }
  private var isNDS: Bool { console == .nds }
  /// Smart Island (reactive coach) for every catalogued ROM with companion in the play stack.
  private var smartBattleIslandEnabled: Bool {
    guard let entry = OptimizedRomCatalog.entry(fileName: rom.url.lastPathComponent, displayName: rom.name)
    else { return false }
    return entry.features.contains(.companion)
  }
  /// ONE SCREEN on a flat phone/iPad; Duo fold / Stacked / dual-screen skins still show both LCDs.
  private var dsOneScreen: Bool {
    isNDS
      && settings.dsLayout == .oneScreen
      && foldDivision == nil
      && !settings.folderLayout
      && !skinActive
  }
  private var dsTouchPopupOpen: Bool {
    guard dsOneScreen else { return false }
    if dsTouchSuppressed { return false }
    return dsTouchManual || engine.dsTouchWanted || engine.dsMenuScreen
  }

  private var consoleAspect: CGFloat {
    switch console {
    case .gb, .gbc: return 160.0 / 144.0
    case .gba: return 240.0 / 160.0
    case .nds: return 256.0 / 192.0 // one DS LCD
    case .none: return 240.0 / 160.0
    }
  }

  private var ndsTopImage: CGImage? {
    guard let full = engine.frameImage else { return nil }
    // Expand presents a single wide top LCD; otherwise crop the stacked 256×384.
    if full.height < full.width * 3 / 2 { return full }
    return Self.cropNDS(full, top: true)
  }

  private var ndsBottomImage: CGImage? {
    if let bot = engine.ndsNativeFrame { return bot }
    guard let full = engine.frameImage else { return nil }
    return Self.cropNDS(full, top: false)
  }

  /// Delta: top inputFrame y=0 h=192, bottom y=192 h=192 of the 256×384 buffer.
  private static func cropNDS(_ image: CGImage, top: Bool) -> CGImage? {
    let w = image.width
    let h = image.height
    guard w > 0, h > 0 else { return nil }
    if h >= w * 3 / 2 {
      // Stacked framebuffer
      let half = h / 2
      let rect = CGRect(x: 0, y: top ? 0 : half, width: w, height: half)
      return image.cropping(to: rect)
    }
    return image
  }

  var body: some View {
    GeometryReader { geo in
      // Full-screen canvas (ignoresSafeArea below) so the LCD centers into side black bars.
      let size = geo.size
      let landscape = size.width > size.height
      let panes = resolvePanes(in: size)
      let folderMode = panes != nil
      let gameRect: CGRect = {
        if isNDS { return topScreenRect }
        if folderMode { return gameScreenRect }
        if skinActive { return gameScreenRect }
        return fallbackGameRect(in: size, landscape: landscape, safe: geo.safeAreaInsets)
      }()

      ZStack {
        // OLED letterbox around the LCD (pure black, not library gray).
        Color.black

        // Tracks Duo hinge division for book / tabletop layouts.
        FoldDivisionReader { rect in
          let changed = rect != foldDivision
          foldDivision = rect
          if changed {
            reloadSkin(viewSize: size, landscape: landscape, panes: resolvePanes(in: size))
          }
        }
        .allowsHitTesting(false)

        if let panes {
          // Soft hinge cue between game (top) and controls (bottom).
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(CETheme.border.opacity(0.85))
            .frame(width: panes.hinge.width * 0.42, height: max(3, min(6, panes.hinge.height * 0.35)))
            .position(x: panes.hinge.midX, y: panes.hinge.midY)
            .allowsHitTesting(false)
        }

        // Game framebuffer(s) — NDS ONE SCREEN: top LCD only; touch floats in a modal.
        // Stretch fills the band; Expand/Original keep pixel aspect (Expand still uses a full-size band for WIDE).
        let fillBand = settings.gameAspect == .stretch
        // Always CALayer — never @Published CGImage / frameSerial (that rebuilt PlayView
        // every frame and tanked GB Expand to ~40 FPS with crackly audio).
        if isNDS {
          let freezeTop = dsOneScreen && dsTouchPopupOpen && !engine.dsMenuScreen && dsFrozenTop != nil
          Group {
            if freezeTop, let frozen = dsFrozenTop {
              gameSurface(in: topScreenRect, image: frozen, fill: fillBand)
            } else {
              layerLCD(in: topScreenRect, presenter: engine.lcdTop, fill: fillBand)
            }
          }
          .onAppear { engine.updateWideView(forDisplay: topScreenRect.size) }
          .onChange(of: topScreenRect) { _, rect in engine.updateWideView(forDisplay: rect.size) }
          .onChange(of: settings.gameAspect) { _, _ in
            reloadSkin(viewSize: size, landscape: landscape, panes: panes)
            engine.updateWideView(forDisplay: topScreenRect.size)
          }
          .onChange(of: settings.zoomLevel) { _, _ in engine.updateWideView(forDisplay: topScreenRect.size) }
          .onChange(of: settings.autoZoomIn) { _, _ in engine.updateWideView(forDisplay: topScreenRect.size) }
          if !dsOneScreen {
            layerLCD(in: bottomScreenRect, presenter: engine.lcdBottom, fill: fillBand)
          }
        } else {
          // Full Expand (same as GBA): window grows in both axes so auto-zoom keeps
          // the view filled. Portrait used to be sides-only to hide Prism soft-map
          // color bars — real GB WIDE rows (Prism/Crystal/…) draw the map vertically.
          layerLCD(in: gameRect, presenter: engine.lcdTop, fill: fillBand)
            .onAppear { engine.updateWideView(forDisplay: gameRect.size, sidesOnly: false) }
            .onChange(of: gameRect) { _, rect in
              engine.updateWideView(forDisplay: rect.size, sidesOnly: false)
            }
            .onChange(of: settings.gameAspect) { _, _ in
              engine.updateWideView(forDisplay: gameRect.size, sidesOnly: false)
            }
            .onChange(of: settings.zoomLevel) { _, _ in
              engine.updateWideView(forDisplay: gameRect.size, sidesOnly: false)
            }
            .onChange(of: settings.autoZoomIn) { _, _ in
              engine.updateWideView(forDisplay: gameRect.size, sidesOnly: false)
            }
            .onChange(of: landscape) { _, _ in
              engine.updateWideView(forDisplay: gameRect.size, sidesOnly: false)
            }
        }

        // ROM failed to boot — clear message instead of a stuck spinner.
        if !engine.isRunning, !engine.isPaused,
           engine.statusText.localizedCaseInsensitiveContains("fail") {
          VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 36, weight: .semibold))
              .foregroundStyle(.yellow)
              .symbolRenderingMode(.hierarchical)
            Text(engine.statusText)
              .font(CETheme.sans(14, weight: .semibold))
              .foregroundStyle(CETheme.text)
              .multilineTextAlignment(.center)
            Text("Go back and try again, or re-import the ROM.")
              .font(CETheme.sans(12))
              .foregroundStyle(CETheme.muted)
              .multilineTextAlignment(.center)
          }
          .padding(20)
          .background(CETheme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
          .overlay(RoundedRectangle(cornerRadius: 16).stroke(CETheme.border, lineWidth: 1))
          .padding(.horizontal, 28)
          .allowsHitTesting(false)
        }

        // Skin artwork (aligned to mappingSize → view transform)
        if let rep = representation, let img = rep.assetImage {
          Image(uiImage: img)
            .resizable()
            .interpolation(.high)
            .frame(width: skinDisplayRect.width, height: skinDisplayRect.height)
            .position(x: skinDisplayRect.midX, y: skinDisplayRect.midY)
            .allowsHitTesting(false)
        }

        // Per-control overlays (Duo Folio 2: D-pad + A/B/X/Y live in separate .jxl files)
        if let rep = representation, let map = transformMap {
          ForEach(Array(rep.items.enumerated()), id: \.offset) { _, item in
            if let asset = item.assetImage {
              let r = map.viewRect(from: item.frame)
              Image(uiImage: asset)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
            }
          }
        }

        // Skin hit-testing layer
        if skinActive {
          SkinTouchRepresentable(
            representation: representation,
            transformMap: transformMap,
            onMaskChange: { engine.setMask($0) },
            onMenu: {
              withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { companionOpen = true }
            }
          )
        }

        // Same full-canvas pad as Edit Layout (normalized coords match 1:1).
        if !skinActive {
          let padVisible = isNDS ? PadControlID.ndsCases : PadControlID.gbaCases
          let padLayout = padLayouts.layout(
            landscape: landscape,
            surface: hingeClosed ? .cover : .inner
          )
          let padContainer = CGRect(origin: .zero, size: size)
          ZStack {
            // Own ObservedObject so D-pad glow doesn’t redraw the whole play canvas.
            PlayPadChrome(
              layout: padLayout,
              onKey: engine.setKey,
              onDpadMask: { engine.applyDpadMask($0) },
              visibleControls: padVisible
            )
          }
          .frame(width: padContainer.width, height: padContainer.height)
          .position(x: padContainer.midX, y: padContainer.midY)
          // Don’t steal stylus taps while the DS touch window is up.
          .allowsHitTesting(!dsTouchPopupOpen)
          .opacity(dsTouchPopupOpen ? 0.35 : 1)
        }

        // DS stylus on the always-visible bottom LCD (stacked / Duo). ONE SCREEN uses DsTouchWindow.
        if isNDS, !dsOneScreen, bottomScreenRect.width > 1, bottomScreenRect.height > 1 {
          Color.clear
            .contentShape(Rectangle())
            .frame(width: bottomScreenRect.width, height: bottomScreenRect.height)
            .position(x: bottomScreenRect.midX, y: bottomScreenRect.midY)
            .gesture(
              DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                  engine.setTouch(
                    down: true,
                    inBottomScreen: value.location,
                    screenSize: bottomScreenRect.size
                  )
                }
                .onEnded { _ in engine.releaseTouch() }
            )
        }

        // PokeDaisy ONE SCREEN: floating touch (and dual-menu) window.
        // Below chrome (zIndex) so speed / zoom / menu stay tappable while naming, etc.
        if isNDS, dsOneScreen {
          DsTouchWindow(
            open: dsTouchPopupOpen,
            dualScreens: engine.dsMenuScreen,
            loading: engine.dsTouchBlank && (engine.dsTouchWanted || engine.dsMenuScreen),
            topImage: ndsTopImage,
            bottomImage: ndsBottomImage,
            topPresenter: engine.lcdTouchTop,
            bottomPresenter: engine.lcdTouchBottom,
            smoothing: settings.smoothing,
            onDismiss: {
              if dsTouchManual {
                dsTouchManual = false
              } else {
                // Hide only — keep the in-game menu open so the top LCD stays usable.
                dsTouchSuppressed = true
              }
            },
            onClose: {
              dsTouchSuppressed = true
              dsTouchManual = false
            },
            onStylusChanged: { point, size in
              engine.setTouch(down: true, inBottomScreen: point, screenSize: size)
            },
            onStylusEnded: { engine.releaseTouch() }
          )
          .zIndex(30)
        }

        // Top chrome: back · title/route + lead sprite · edit layout · companion
        // Must sit above DsTouchWindow so HUD actions work during the touch popup.
        VStack(spacing: 0) {
          // Companion / FPS chrome observes isolated stores — not EmulatorEngine —
          // so sample + fps ticks do not rebuild the whole play surface.
          PlayCompanionStatusStrip(
            statusBarMode: settings.statusBarMode,
            coverFace: hingeClosed,
            smartBattleIsland: smartBattleIslandEnabled
          )
          HStack(alignment: .center, spacing: 8) {
            chromeButton(systemName: "chevron.left") {
              showLeaveConfirm = true
            }
            .accessibilityLabel("Back to library")
            if settings.statusBarMode != .game {
              PlayCompanionTitleChipGate(coverFace: hingeClosed)
            }
            PlayCompanionCenterChrome(
              raBanner: raHUD.banner,
              preferInlineIsland: settings.statusBarMode != .game && smartBattleIslandEnabled,
              coverFace: hingeClosed
            )
            if settings.showFps {
              FpsChromeChipView()
            }
            if chromeActionsExpanded {
              HStack(spacing: 8) {
                speedChromeButton
                if settings.gameAspect == .expand, engine.wideSupported {
                  chromeButton(systemName: "plus.magnifyingglass") {
                    engine.cycleZoom()
                  }
                  .accessibilityLabel("Cycle zoom \(engine.zoomStepTitle)")
                }
                chromeButton(systemName: settings.folderLayout ? "rectangle.split.1x2.fill" : "rectangle.split.1x2") {
                  settings.folderLayout.toggle()
                  reloadSkin(viewSize: size, landscape: landscape, panes: resolvePanes(in: size))
                }
                .accessibilityLabel(settings.folderLayout ? "Folder layout on" : "Folder layout off")
                if !skinActive {
                  chromeButton(systemName: "arrow.up.and.down.and.arrow.left.and.right") {
                    showPadEditor = true
                  }
                  .accessibilityLabel("Edit button layout")
                }
                chromeButton(systemName: companionOpen ? "xmark" : "line.3.horizontal") {
                  if !companionOpen {
                    companionPanelSize = size
                  }
                  withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    companionOpen.toggle()
                    engine.companionDrawerOpen = companionOpen
                  }
                  withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    chromeActionsExpanded = false
                  }
                }
                .accessibilityLabel("Companion menu")
              }
              .transition(
                .asymmetric(
                  insertion: .move(edge: .trailing).combined(with: .opacity).combined(with: .scale(scale: 0.88)),
                  removal: .move(edge: .trailing).combined(with: .opacity)
                )
              )
            }
            chromeButton(systemName: chromeActionsExpanded ? "chevron.right" : "chevron.left") {
              withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                chromeActionsExpanded.toggle()
              }
            }
            .accessibilityLabel(chromeActionsExpanded ? "Hide play actions" : "Show play actions")
          }
          .animation(.spring(response: 0.34, dampingFraction: 0.86), value: chromeActionsExpanded)
          .padding(.horizontal, 14)
          .padding(.top, {
            // Duo cover/outer is short — don't push the LCD down with phone-portrait chrome.
            if hingeClosed {
              return settings.statusBarMode == .game ? 4 : max(2, geo.safeAreaInsets.top)
            }
            return settings.statusBarMode == .game ? 6 : max(6, geo.safeAreaInsets.top + 2)
          }())
          .zIndex(1)

          if let notice = engine.autoSaveNotice {
            HStack(spacing: 8) {
              Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CETheme.crystal)
              Text(notice)
                .font(CETheme.sans(12, weight: .bold))
                .foregroundStyle(CETheme.text)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(CETheme.card.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(CETheme.crystal.opacity(0.65), lineWidth: 1.2))
            .shadow(color: CETheme.crystal.opacity(0.25), radius: 8, y: 2)
            .padding(.top, 8)
            .transition(
              .asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                removal: .opacity.combined(with: .scale(scale: 0.96))
              )
            )
            .allowsHitTesting(false)
          } else if let toast = engine.actionToast {
            Text(toast)
              .font(CETheme.sans(12, weight: .bold))
              .foregroundStyle(CETheme.text)
              .padding(.horizontal, 14)
              .padding(.vertical, 7)
              .background(CETheme.card.opacity(0.85), in: Capsule())
              .overlay(Capsule().stroke(CETheme.border.opacity(0.5), lineWidth: 1))
              .padding(.top, 8)
              .transition(.opacity)
              .allowsHitTesting(false)
          }

          // Pass taps through to the DS touch window / game under the chrome.
          Spacer().allowsHitTesting(false)

          if isNDS, dsOneScreen {
            HStack(spacing: 14) {
              Spacer().allowsHitTesting(false)
              dsTouchBottomButton
              Spacer().allowsHitTesting(false)
            }
            .padding(.bottom, max(18, geo.safeAreaInsets.bottom + (landscape ? 10 : 22)))
            .padding(.horizontal, 14)
          }
        }
        .padding(.leading, geo.safeAreaInsets.leading)
        .padding(.trailing, geo.safeAreaInsets.trailing)
        // Above the DS touch dim so HUD controls stay usable during naming / menus.
        .zIndex(60)

        // Movable SAVE — same normalized coords as Edit Layout (not a fixed chrome slot).
        if !skinActive {
          let saveLayout = padLayouts.layout(
            landscape: landscape,
            surface: hingeClosed ? .cover : .inner
          )
          let savePlace = saveLayout[.save]
          let saveScale = savePlace.scale
          let saveW = PadControlID.save.baseSize.width * saveScale
          let saveH = PadControlID.save.baseSize.height * saveScale
          quickSaveButton
            .frame(width: saveW, height: saveH)
            .position(x: savePlace.x * size.width, y: savePlace.y * size.height)
            .zIndex(61)
        }

        if companionOpen {
          Color.black.opacity(0.45)
            .onTapGesture {
              withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                companionOpen = false
                engine.companionDrawerOpen = false
              }
            }
            .zIndex(70)

          // Explicit Spacer layout (not trailing alignment + move transition): Duo cover→inner
          // display switches briefly report a wrong size/safe-area and the drawer would stick on the left.
          // Use frozen panel size — remounting on every geo.size tick made landscape scroll jump up.
          let panel = companionPanelSize.width > 1 ? companionPanelSize : size
          Group {
            if landscape {
              HStack(spacing: 0) {
                Spacer(minLength: 0)
                companionDrawer(height: panel.height * 0.78, width: panel.width)
                  .padding(.trailing, max(10, geo.safeAreaInsets.trailing))
                  .padding(.bottom, max(10, geo.safeAreaInsets.bottom))
              }
            } else {
              VStack(spacing: 0) {
                Spacer(minLength: 0)
                companionDrawer(height: panel.height * 0.56, width: panel.width)
                  .padding(.horizontal, max(10, min(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing)))
                  .padding(.bottom, max(10, geo.safeAreaInsets.bottom))
              }
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          // Keep companion out of inherited chrome animations (RA toast / battle tip).
          .transaction { $0.animation = nil }
          .transition(.opacity)
          .zIndex(71)
        }

        // Exit / pause leave: opaque fade so the library handoff isn’t a hard cut.
        Color.black
          .opacity(exitCoverOpacity)
          .ignoresSafeArea()
          .allowsHitTesting(exitCoverOpacity > 0.01)
          .zIndex(100)
      }
      .onAppear {
        playLandscape = landscape
        engine.companionDrawerOpen = companionOpen
        reloadSkin(viewSize: size, landscape: landscape, panes: panes)
        raHUD.start(forRom: rom.url)
      }
      .onDisappear {
        engine.companionDrawerOpen = false
        raHUD.stop()
      }
      .onChange(of: companionOpen) { _, open in
        engine.companionDrawerOpen = open
        if open {
          companionPanelSize = size
        } else {
          companionPanelSize = .zero
        }
      }
      // Do NOT attach .animation(…, value: raHUD) to this whole ZStack — it was
      // springing the landscape companion panel and making scroll jump/glitch.
      .onChange(of: geo.size) { oldSize, newSize in
        let land = newSize.width > newSize.height
        playLandscape = land
        // Cover ↔ inner (or big rotate): drop the drawer so it doesn’t remount mid-glitch on the wrong edge.
        let jumped = abs(oldSize.width - newSize.width) > 80 || abs(oldSize.height - newSize.height) > 80
        if jumped, companionOpen {
          var t = Transaction()
          t.disablesAnimations = true
          withTransaction(t) {
            companionOpen = false
            engine.companionDrawerOpen = false
            companionPanelSize = .zero
          }
        }
        reloadSkin(
          viewSize: newSize,
          landscape: land,
          panes: resolvePanes(in: newSize)
        )
      }
      .onChange(of: settings.skinsEnabled) { _, _ in
        reloadSkin(viewSize: size, landscape: landscape, panes: resolvePanes(in: size))
      }
      .onChange(of: settings.folderLayout) { _, _ in
        reloadSkin(viewSize: size, landscape: landscape, panes: resolvePanes(in: size))
      }
      .onChange(of: settings.dsLayout) { _, _ in
        reloadSkin(viewSize: size, landscape: landscape, panes: resolvePanes(in: size))
      }
      .onChange(of: settings.gameAspect) { _, _ in
        reloadSkin(viewSize: size, landscape: landscape, panes: resolvePanes(in: size))
      }
      .onChange(of: hingeClosed) { _, _ in
        if companionOpen {
          var t = Transaction()
          t.disablesAnimations = true
          withTransaction(t) {
            companionOpen = false
            engine.companionDrawerOpen = false
          }
        }
        chromeActionsExpanded = false
        // Cover ↔ inner swap: wait one turn so geo.size / safeArea settle, then rebuild LCD + pads.
        let land = size.width > size.height
        playLandscape = land
        reloadSkin(viewSize: size, landscape: land, panes: resolvePanes(in: size))
        DispatchQueue.main.async {
          let s = geo.size
          let l = s.width > s.height
          playLandscape = l
          reloadSkin(viewSize: s, landscape: l, panes: resolvePanes(in: s))
        }
      }
      .onChange(of: engine.dsTouchWanted) { _, wanted in
        if wanted, dsOneScreen, !engine.dsMenuScreen, dsFrozenTop == nil {
          dsFrozenTop = ndsTopImage
        }
        if !wanted, !engine.dsMenuScreen {
          if !dsTouchManual { dsFrozenTop = nil }
          // Auto-popup ended — clear HIDE so the next menu can show again.
          dsTouchSuppressed = false
        }
      }
      .onChange(of: engine.dsMenuScreen) { _, menu in
        if menu {
          dsFrozenTop = nil
        } else if !engine.dsTouchWanted {
          dsTouchSuppressed = false
        }
      }
      .onChange(of: dsTouchManual) { _, manual in
        if !manual, !engine.dsTouchWanted { dsFrozenTop = nil }
      }
    }
    .ignoresSafeArea()
    .navigationBarHidden(true)
    .statusBarHidden(settings.statusBarMode == .off)
    .persistentSystemOverlays(.hidden)
    .modifier(DuoHingeClosedObserver { closed in
      hingeClosed = closed
    })
    .fullScreenCover(isPresented: $showPadEditor) {
      PadLayoutEditorView(
        forceLandscape: playLandscape,
        coverFace: hingeClosed,
        ndsButtons: isNDS,
        consoleAspect: consoleAspect,
        gameAspect: settings.gameAspect,
        isPresented: $showPadEditor
      )
      .environmentObject(settings)
    }
    .sheet(isPresented: $showSaveStates) {
      SaveStateSheet()
        .environmentObject(engine)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    .confirmationDialog(
      "Leave game?",
      isPresented: $showLeaveConfirm,
      titleVisibility: .visible
    ) {
      Button("Pause & Leave") {
        engine.pause()
        leaveWithFade()
      }
      Button("Exit Completely", role: .destructive) {
        // Device hang log: `@Published` teardown + animated nav pop = AttributeGraph
        // spin (watchdog 0x8BADF00D). Halt → fade to black → unanimated pop → teardown.
        engine.beginQuit()
        leaveWithFade {
          engine.finishQuit()
        }
      }
      Button("Keep Playing", role: .cancel) {}
    } message: {
      Text("Pause keeps the game ready to resume from the library. Exit closes it completely (auto-save first).")
    }
    .onDisappear {
      // Swipe-back / any leave from play should pause, not soft-kill the session.
      if engine.isQuitting { return }
      if engine.isRunning, engine.loadedRomKey != nil {
        engine.pause()
      }
    }
  }

  /// Fade play to black, then unanimated pop (avoids AG hang from nav parallax + teardown).
  private func leaveWithFade(afterPop: (() -> Void)? = nil) {
    withAnimation(.easeIn(duration: 0.22)) {
      exitCoverOpacity = 1
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) { onLeave() }
      if let afterPop {
        DispatchQueue.main.async { afterPop() }
      }
    }
  }

  private func chromeButton(systemName: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .semibold))
        .environment(\.font, .system(size: 14, weight: .semibold))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(CETheme.text)
        .frame(width: 36, height: 36)
        .background(CETheme.card.opacity(0.55), in: Circle())
        .overlay(Circle().stroke(CETheme.border.opacity(0.55), lineWidth: 1))
    }
  }

  // FPS chip is `FpsChromeChipView` — observes `FpsBadge` only (not EmulatorEngine).

  private var speedChromeButton: some View {
    Button {
      engine.cycleSpeed()
    } label: {
      Text("\(engine.speedMultiplier)×")
        .font(CETheme.sans(12, weight: .bold))
        .foregroundStyle(engine.speedMultiplier > 1 ? CETheme.crystal : CETheme.text)
        .frame(width: 36, height: 36)
        .background(
          (engine.speedMultiplier > 1 ? CETheme.crystal.opacity(0.22) : CETheme.card.opacity(0.55)),
          in: Circle()
        )
        .overlay(
          Circle().stroke(
            engine.speedMultiplier > 1 ? CETheme.crystal.opacity(0.8) : CETheme.border.opacity(0.55),
            lineWidth: 1
          )
        )
    }
    .accessibilityLabel("Speed \(engine.speedMultiplier)×")
  }

  /// Looks like START / SELECT (wide capsule). Opens the save-state picker.
  private var quickSaveButton: some View {
    Button {
      showSaveStates = true
    } label: {
      Text("SAVE")
        .font(CETheme.sans(11, weight: .bold))
        .tracking(1.0)
        .foregroundStyle(PadStyle.label)
        .frame(width: 96, height: 38)
        .background(PadStyle.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(engine.hasAnySaveState ? CETheme.crystal.opacity(0.7) : PadStyle.stroke, lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Open save states")
  }

  /// Bottom TOUCH control — hide/show the floating second screen without closing the in-game menu.
  private var dsTouchBottomButton: some View {
    Button {
      toggleDsTouchManual()
    } label: {
      Text(dsTouchPopupOpen ? "HIDE" : "TOUCH")
        .font(CETheme.sans(11, weight: .bold))
        .tracking(1.0)
        .foregroundStyle(dsTouchPopupOpen ? CETheme.crystal : PadStyle.label)
        .frame(width: 96, height: 38)
        .background(
          (dsTouchPopupOpen ? CETheme.crystal.opacity(0.22) : PadStyle.fill),
          in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
              dsTouchPopupOpen ? CETheme.crystal.opacity(0.85) : PadStyle.stroke,
              lineWidth: 1
            )
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(dsTouchPopupOpen ? "Hide touch screen" : "Show touch screen")
  }

  private func toggleDsTouchManual() {
    if dsTouchPopupOpen {
      // Hide the float only — party / menus stay open so you can read the top LCD.
      dsTouchSuppressed = true
      dsTouchManual = false
      return
    }
    dsTouchSuppressed = false
    if !(engine.dsTouchWanted || engine.dsMenuScreen) {
      dsTouchManual = true
    }
  }

  /// Expand/Stretch play band. Portrait: letterbox to console aspect so WIDE only
  /// opens left/right (top/bottom overscan is fill-color bars, not the world).
  private func expandBand(in avail: CGRect, landscape: Bool) -> CGRect {
    if landscape { return avail }
    return aspectFit(consoleAspect, in: avail)
  }

  /// Largest 4:3 that covers `rect` (may crop edges) — fills the band without squashing pixels.
  private func aspectFill(_ aspect: CGFloat, in rect: CGRect) -> CGRect {
    let viewAspect = rect.width / max(rect.height, 1)
    if viewAspect > aspect {
      let w = rect.width
      let h = w / aspect
      return CGRect(x: rect.minX, y: rect.midY - h / 2, width: w, height: h)
    } else {
      let h = rect.height
      let w = h * aspect
      return CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)
    }
  }

  /// Duo hinge wins; Folder setting forces a book split in both orientations.
  /// Expand/Stretch only skip panes in landscape — a full-height portrait canvas makes
  /// WIDE request a too-tall window and the top/bottom map strips corrupt.
  private func resolvePanes(in size: CGSize) -> FoldPanes? {
    let landscape = size.width > size.height
    let singleLCDExpand =
      !isNDS && landscape
      && (settings.gameAspect == .expand || settings.gameAspect == .stretch)
    if singleLCDExpand { return nil }

    if let fold = foldDivision, fold.width > 8, fold.height > 1,
       let panes = FoldLayout.panes(fromDivision: fold, in: size) {
      return panes
    }
    if settings.folderLayout {
      return FoldLayout.manualSplit(in: size)
    }
    return nil
  }

  private func fallbackGameRect(in size: CGSize, landscape: Bool, safe: EdgeInsets = EdgeInsets()) -> CGRect {
    // Leave room for translucent pads; center in the full screen (including side black bars).
    // Ultra-wide Duo / closed cover: Expand must claim almost the whole canvas.
    let ultraWide = landscape && size.width / max(size.height, 1) > 1.6
    let coverFace = hingeClosed
    let statusLift: CGFloat = {
      if coverFace || ultraWide {
        return settings.statusBarMode == .game ? 28 : 4
      }
      return settings.statusBarMode == .game ? 36 : 8
    }()
    let top: CGFloat = {
      if coverFace || ultraWide {
        // Short outer face — keep the LCD flush under chrome instead of a phone-portrait band.
        return statusLift + max(0, safe.top * 0.15)
      }
      return max(48, size.height * 0.06) + statusLift + (landscape ? 0 : max(0, safe.top * 0.25))
    }()
    switch settings.gameAspect {
    case .expand:
      // Nearly full stage so WIDE can grow left/right; pads overlay the edges.
      // Portrait (cover + phone): cap height to Android's upright Expand profile so
      // top/bottom map rebuild stays valid — see WideCameraMath.effectiveViewSize.
      let sidePad: CGFloat = (ultraWide || coverFace) ? 4 : (landscape ? 6 : 4)
      let bottomReserve: CGFloat = {
        if ultraWide || coverFace { return max(24, size.height * 0.05) }
        return landscape ? size.height * 0.08 : size.height * 0.22
      }()
      let avail = CGRect(
        x: sidePad,
        y: top,
        width: max(80, size.width - sidePad * 2),
        height: max(80, size.height - top - bottomReserve)
      )
      return expandBand(in: avail, landscape: landscape)
    case .stretch:
      // Same large band as Expand — Stretch only changes pixel fill (squash allowed).
      let sidePad: CGFloat = (ultraWide || coverFace) ? 4 : (landscape ? 6 : 4)
      let bottomReserve: CGFloat = {
        if ultraWide || coverFace { return max(24, size.height * 0.05) }
        return landscape ? size.height * 0.08 : size.height * 0.22
      }()
      let avail = CGRect(
        x: sidePad,
        y: top,
        width: max(80, size.width - sidePad * 2),
        height: max(80, size.height - top - bottomReserve)
      )
      return expandBand(in: avail, landscape: landscape)
    case .original:
      // Ultra-wide Duo: still maximize the LCD (letterboxed), don’t leave a tiny left postage stamp.
      let bottomReserve: CGFloat = {
        if ultraWide || coverFace { return size.height * 0.08 }
        return landscape ? size.height * 0.14 : size.height * 0.38
      }()
      let sidePad: CGFloat = {
        if ultraWide || coverFace { return max(16, size.width * 0.04) }
        return landscape ? max(96, size.width * 0.20) : 12
      }()
      let available = CGRect(
        x: sidePad,
        y: top,
        width: size.width - sidePad * 2,
        height: max(80, size.height - top - bottomReserve)
      )
      return aspectFit(consoleAspect, in: available)
    }
  }

  private func aspectFit(_ aspect: CGFloat, in rect: CGRect) -> CGRect {
    let viewAspect = rect.width / max(rect.height, 1)
    if viewAspect > aspect {
      let h = rect.height
      let w = h * aspect
      return CGRect(x: rect.midX - w / 2, y: rect.minY, width: w, height: h)
    } else {
      let w = rect.width
      let h = w / aspect
      return CGRect(x: rect.minX, y: rect.midY - h / 2, width: w, height: h)
    }
  }

  @ViewBuilder
  private func layerLCD(in rect: CGRect, presenter: LCDPresenter, fill: Bool) -> some View {
    LCDViewRepresentable(presenter: presenter, fill: fill)
      .frame(width: max(0, rect.width), height: max(0, rect.height))
      .clipped()
      .background(Color.black)
      .position(x: rect.midX, y: rect.midY)
      .allowsHitTesting(false)
      .opacity(rect.width > 1 && rect.height > 1 ? 1 : 0)
  }

  @ViewBuilder
  private func gameSurface(in rect: CGRect, image: CGImage?, fill: Bool = false) -> some View {
    ZStack(alignment: .topLeading) {
      Color.black.opacity(0.001) // keep hit-free layout size
      if rect.width > 1, rect.height > 1, let image {
        // Expand: place the WIDE buffer at Android's exact pixel scale + offX/offY so the
        // original 240×160 frame edge stays on whole screen pixels (no seam shimmer).
        if settings.gameAspect == .expand, engine.wideSupported, let place = engine.widePlacement {
          let ns = max(WideCameraMath.nativeScale(), 1)
          // scale: so one game pixel = place.scale screen pixels (Android windowQuad).
          // Round offsets to whole points — fractional SwiftUI offsets reintroduce seam shimmer.
          Image(decorative: image, scale: ns / max(place.scale, 0.01))
            .interpolation(.none)
            .offset(x: (place.offX / ns).rounded(.toNearestOrAwayFromZero),
                    y: (place.offY / ns).rounded(.toNearestOrAwayFromZero))
        } else {
          Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(settings.smoothing == .soft ? .medium : .none)
            // Expand/Original: scale up to the largest size that fits the band (no squash).
            // Stretch: fill the band (may squash).
            .aspectRatio(contentMode: fill ? .fill : .fit)
            .frame(width: rect.width, height: rect.height)
        }
        GameShaderOverlay(
          filter: settings.screenFilter,
          grid: settings.gridStrength,
          pixelSize: CGSize(width: rect.width, height: rect.height)
        )
        .frame(width: rect.width, height: rect.height)
        .allowsHitTesting(false)
      } else if rect.width > 1, rect.height > 1 {
        ProgressView().tint(CETheme.accent)
      }
    }
    .frame(width: max(0, rect.width), height: max(0, rect.height), alignment: .topLeading)
    .clipped()
    .background(Color.black)
    .clipShape(Rectangle())
    .position(x: rect.midX, y: rect.midY)
    .allowsHitTesting(false)
    .opacity(rect.width > 1 && rect.height > 1 ? 1 : 0)
  }

  private func companionDrawer(height: CGFloat, width: CGFloat) -> some View {
    let panelWidth = min(380, width * 0.92)
    return CompanionDrawerView(onClose: {
      withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { companionOpen = false }
    })
    .frame(width: panelWidth, height: height)
    .background(CETheme.elevated)
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(CETheme.border, lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
  }

  private func reloadSkin(viewSize: CGSize, landscape: Bool, panes: FoldPanes?) {
    if console == .nds {
      reloadNDSLayout(viewSize: viewSize, landscape: landscape, panes: panes)
      return
    }

    // Folder / Duo book: LCD on game pane (top or left), skin or pad on the other pane.
    if let panes {
      let topPlay = panes.top.insetBy(dx: 8, dy: 8)
      switch settings.gameAspect {
      case .original:
        gameScreenRect = aspectFit(consoleAspect, in: topPlay)
      case .stretch, .expand:
        // Game page (top/left). Portrait letterboxes to console aspect (sides-only Expand).
        gameScreenRect = expandBand(in: topPlay, landscape: landscape)
      }
      topScreenRect = .zero
      bottomScreenRect = .zero

      guard let console,
            let skin = DeltaSkinManager.activeSkin(for: console),
            let rep = DeltaSkinParser.loadRepresentation(
              skinDir: skin.extractedDirectory,
              landscape: false, // control deck reads portrait skin into the lower pane
              viewSize: panes.bottom.size,
              preferCoverLayout: hingeClosed
            ) else {
        representation = nil
        transformMap = nil
        skinDisplayRect = .zero
        return
      }

      let map = SkinViewTransform(
        mappingSize: rep.mappingSize,
        viewSize: panes.bottom.size,
        fill: false,
        in: panes.bottom
      )
      representation = rep
      transformMap = map
      skinDisplayRect = map.displayRect
      return
    }

    guard let console,
          let skin = DeltaSkinManager.activeSkin(for: console),
          let rep = DeltaSkinParser.loadRepresentation(
            skinDir: skin.extractedDirectory,
            landscape: landscape,
            viewSize: viewSize,
            preferCoverLayout: hingeClosed
          ) else {
      representation = nil
      transformMap = nil
      gameScreenRect = fallbackGameRect(in: viewSize, landscape: landscape)
      topScreenRect = .zero
      bottomScreenRect = .zero
      skinDisplayRect = CGRect(origin: .zero, size: viewSize)
      return
    }

    // Match Delta: aspect-fit mappingSize, then place outputFrame inside that rect.
    let map = SkinViewTransform(mappingSize: rep.mappingSize, viewSize: viewSize, fill: false)
    representation = rep
    transformMap = map
    skinDisplayRect = map.displayRect
    if let screen = rep.screenFrame {
      gameScreenRect = map.viewRect(from: screen)
    } else {
      gameScreenRect = fallbackGameRect(in: viewSize, landscape: landscape)
    }
    topScreenRect = .zero
    bottomScreenRect = .zero
  }

  /// PokeDaisy DS LAYOUT: dual-screen skin (Duo Folio) beats ONE SCREEN; else float / stacked.
  private func reloadNDSLayout(viewSize: CGSize, landscape: Bool, panes: FoldPanes?) {
    let lcdAspect = 256.0 / 192.0

    // Dual-screen Delta skins (Duo Folio inner/outer) — disables ONE SCREEN float while active.
    if settings.skinsEnabled,
       let console,
       let skin = DeltaSkinManager.activeSkin(for: console),
       let rep = DeltaSkinParser.loadRepresentation(
         skinDir: skin.extractedDirectory,
         landscape: landscape,
         viewSize: viewSize,
         preferCoverLayout: hingeClosed
       ),
       rep.screens.count >= 1 {
      let map = SkinViewTransform(mappingSize: rep.mappingSize, viewSize: viewSize, fill: false)
      if rep.screens.count >= 2 {
        let top = map.viewRect(from: rep.screens[0].outputFrame)
        let bot = map.viewRect(from: rep.screens[1].outputFrame)
        if top.width > 40, top.height > 40, bot.width > 40, bot.height > 40,
           abs(top.midY - bot.midY) > 20 || abs(top.midX - bot.midX) > 20 {
          representation = rep
          transformMap = map
          skinDisplayRect = map.displayRect
          topScreenRect = top
          bottomScreenRect = bot
          gameScreenRect = top.union(bot)
          return
        }
      }
      // Single usable screen in the skin (e.g. outer face) — show that LCD full in its hole.
      if let only = rep.screens.first {
        let frame = map.viewRect(from: only.outputFrame)
        if frame.width > 40, frame.height > 40 {
          representation = rep
          transformMap = map
          skinDisplayRect = map.displayRect
          let isBottom = (only.inputFrame?.y ?? 0) >= 100
          if isBottom {
            topScreenRect = .zero
            bottomScreenRect = frame
          } else {
            topScreenRect = frame
            bottomScreenRect = .zero
          }
          gameScreenRect = frame
          return
        }
      }
    }

    representation = nil
    transformMap = nil
    skinDisplayRect = .zero

    // Duo book / Folder: top LCD upper pane; touch LCD + pad strip in lower pane.
    if let panes {
      let topPlay = panes.top.insetBy(dx: 8, dy: 8)
      switch settings.gameAspect {
      case .expand, .stretch:
        // Fill the upper pane so Expand can grow left/right on a wide Duo page.
        topScreenRect = topPlay
      case .original:
        topScreenRect = aspectFit(lcdAspect, in: topPlay)
      }

      let touchBandH = min(panes.bottom.height * 0.42, (panes.bottom.width - 24) * 192.0 / 256.0)
      let touchBand = CGRect(
        x: panes.bottom.minX + 12,
        y: panes.bottom.minY + 6,
        width: panes.bottom.width - 24,
        height: max(60, touchBandH)
      )
      bottomScreenRect = aspectFit(lcdAspect, in: touchBand)
      gameScreenRect = topScreenRect.union(bottomScreenRect)
      return
    }

    let statusLift: CGFloat = settings.statusBarMode == .game ? 36 : 8
    let topChrome: CGFloat = max(52, viewSize.height * 0.06) + statusLift
    let gap: CGFloat = landscape ? 8 : 12

    // ONE SCREEN fallback (no dual-screen skin active).
    if settings.dsLayout == .oneScreen {
      switch settings.gameAspect {
      case .expand:
        // Nearly full stage — pads overlay. Wide/ultrawide so WIDE grows left+right, not only up/down.
        let sidePad: CGFloat = landscape ? 6 : 4
        let bottomReserve: CGFloat = landscape ? 36 : max(88, viewSize.height * 0.18)
        let play = CGRect(
          x: sidePad,
          y: topChrome,
          width: max(80, viewSize.width - sidePad * 2),
          height: max(120, viewSize.height - topChrome - bottomReserve)
        )
        topScreenRect = play
      case .stretch:
        // Fill the center column (may squash). Side gutters stay clear for controls.
        let sidePad = landscape ? max(100, viewSize.width * 0.20) : 10
        let bottomReserve: CGFloat = landscape ? 48 : max(120, viewSize.height * 0.26)
        let play = CGRect(
          x: sidePad,
          y: topChrome,
          width: max(80, viewSize.width - sidePad * 2),
          height: max(120, viewSize.height - topChrome - bottomReserve)
        )
        topScreenRect = play
      case .original:
        // True 4:3 letterboxed in the center column — never squash or crop.
        let sidePad = landscape ? max(100, viewSize.width * 0.20) : 10
        let bottomReserve: CGFloat = landscape ? 48 : max(120, viewSize.height * 0.26)
        let play = CGRect(
          x: sidePad,
          y: topChrome,
          width: max(80, viewSize.width - sidePad * 2),
          height: max(120, viewSize.height - topChrome - bottomReserve)
        )
        topScreenRect = aspectFit(lcdAspect, in: play)
      }
      bottomScreenRect = .zero
      gameScreenRect = topScreenRect
      return
    }

    if landscape {
      // Side gutters for controls; stacked LCDs centered in the middle column.
      let sidePad = max(110, viewSize.width * 0.22)
      let bottomChrome: CGFloat = 56
      let col = CGRect(
        x: sidePad,
        y: topChrome,
        width: max(80, viewSize.width - sidePad * 2),
        height: max(100, viewSize.height - topChrome - bottomChrome)
      )
      let eachH = (col.height - gap) * 0.5
      let topBand = CGRect(x: col.minX, y: col.minY, width: col.width, height: eachH)
      let botBand = CGRect(x: col.minX, y: col.minY + eachH + gap, width: col.width, height: eachH)
      switch settings.gameAspect {
      case .expand, .stretch:
        // Give Soft Expand the full upper band so zoom can grow L/R.
        topScreenRect = topBand
        bottomScreenRect = aspectFit(lcdAspect, in: botBand)
      case .original:
        topScreenRect = aspectFit(lcdAspect, in: topBand)
        bottomScreenRect = aspectFit(lcdAspect, in: botBand)
      }
      gameScreenRect = topScreenRect.union(bottomScreenRect)
      return
    }

    // Flat portrait: two LCDs stacked, pad strip underneath.
    let padReserve = max(150, viewSize.height * 0.32)
    let availableH = max(140, viewSize.height - topChrome - padReserve - gap)
    let eachH = availableH * 0.5
    let sidePad: CGFloat = 18
    let bandW = viewSize.width - sidePad * 2
    let topBand = CGRect(x: sidePad, y: topChrome, width: bandW, height: eachH)
    let botBand = CGRect(x: sidePad, y: topChrome + eachH + gap, width: bandW, height: eachH)
    topScreenRect = aspectFit(lcdAspect, in: topBand)
    bottomScreenRect = aspectFit(lcdAspect, in: botBand)
    gameScreenRect = topScreenRect.union(bottomScreenRect)
  }
}

// MARK: - Play pad (visuals isolated from EmulatorEngine publishes)

private struct PlayPadChrome: View {
  let layout: TouchPadLayout
  let onKey: (UInt32, Bool) -> Void
  let onDpadMask: (UInt32) -> Void
  let visibleControls: [PadControlID]
  @ObservedObject private var pressed = PadPressedStore.shared

  var body: some View {
    ZStack {
      CustomizableVirtualPad(
        layout: layout,
        isEditing: false,
        onKey: onKey,
        onDpadMask: onDpadMask,
        handlesTouches: false,
        pressedMask: pressed.mask,
        visibleControls: visibleControls
      )
      PadTouchRepresentable(
        layout: layout,
        onKey: onKey,
        onDpadMask: onDpadMask,
        visibleControls: visibleControls
      )
      .contentShape(Rectangle())
    }
  }
}

// MARK: - Isolated HUD (companion / FPS) — do not observe EmulatorEngine here

private struct PlayCompanionStatusStrip: View {
  @ObservedObject private var live = CompanionLiveStore.shared
  let statusBarMode: StatusBarMode
  var coverFace: Bool = false
  var smartBattleIsland: Bool = true

  private var leadMon: Mon? {
    live.snapshot?.party.first(where: { !$0.isEgg && $0.species > 0 })
      ?? live.snapshot?.party.first
  }

  private var location: String? {
    if let name = live.snapshot?.mapSecName, !name.isEmpty { return name }
    guard let snap = live.snapshot else { return nil }
    if snap.mapGroup != 0 || snap.mapNum != 0 {
      return "Map \(snap.mapGroup)-\(snap.mapNum)"
    }
    return nil
  }

  var body: some View {
    if statusBarMode == .game {
      GameStatusBarStrip(
        location: location,
        money: live.snapshot?.money,
        inBattle: live.snapshot?.inBattle == true,
        lead: leadMon,
        tables: live.snapshot?.tables ?? .retail,
        advice: smartBattleIsland ? live.islandAdvice : nil,
        preferCompactIsland: coverFace,
        onCycleIslandTip: smartBattleIsland ? { live.cycleIslandTip() } : nil
      )
    }
  }
}

/// Hides the route/lead chip on Duo cover when the island is coaching (battle or field).
private struct PlayCompanionTitleChipGate: View {
  @ObservedObject private var live = CompanionLiveStore.shared
  var coverFace: Bool

  var body: some View {
    let islandBusy = coverFace && live.islandAdvice != nil
    if islandBusy {
      EmptyView()
    } else {
      PlayCompanionTitleChip()
    }
  }
}

private struct PlayCompanionTitleChip: View {
  @ObservedObject private var live = CompanionLiveStore.shared

  private var leadMon: Mon? {
    live.snapshot?.party.first(where: { !$0.isEgg && $0.species > 0 })
      ?? live.snapshot?.party.first
  }

  private var location: String? {
    if let name = live.snapshot?.mapSecName, !name.isEmpty { return name }
    guard let snap = live.snapshot else { return nil }
    if snap.mapGroup != 0 || snap.mapNum != 0 {
      return "Map \(snap.mapGroup)-\(snap.mapNum)"
    }
    return nil
  }

  var body: some View {
    PlayTitleChip(
      location: location,
      lead: leadMon,
      tables: live.snapshot?.tables ?? .retail,
      inBattle: live.snapshot?.inBattle == true
    )
  }
}

private struct PlayCompanionCenterChrome: View {
  @ObservedObject private var live = CompanionLiveStore.shared
  let raBanner: RetroAchievementsPlayHUD.Banner?
  /// When false, the full game status bar already hosts the island — avoid a duplicate.
  var preferInlineIsland: Bool = true
  /// Duo front/cover — keep Smart Battle Island on the short face.
  var coverFace: Bool = false

  var body: some View {
    if let raBanner {
      RAAchievementChip(banner: raBanner)
        .frame(maxWidth: .infinity)
        .layoutPriority(-1)
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.88).combined(with: .opacity).combined(with: .move(edge: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96))
          )
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: raBanner.id)
    } else if preferInlineIsland, let advice = live.islandAdvice {
      SmartBattleIsland(
        advice: advice,
        preferCompact: coverFace,
        onCycleTip: { live.cycleIslandTip() }
      )
        .frame(maxWidth: .infinity)
        .layoutPriority(-1)
        .transition(.asymmetric(
          insertion: .scale(scale: 0.94).combined(with: .opacity),
          removal: .opacity
        ))
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: advice.headline)
    } else if preferInlineIsland, let epi = live.battleEpilogue {
      Text(epi)
        .font(CETheme.sans(coverFace ? 11 : 13, weight: .bold))
        .foregroundStyle(CETheme.text)
        .lineLimit(2)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, coverFace ? 8 : 10)
        .frame(maxWidth: .infinity)
        .background(CETheme.card.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(CETheme.crystal.opacity(0.55), lineWidth: 1))
        .layoutPriority(-1)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: epi)
    } else {
      Spacer(minLength: 8)
    }
  }
}

struct FpsChromeChipView: View {
  @ObservedObject private var badge = FpsBadge.shared

  var body: some View {
    let n = badge.value
    let tint: Color = n >= 55 ? CETheme.crystal : (n >= 40 ? CETheme.accent : Color(red: 1, green: 0.35, blue: 0.32))
    return Text("\(n)")
      .font(CETheme.mono(11))
      .fontWeight(.bold)
      .foregroundStyle(tint)
      .frame(minWidth: 36, minHeight: 36)
      .padding(.horizontal, n >= 100 ? 4 : 0)
      .background(CETheme.card.opacity(0.55), in: Capsule())
      .overlay(Capsule().stroke(tint.opacity(0.55), lineWidth: 1))
      .accessibilityLabel("\(n) frames per second")
      .allowsHitTesting(false)
  }
}

