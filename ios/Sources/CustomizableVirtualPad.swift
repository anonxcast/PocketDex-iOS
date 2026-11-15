import SwiftUI

enum PadStyle {
  static let fill = Color.black.opacity(0.58)
  static let stroke = Color.white.opacity(0.28)
  static let label = Color.white.opacity(0.92)
  static let editStroke = Color(red: 0.88, green: 0.88, blue: 0.88)
}

enum GbaKey {
  static let a: UInt32 = 1 << 0
  static let b: UInt32 = 1 << 1
  static let select: UInt32 = 1 << 2
  static let start: UInt32 = 1 << 3
  static let right: UInt32 = 1 << 4
  static let left: UInt32 = 1 << 5
  static let up: UInt32 = 1 << 6
  static let down: UInt32 = 1 << 7
  static let r: UInt32 = 1 << 8
  static let l: UInt32 = 1 << 9
  static let x: UInt32 = 1 << 10
  static let y: UInt32 = 1 << 11
}

private struct PressGestureModifier: ViewModifier {
  let enabled: Bool
  let bit: UInt32
  let onKey: (UInt32, Bool) -> Void

  func body(content: Content) -> some View {
    if enabled {
      content.gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .onChanged { _ in onKey(bit, true) }
          .onEnded { _ in onKey(bit, false) }
      )
    } else {
      content
    }
  }
}

/// Free-layout virtual pad. In edit mode, drag controls; Save / Exit live in `PadLayoutEditorView`.
struct CustomizableVirtualPad: View {
  let layout: TouchPadLayout
  let isEditing: Bool
  var selected: PadControlID? = nil
  let onKey: (UInt32, Bool) -> Void
  let onDpadMask: (UInt32) -> Void
  var onSelect: ((PadControlID) -> Void)? = nil
  var onMove: ((PadControlID, CGPoint) -> Void)? = nil
  /// When false, visuals only — UIKit `PadTouchRepresentable` owns hit-testing (snappier + larger targets).
  var handlesTouches: Bool = true
  /// Which controls to draw (GBA omits X/Y; NDS includes them).
  var visibleControls: [PadControlID] = PadControlID.gbaCases

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      ZStack {
        ForEach(visibleControls) { id in
          let place = layout[id]
          let px = place.x * size.width
          let py = place.y * size.height
          positionedControl(id, at: CGPoint(x: px, y: py), canvas: size)
        }
        if !isEditing && handlesTouches {
          Color.clear
            .allowsHitTesting(false)
        }
      }
      .frame(width: size.width, height: size.height)
      .coordinateSpace(name: "padCanvas")
    }
  }

  @ViewBuilder
  private func positionedControl(_ id: PadControlID, at point: CGPoint, canvas: CGSize) -> some View {
    let visual = controlView(id)
      .contentShape(Rectangle())
      .position(x: point.x, y: point.y)
    if isEditing {
      visual
        .highPriorityGesture(editDrag(id: id, canvas: canvas))
        .onTapGesture { onSelect?(id) }
    } else {
      visual.allowsHitTesting(handlesTouches)
    }
  }

  @ViewBuilder
  private func controlView(_ id: PadControlID) -> some View {
    let place = layout[id]
    let base = id.baseSize
    let w = base.width * place.scale
    let h = base.height * place.scale
    let highlighted = isEditing && selected == id
    let touch = handlesTouches && !isEditing

    Group {
      switch id {
      case .dpad:
        SlidingDPad(onMask: onDpadMask, size: w, interactive: touch)
          .frame(width: w, height: h)
          .contentShape(Rectangle())
      case .a:
        faceLabel("A", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.a, interactive: touch)
      case .b:
        faceLabel("B", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.b, interactive: touch)
      case .x:
        faceLabel("X", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.x, interactive: touch)
      case .y:
        faceLabel("Y", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.y, interactive: touch)
      case .start:
        faceLabel("START", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.start, fontSize: 10, interactive: touch)
      case .select:
        faceLabel("SELECT", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.select, fontSize: 10, interactive: touch)
      case .l:
        faceLabel("L", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.l, fontSize: 14, interactive: touch)
      case .r:
        faceLabel("R", width: w, height: h, corner: id.cornerRadius * place.scale, bit: GbaKey.r, fontSize: 14, interactive: touch)
      }
    }
    .overlay {
      if highlighted {
        RoundedRectangle(cornerRadius: max(8, id.cornerRadius * place.scale), style: .continuous)
          .stroke(PadStyle.editStroke, lineWidth: 2)
          .frame(width: w + 6, height: h + 6)
      }
    }
  }

  private func faceLabel(
    _ text: String,
    width: CGFloat,
    height: CGFloat,
    corner: CGFloat,
    bit: UInt32,
    fontSize: CGFloat = 18,
    interactive: Bool
  ) -> some View {
    Text(text)
      .font(CETheme.sans(fontSize, weight: .bold))
      .foregroundStyle(PadStyle.label)
      .frame(width: width, height: height)
      .background(PadStyle.fill, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: corner, style: .continuous)
          .stroke(PadStyle.stroke, lineWidth: 1)
      )
      .modifier(PressGestureModifier(enabled: interactive, bit: bit, onKey: onKey))
  }

  private func editDrag(id: PadControlID, canvas: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("padCanvas"))
      .onChanged { value in
        guard canvas.width > 0, canvas.height > 0 else { return }
        let nx = value.location.x / canvas.width
        let ny = value.location.y / canvas.height
        onMove?(id, CGPoint(x: nx, y: ny))
      }
  }
}

