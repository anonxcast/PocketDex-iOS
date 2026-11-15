import SwiftUI

/// Liquid Glass helpers (iOS 26+) with Material fallbacks.
enum GlassChrome {
  /// Soft Music-like canvas (not pure black).
  static let canvas = Color(red: 0.07, green: 0.07, blue: 0.08)
}

extension View {
  /// Capsule Liquid Glass (Music-style floating chrome).
  @ViewBuilder
  func pocketGlassCapsule(interactive: Bool = false) -> some View {
    if #available(iOS 26.0, *) {
      let glass: Glass = interactive ? .regular.interactive() : .regular
      self.glassEffect(glass, in: Capsule(style: .continuous))
    } else {
      self
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
  }

  /// Rounded-rect Liquid Glass.
  @ViewBuilder
  func pocketGlassCard(cornerRadius: CGFloat = 18, interactive: Bool = false) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if #available(iOS 26.0, *) {
      let glass: Glass = interactive ? .regular.interactive() : .regular
      self.glassEffect(glass, in: shape)
    } else {
      self
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
  }

}
