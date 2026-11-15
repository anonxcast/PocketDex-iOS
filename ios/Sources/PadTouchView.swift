import SwiftUI
import UIKit

/// UIKit multi-touch layer for the translucent virtual pad.
/// Instant touchesBegan (no SwiftUI DragGesture delay) and expanded hit boxes so light taps register.
final class PadTouchUIView: UIView {
  var layout: TouchPadLayout = .defaultPortrait()
  var onKey: ((UInt32, Bool) -> Void)?
  var onDpadMask: ((UInt32) -> Void)?
  var visibleControls: [PadControlID] = PadControlID.gbaCases

  private var buttonTouches: [ObjectIdentifier: UInt32] = [:]
  private var dpadTouch: ObjectIdentifier?
  private var heldButtons: UInt32 = 0

  /// Extra hit padding beyond the drawn control (points).
  private let hitSlop: CGFloat = 22
  private let dpadDead: CGFloat = 8

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    backgroundColor = .clear
    isOpaque = false
  }

  required init?(coder: NSCoder) { fatalError() }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { begin(t) }
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { move(t) }
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { end(t) }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { end(t) }
  }

  private func begin(_ touch: UITouch) {
    let p = touch.location(in: self)
    let id = ObjectIdentifier(touch)
    if hitDpad(p) {
      dpadTouch = id
      onDpadMask?(dpadMask(at: p))
      return
    }
    if let bit = hitButton(p) {
      buttonTouches[id] = bit
      setButton(bit, down: true)
    }
  }

  private func move(_ touch: UITouch) {
    let p = touch.location(in: self)
    let id = ObjectIdentifier(touch)
    if dpadTouch == id {
      if hitDpad(p) {
        onDpadMask?(dpadMask(at: p))
      } else {
        // Slide off d-pad → release
        dpadTouch = nil
        onDpadMask?(0)
      }
      return
    }
    if let bit = buttonTouches[id] {
      // Finger left the expanded hit box → release that button.
      if !buttonFrame(forBit: bit).insetBy(dx: -hitSlop, dy: -hitSlop).contains(p) {
        buttonTouches.removeValue(forKey: id)
        setButton(bit, down: false)
      }
    }
  }

  private func end(_ touch: UITouch) {
    let id = ObjectIdentifier(touch)
    if dpadTouch == id {
      dpadTouch = nil
      onDpadMask?(0)
    }
    if let bit = buttonTouches.removeValue(forKey: id) {
      setButton(bit, down: false)
    }
  }

  private func setButton(_ bit: UInt32, down: Bool) {
    if down {
      if heldButtons & bit == 0 {
        heldButtons |= bit
        onKey?(bit, true)
      }
    } else {
      // Only release if no other finger still holds this bit.
      let stillHeld = buttonTouches.values.contains(bit)
      if !stillHeld, heldButtons & bit != 0 {
        heldButtons &= ~bit
        onKey?(bit, false)
      }
    }
  }

  private func controlFrame(_ id: PadControlID) -> CGRect {
    let place = layout[id]
    let base = id.baseSize
    let w = base.width * place.scale
    let h = base.height * place.scale
    let cx = place.x * bounds.width
    let cy = place.y * bounds.height
    return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
  }

  private func hitDpad(_ p: CGPoint) -> Bool {
    controlFrame(.dpad).insetBy(dx: -hitSlop, dy: -hitSlop).contains(p)
  }

  private func hitButton(_ p: CGPoint) -> UInt32? {
    // Prefer nearer center when overlaps (A/B/X/Y cluster).
    let all: [(PadControlID, UInt32)] = [
      (.a, GbaKey.a), (.b, GbaKey.b), (.x, GbaKey.x), (.y, GbaKey.y),
      (.start, GbaKey.start), (.select, GbaKey.select),
      (.l, GbaKey.l), (.r, GbaKey.r),
    ]
    let buttons = all.filter { visibleControls.contains($0.0) }
    var best: (UInt32, CGFloat)?
    for (id, bit) in buttons {
      let frame = controlFrame(id).insetBy(dx: -hitSlop, dy: -hitSlop)
      guard frame.contains(p) else { continue }
      let dx = p.x - frame.midX
      let dy = p.y - frame.midY
      let d2 = dx * dx + dy * dy
      if best == nil || d2 < best!.1 {
        best = (bit, d2)
      }
    }
    return best?.0
  }

  private func buttonFrame(forBit bit: UInt32) -> CGRect {
    let id: PadControlID
    switch bit {
    case GbaKey.a: id = .a
    case GbaKey.b: id = .b
    case GbaKey.x: id = .x
    case GbaKey.y: id = .y
    case GbaKey.start: id = .start
    case GbaKey.select: id = .select
    case GbaKey.l: id = .l
    case GbaKey.r: id = .r
    default: return .null
    }
    return controlFrame(id)
  }

  private func dpadMask(at point: CGPoint) -> UInt32 {
    let frame = controlFrame(.dpad)
    let midX = frame.midX
    let midY = frame.midY
    let dx = point.x - midX
    let dy = point.y - midY
    if abs(dx) < dpadDead && abs(dy) < dpadDead { return 0 }
    var mask: UInt32 = 0
    let axisBias: CGFloat = 0.5
    if abs(dy) >= dpadDead && (abs(dy) >= abs(dx) * axisBias || abs(dx) < dpadDead) {
      mask |= dy < 0 ? GbaKey.up : GbaKey.down
    }
    if abs(dx) >= dpadDead && (abs(dx) >= abs(dy) * axisBias || abs(dy) < dpadDead) {
      mask |= dx < 0 ? GbaKey.left : GbaKey.right
    }
    if mask == 0 {
      mask = abs(dy) >= abs(dx) ? (dy < 0 ? GbaKey.up : GbaKey.down) : (dx < 0 ? GbaKey.left : GbaKey.right)
    }
    return mask
  }
}

struct PadTouchRepresentable: UIViewRepresentable {
  let layout: TouchPadLayout
  let onKey: (UInt32, Bool) -> Void
  let onDpadMask: (UInt32) -> Void
  var visibleControls: [PadControlID] = PadControlID.gbaCases

  func makeUIView(context: Context) -> PadTouchUIView {
    let v = PadTouchUIView()
    v.layout = layout
    v.onKey = onKey
    v.onDpadMask = onDpadMask
    v.visibleControls = visibleControls
    return v
  }

  func updateUIView(_ uiView: PadTouchUIView, context: Context) {
    uiView.layout = layout
    uiView.onKey = onKey
    uiView.onDpadMask = onDpadMask
    uiView.visibleControls = visibleControls
  }
}
