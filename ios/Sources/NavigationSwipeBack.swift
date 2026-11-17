import SwiftUI
import UIKit

/// Re-enables the system edge-swipe-to-pop when the navigation bar is hidden.
/// (UIKit disables `interactivePopGestureRecognizer` while the bar is gone.)
struct NavigationSwipeBackEnabler: UIViewControllerRepresentable {
  func makeUIViewController(context: Context) -> Controller {
    Controller()
  }

  func updateUIViewController(_ uiViewController: Controller, context: Context) {}

  final class Controller: UIViewController, UIGestureRecognizerDelegate {
    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      guard let nav = navigationController else { return }
      nav.interactivePopGestureRecognizer?.isEnabled = true
      nav.interactivePopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      (navigationController?.viewControllers.count ?? 0) > 1
    }

    /// Allow simultaneous recognition with scroll views so vertical scrolling still works.
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      false
    }
  }
}

extension View {
  /// Edge swipe from the left to pop, even with a custom / hidden nav bar.
  func navigationSwipeBackEnabled() -> some View {
    background(NavigationSwipeBackEnabler())
  }
}