// MARK: - Sliding D-pad (chevron cross — previous look)

struct SlidingDPad: View {
  let onMask: (UInt32) -> Void
  var size: CGFloat = 150
  /// When false (layout editor), no directional gesture so the parent can drag the whole pad.
  var interactive: Bool = true
  @State private var activeMask: UInt32 = 0

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
        .fill(PadStyle.fill)
        .overlay(
          RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
            .stroke(PadStyle.stroke, lineWidth: 1)
        )

      VStack(spacing: 0) {
        chevron("chevron.up", lit: (activeMask & GbaKey.up) != 0)
        Spacer(minLength: 0)
        chevron("chevron.down", lit: (activeMask & GbaKey.down) != 0)
      }
      .padding(.vertical, size * 0.093)
      .frame(width: size, height: size)

      HStack(spacing: 0) {
        chevron("chevron.left", lit: (activeMask & GbaKey.left) != 0)
        Spacer(minLength: 0)
        chevron("chevron.right", lit: (activeMask & GbaKey.right) != 0)
      }
      .padding(.horizontal, size * 0.093)
      .frame(width: size, height: size)

      Circle()
        .stroke(Color.white.opacity(0.22), lineWidth: 1)
        .frame(width: size * 0.24, height: size * 0.24)
    }
    .frame(width: size, height: size)
    .contentShape(Rectangle())
    .gesture(interactive ? dpadGesture : nil)
  }

  private func chevron(_ name: String, lit: Bool) -> some View {
    Image(systemName: name)
      .font(.system(size: size * 0.133, weight: .bold))
      .foregroundStyle(PadStyle.label.opacity(lit ? 1.0 : 0.75))
      .frame(width: size * 0.293, height: size * 0.293)
  }

  private var dpadGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .local)
      .onChanged { value in
        let next = Self.mask(at: value.location, size: size)
        if next != activeMask {
          activeMask = next
          onMask(next)
        }
      }
      .onEnded { _ in
        activeMask = 0
        onMask(0)
      }
  }

  static func mask(at point: CGPoint, size: CGFloat) -> UInt32 {
    let mid = size / 2
    let dx = point.x - mid
    let dy = point.y - mid
    let dead = size * 0.093
    if abs(dx) < dead && abs(dy) < dead { return 0 }

    var mask: UInt32 = 0
    let axisBias: CGFloat = 0.55
    if abs(dy) >= dead && (abs(dy) >= abs(dx) * axisBias || abs(dx) < dead) {
      mask |= dy < 0 ? GbaKey.up : GbaKey.down
    }
    if abs(dx) >= dead && (abs(dx) >= abs(dy) * axisBias || abs(dy) < dead) {
      mask |= dx < 0 ? GbaKey.left : GbaKey.right
    }
    if mask == 0 {
      if abs(dy) >= abs(dx) {
        mask = dy < 0 ? GbaKey.up : GbaKey.down
      } else {
        mask = dx < 0 ? GbaKey.left : GbaKey.right
      }
    }
    return mask
  }
}

// MARK: - Editor screen

struct PadLayoutEditorView: View {
  @ObservedObject private var store = TouchPadLayoutStore.shared
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var settings: AppSettings

  /// When true, X/Y are editable (same set as DS play).
  var ndsButtons: Bool = false
  /// Native LCD aspect (GB 160/144, GBA 240/160, NDS 256/192).
  var consoleAspect: CGFloat = 240.0 / 160.0
  var gameAspect: GameAspectMode = .expand
  /// Parent binding — more reliable than dismiss() alone inside fullScreenCover.
  var isPresented: Binding<Bool>? = nil

