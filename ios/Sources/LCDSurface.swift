import QuartzCore
import SwiftUI
import UIKit

/// Pushes CGImages onto a CALayer without going through SwiftUI `@Published`.
/// Updating `EmulatorEngine.frameImage` was rebuilding the whole PlayView at 60 Hz.
final class LCDPresenter {
  fileprivate weak var host: LCDHostView?

  func setImage(_ image: CGImage?) {
    if Thread.isMainThread {
      host?.setContents(image)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.host?.setContents(image)
      }
    }
  }

  func clear() { setImage(nil) }
}

final class LCDHostView: UIView {
  override class var layerClass: AnyClass { CALayer.self }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = .black
    layer.contentsGravity = .resizeAspect
    layer.magnificationFilter = .nearest
    layer.minificationFilter = .nearest
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  fileprivate func setContents(_ image: CGImage?) {
    layer.contents = image
  }

  func setFill(_ fill: Bool) {
    layer.contentsGravity = fill ? .resize : .resizeAspect
  }
}

struct LCDViewRepresentable: UIViewRepresentable {
  let presenter: LCDPresenter
  var fill: Bool = false

  func makeUIView(context: Context) -> LCDHostView {
    let v = LCDHostView()
    v.setFill(fill)
    presenter.host = v
    return v
  }

  func updateUIView(_ uiView: LCDHostView, context: Context) {
    uiView.setFill(fill)
    if presenter.host !== uiView {
      presenter.host = uiView
    }
  }

  static func dismantleUIView(_ uiView: LCDHostView, coordinator: ()) {
    uiView.setContents(nil)
  }
}
