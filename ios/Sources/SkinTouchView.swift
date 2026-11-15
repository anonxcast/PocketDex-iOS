import SwiftUI
import UIKit

/// UIKit touch layer that hit-tests Delta skin control items (multi-touch).
final class SkinTouchUIView: UIView {
  var representation: DeltaSkinRepresentation?
  var transformMap: SkinViewTransform?
  var onMaskChange: ((UInt32) -> Void)?
  var onMenu: (() -> Void)?

  private var active: [UITouch: UInt32] = [:]

  override init(frame: CGRect) {
    super.init(frame: frame)
    isMultipleTouchEnabled = true
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) { fatalError() }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { update(touch: t, phase: .began) }
    emit()
  }
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { update(touch: t, phase: .moved) }
    emit()
  }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { active.removeValue(forKey: t) }
    emit()
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    for t in touches { active.removeValue(forKey: t) }
    emit()
  }

  private func update(touch: UITouch, phase: UITouch.Phase) {
    guard let rep = representation, let map = transformMap else { return }
    let p = touch.location(in: self)
    let mp = map.mappingPoint(from: p)

    var mask: UInt32 = 0
    var hitMenu = false
    // Extra slop beyond skin extendedEdges — light / near-miss taps still register.
    let slop: CGFloat = 18
    for item in rep.items {
      guard item.hitFrame.cgRect.insetBy(dx: -slop, dy: -slop).contains(mp) else { continue }
      switch item.input {
      case .button(let name):
        if let bit = SkinInputMapper.gbaMask(for: name) { mask |= bit }
      case .dpad:
        mask |= SkinInputMapper.dpadMask(at: mp, frame: item.frame, map: item.dpadMap)
      case .menu:
        hitMenu = true
      case .touchScreen, .ignored:
        // Stylus is handled by PlayView's bottom-screen overlay (Delta / Manic).
        break
      }
    }
    if hitMenu, phase == .began { onMenu?() }
    if mask != 0 {
      active[touch] = mask
    } else if phase != .began {
      active.removeValue(forKey: touch)
    } else {
      active.removeValue(forKey: touch)
    }
  }

  private func emit() {
    var combined: UInt32 = 0
    for (_, m) in active { combined |= m }
    onMaskChange?(combined)
  }
}

struct SkinTouchRepresentable: UIViewRepresentable {
  let representation: DeltaSkinRepresentation?
  let transformMap: SkinViewTransform?
  let onMaskChange: (UInt32) -> Void
  let onMenu: () -> Void

  func makeUIView(context: Context) -> SkinTouchUIView {
    let v = SkinTouchUIView()
    v.onMaskChange = onMaskChange
    v.onMenu = onMenu
    return v
  }

  func updateUIView(_ uiView: SkinTouchUIView, context: Context) {
    uiView.representation = representation
    uiView.transformMap = transformMap
    uiView.onMaskChange = onMaskChange
    uiView.onMenu = onMenu
  }
}