  @State private var draft: TouchPadLayout
  @State private var baseline: TouchPadLayout
  @State private var selected: PadControlID? = .start
  @State private var showExitPrompt = false
  @State private var landscape: Bool

  init(
    forceLandscape: Bool? = nil,
    ndsButtons: Bool = false,
    consoleAspect: CGFloat = 240.0 / 160.0,
    gameAspect: GameAspectMode = .expand,
    isPresented: Binding<Bool>? = nil
  ) {
    let isLandscape = forceLandscape ?? false
    let saved = TouchPadLayoutStore.shared.layout(landscape: isLandscape)
    self.ndsButtons = ndsButtons
    self.consoleAspect = consoleAspect
    self.gameAspect = gameAspect
    self.isPresented = isPresented
    _landscape = State(initialValue: isLandscape)
    _draft = State(initialValue: saved)
    _baseline = State(initialValue: saved)
  }

  private func closeEditor() {
    if let isPresented {
      isPresented.wrappedValue = false
    } else {
      dismiss()
    }
  }

  private var isDirty: Bool { draft != baseline }
  private var visibleControls: [PadControlID] {
    ndsButtons ? PadControlID.ndsCases : PadControlID.gbaCases
  }

  var body: some View {
    // Full-screen pad canvas (same size as PlayView) so normalized coords match 1:1.
    // Chrome overlays the top — it must not shrink the pad GeometryReader.
    GeometryReader { geo in
      let isLand = geo.size.width > geo.size.height
      let size = geo.size
      ZStack {
        CETheme.bg

        editorScreenPlaceholders(size: size, landscape: isLand)
          .allowsHitTesting(false)

        Text("Drag buttons — same canvas as in play")
          .font(CETheme.sans(12, weight: .medium))
          .foregroundStyle(CETheme.muted)
          .padding(.horizontal, 14)
          .padding(.vertical, 7)
          .background(CETheme.card.opacity(0.85), in: Capsule())
          .position(x: size.width / 2, y: min(size.height * 0.22, 140))
          .allowsHitTesting(false)

        CustomizableVirtualPad(
          layout: draft,
          isEditing: true,
          selected: selected,
          onKey: { _, _ in },
          onDpadMask: { _ in },
          onSelect: { selected = $0 },
          onMove: { id, point in
            draft.move(id, toNormalized: point)
          },
          visibleControls: visibleControls
        )
        .frame(width: size.width, height: size.height)

        // Overlay chrome — does not affect pad coordinate space.
        VStack(spacing: 0) {
          editorChrome
            .padding(.top, max(8, geo.safeAreaInsets.top))
          if let selected, visibleControls.contains(selected) {
            scaleBar(for: selected)
          }
          Spacer(minLength: 0)
        }
        .zIndex(80)
      }
      .onAppear {
        syncOrientation(isLand)
        if let selected, !visibleControls.contains(selected) {
          self.selected = .a
        }
      }
      .onChange(of: isLand) { _, newValue in
        handleOrientationChange(newValue)
      }
    }
    .ignoresSafeArea()
    .background(CETheme.bg.ignoresSafeArea())
    .navigationBarHidden(true)
    .statusBarHidden(false)
    .alert("Discard changes?", isPresented: $showExitPrompt) {
      Button("Discard", role: .destructive) {
        closeEditor()
      }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("Throw away your layout edits and leave the editor?")
    }
  }

  /// Mirrors PlayView `fallbackGameRect` for the active console + aspect mode.
  @ViewBuilder
  private func editorScreenPlaceholders(size: CGSize, landscape: Bool) -> some View {
    let lcdAspect = consoleAspect
    let statusLift: CGFloat = 52
    let ultraWide = landscape && size.width / max(size.height, 1) > 1.6
    let aspect = settings.gameAspect
    switch aspect {
    case .expand, .stretch:
      let sidePad: CGFloat = ultraWide ? 4 : (landscape ? 6 : 4)
      let bottomReserve: CGFloat = {
        if ultraWide { return max(28, size.height * 0.06) }
        if landscape { return size.height * 0.08 }
        return ndsButtons ? max(88, size.height * 0.18) : size.height * 0.22
      }()
      let col = CGRect(
        x: sidePad,
        y: statusLift,
        width: max(80, size.width - sidePad * 2),
        height: max(80, size.height - statusLift - bottomReserve)
      )
      // Same full Expand/Stretch band as PlayView (WIDE target); pads align to this canvas.
      placeholderLCD(in: col, aspect: lcdAspect, label: "GAME", fit: false)
    case .original:
      let bottomReserve: CGFloat = landscape ? size.height * 0.14 : size.height * 0.38
      let sidePad: CGFloat = landscape ? max(96, size.width * 0.20) : 12
      let avail = CGRect(
        x: sidePad,
        y: statusLift,
        width: size.width - sidePad * 2,
        height: max(80, size.height - statusLift - bottomReserve)
      )
      placeholderLCD(in: avail, aspect: lcdAspect, label: "GAME", fit: true)
    }
  }

