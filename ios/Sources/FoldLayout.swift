import SwiftUI
import UIKit

/// Split panes for Duo book / tabletop play (game above the fold, controls below).
struct FoldPanes: Equatable {
  var top: CGRect
  var bottom: CGRect
  var hinge: CGRect
  var isFoldActive: Bool
}

enum FoldLayout {
  /// Manual 48/52 split when Folder mode is on but the hinge division isn’t active yet.
  static func manualSplit(in size: CGSize) -> FoldPanes {
    let hingeH = max(10, min(28, size.height * 0.028))
    let topH = size.height * 0.46
    let top = CGRect(x: 0, y: 0, width: size.width, height: topH)
    let hinge = CGRect(x: 0, y: topH, width: size.width, height: hingeH)
    let bottom = CGRect(
      x: 0,
      y: hinge.maxY,
      width: size.width,
      height: max(80, size.height - hinge.maxY)
    )
    return FoldPanes(top: top, bottom: bottom, hinge: hinge, isFoldActive: false)
  }

  static func panes(fromDivision fold: CGRect, in size: CGSize) -> FoldPanes? {
    // Horizontal crease (tabletop / portrait book): game above, controls below.
    if fold.height <= fold.width * 1.35, fold.height < size.height * 0.35 {
      let topH = max(60, fold.minY)
      let botH = max(80, size.height - fold.maxY)
      // Reject junk divisions that leave a postage-stamp game pane.
      guard topH >= size.height * 0.28, botH >= size.height * 0.22 else { return nil }
      let top = CGRect(x: 0, y: 0, width: size.width, height: topH)
      let bottom = CGRect(x: 0, y: fold.maxY, width: size.width, height: botH)
      return FoldPanes(top: top, bottom: bottom, hinge: fold, isFoldActive: fold.height > 1)
    }
    // Vertical crease (Duo landscape book): game on the left page, controls on the right.
    if fold.width <= fold.height * 1.35, fold.width < size.width * 0.35 {
      let leftW = max(80, fold.minX)
      let rightW = max(80, size.width - fold.maxX)
      // Flat Duo sometimes reports a thin active strip — ignore unless both pages are real.
      guard leftW >= size.width * 0.32, rightW >= size.width * 0.28 else { return nil }
      let left = CGRect(x: 0, y: 0, width: leftW, height: size.height)
      let right = CGRect(x: fold.maxX, y: 0, width: rightW, height: size.height)
      return FoldPanes(top: left, bottom: right, hinge: fold, isFoldActive: fold.width > 1)
    }
    return nil
  }
}

/// Reports the Duo fold division rect (view coords) into SwiftUI.
struct FoldDivisionReader: UIViewRepresentable {
  var onChange: (CGRect?) -> Void

  func makeUIView(context: Context) -> FoldDivisionUIView {
    let v = FoldDivisionUIView()
    v.onChange = onChange
    return v
  }

  func updateUIView(_ uiView: FoldDivisionUIView, context: Context) {
    uiView.onChange = onChange
    uiView.reportDivision()
  }
}

final class FoldDivisionUIView: UIView {
  var onChange: ((CGRect?) -> Void)?
  private var last: CGRect?

  override func layoutSubviews() {
    super.layoutSubviews()
    reportDivision()
  }

  func reportDivision() {
    let next = activeDivisionFrame()
    if next != last {
      last = next
      onChange?(next)
    }
  }

  private func activeDivisionFrame() -> CGRect? {
    guard #available(iOS 27.1, *) else { return nil }
    let regions = reservedRegions(kind: .division)
    // Active fold only — flat Duo reports inactive/zero-width divisions.
    guard let region = regions.first(where: { $0.isActive && $0.frame.height > 1 && $0.frame.width > 1 })
    else { return nil }
    return region.frame
  }
}
