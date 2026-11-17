import QuartzCore
import SwiftUI
import UIKit

/// Pushes CGImages onto a CALayer without going through SwiftUI `@Published`.
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

  func setExpandPlacement(_ place: WideCameraMath.Placement?) {
    if Thread.isMainThread {
      host?.setExpandPlacement(place)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.host?.setExpandPlacement(place)
      }
    }
  }

  func clear() { setImage(nil) }
}

final class LCDHostView: UIView {
  private let fbLayer = CALayer()
  private var fill = false
  private var expandPlacement: WideCameraMath.Placement?
  private var imagePixelSize: CGSize = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = true
    backgroundColor = .black
    clipsToBounds = true
    fbLayer.magnificationFilter = .nearest
    fbLayer.minificationFilter = .nearest
    fbLayer.contentsGravity = .resize
    layer.addSublayer(fbLayer)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutFramebuffer()
  }

  fileprivate func setContents(_ image: CGImage?) {
    fbLayer.contents = image
    let newSize: CGSize
    if let image {
      newSize = CGSize(width: image.width, height: image.height)
    } else {
      newSize = .zero
    }
    // Stable Expand windows keep the same pixel size — skip layout every frame.
    if newSize != imagePixelSize {
      imagePixelSize = newSize
      layoutFramebuffer()
    }
  }

  fileprivate func setExpandPlacement(_ place: WideCameraMath.Placement?) {
    guard expandPlacement != place else { return }
    expandPlacement = place
    layoutFramebuffer()
  }

  func setFill(_ fill: Bool) {
    self.fill = fill
    layoutFramebuffer()
  }

  private func layoutFramebuffer() {
    let bounds = self.bounds
    guard bounds.width > 1, bounds.height > 1, imagePixelSize.width > 0, imagePixelSize.height > 0 else {
      fbLayer.frame = bounds
      return
    }

    if let place = expandPlacement {
      // Match PlayView gameSurface Expand: 1 game pixel = place.scale screen px.
      let ns = max(window?.screen.scale ?? UIScreen.main.scale, 1)
      let w = imagePixelSize.width * place.scale / ns
      let h = imagePixelSize.height * place.scale / ns
      let x = (place.offX / ns).rounded(.toNearestOrAwayFromZero)
      let y = (place.offY / ns).rounded(.toNearestOrAwayFromZero)
      fbLayer.frame = CGRect(x: x, y: y, width: w, height: h)
      return
    }

    let imgAspect = imagePixelSize.width / imagePixelSize.height
    let viewAspect = bounds.width / bounds.height
    if fill {
      fbLayer.frame = bounds
    } else if viewAspect > imgAspect {
      let h = bounds.height
      let w = h * imgAspect
      fbLayer.frame = CGRect(x: (bounds.width - w) / 2, y: 0, width: w, height: h)
    } else {
      let w = bounds.width
      let h = w / imgAspect
      fbLayer.frame = CGRect(x: 0, y: (bounds.height - h) / 2, width: w, height: h)
    }
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