  private func placeholderLCD(in band: CGRect, aspect: CGFloat, label: String, fit: Bool) -> some View {
    let rect: CGRect = {
      if !fit { return band }
      let viewAspect = band.width / max(band.height, 1)
      if viewAspect > aspect {
        let h = band.height
        let w = h * aspect
        return CGRect(x: band.midX - w / 2, y: band.minY, width: w, height: h)
      }
      let w = band.width
      let h = w / aspect
      return CGRect(x: band.minX, y: band.midY - h / 2, width: w, height: h)
    }()
    return RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(Color.white.opacity(0.06))
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
      )
      .overlay(
        Text(label)
          .font(CETheme.sans(11, weight: .bold))
          .foregroundStyle(CETheme.muted.opacity(0.7))
      )
      .frame(width: rect.width, height: rect.height)
      .position(x: rect.midX, y: rect.midY)
  }

  private var editorChrome: some View {
    HStack(spacing: 10) {
      Button {
        commitSave()
        closeEditor()
      } label: {
        Text("Save & Exit")
          .font(CETheme.sans(14, weight: .bold))
          .foregroundStyle(Color.black)
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background(CETheme.crystal, in: Capsule())
          .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Save and exit")

      Spacer(minLength: 8)

      VStack(spacing: 2) {
        Text("Edit Layout")
          .font(CETheme.sans(15, weight: .bold))
          .foregroundStyle(CETheme.text)
        Text(landscape ? "Landscape" : "Portrait")
          .font(CETheme.sans(11, weight: .medium))
          .foregroundStyle(CETheme.muted)
      }
      .layoutPriority(-1)
      .allowsHitTesting(false)

      Spacer(minLength: 8)

      Button {
        if isDirty {
          showExitPrompt = true
        } else {
          closeEditor()
        }
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(CETheme.text)
          .frame(width: 36, height: 36)
          .background(CETheme.card.opacity(0.9), in: Circle())
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close without saving")
    }
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
    .background(CETheme.elevated.opacity(0.94))
    .contentShape(Rectangle())
  }

  private func scaleBar(for id: PadControlID) -> some View {
    HStack(spacing: 12) {
      Text(id.title.uppercased())
        .font(CETheme.sans(11, weight: .bold))
        .tracking(0.6)
        .foregroundStyle(CETheme.crystal)
      Spacer()
      Button {
        draft.setScale(id, draft[id].scale - 0.1)
      } label: {
        Image(systemName: "minus")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(CETheme.text)
          .frame(width: 32, height: 32)
          .background(CETheme.card, in: Circle())
      }
      Text(String(format: "%.0f%%", draft[id].scale * 100))
        .font(CETheme.mono(12))
        .foregroundStyle(CETheme.muted)
        .frame(width: 48)
      Button {
        draft.setScale(id, draft[id].scale + 0.1)
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(CETheme.text)
          .frame(width: 32, height: 32)
          .background(CETheme.card, in: Circle())
      }
      Button("Reset") {
        let defaults = landscape ? TouchPadLayout.defaultLandscape() : TouchPadLayout.defaultPortrait()
        draft[id] = defaults[id]
      }
      .font(CETheme.sans(12, weight: .semibold))
      .foregroundStyle(CETheme.accent)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(CETheme.card.opacity(0.95))
  }

  private func commitSave() {
    store.save(draft, landscape: landscape)
    baseline = draft
  }

  private func syncOrientation(_ isLand: Bool) {
    guard landscape != isLand else { return }
    landscape = isLand
    let saved = store.layout(landscape: isLand)
    draft = saved
    baseline = saved
  }

  private func handleOrientationChange(_ isLand: Bool) {
    if isDirty {
      showExitPrompt = false
      store.save(draft, landscape: landscape)
      baseline = draft
    }
    landscape = isLand
    let saved = store.layout(landscape: isLand)
    draft = saved
    baseline = saved
  }
}
