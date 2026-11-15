import SwiftUI

/// Observes iPhone Duo hinge status. `onChange(true)` when the device is closed
/// (app moves to the outer / front display); `false` when open / unavailable.
struct DuoHingeClosedObserver: ViewModifier {
  var onChange: (Bool) -> Void

  func body(content: Content) -> some View {
    if #available(iOS 27.1, *) {
      content.onHingeChange { _, newContext in
        // Only `.closed` is the front display. Fully / partially open → inner layout.
        let closed = newContext.hinge?.status == .closed
        onChange(closed)
      }
    } else {
      content
    }
  }
}
