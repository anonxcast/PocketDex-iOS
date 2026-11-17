import SwiftUI

/// Apple Music–style press: soft spring scale.
/// Prefer this on `Button`s inside `ScrollView` — it does not steal pan gestures.
struct MediaPressStyle: ButtonStyle {
  var scale: CGFloat = 0.96

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? scale : 1)
      .animation(.spring(response: 0.28, dampingFraction: 0.72), value: configuration.isPressed)
  }
}

/// Capsule action used on Music/TV-style hubs (Play / Edit Save / Artwork).
struct MediaActionPill: View {
  let title: String
  let systemImage: String
  var prominent: Bool = false
  var compact: Bool = false
  let action: () -> Void

  var body: some View {
    Button {
      InputHaptics.selectionChange()
      action()
    } label: {
      Label(title, systemImage: systemImage)
        .font(CETheme.sans(compact ? 13 : 15, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 10 : 12)
        .padding(.horizontal, compact ? 8 : 10)
        .foregroundStyle(prominent ? Color.white : CETheme.text)
        .background(
          prominent ? CETheme.accent : CETheme.card,
          in: Capsule()
        )
        .overlay(
          Capsule()
            .stroke(prominent ? Color.clear : CETheme.border, lineWidth: 1)
        )
    }
    .buttonStyle(MediaPressStyle())
  }
}

/// Library poster / banner — Button so ScrollView keeps the pan; mid-point for quick-play bubble.
struct LibraryGameTapButton<Label: View>: View {
  let action: (CGPoint) -> Void
  @ViewBuilder var label: () -> Label

  @State private var globalMid: CGPoint = .zero

  var body: some View {
    Button {
      action(globalMid)
    } label: {
      label()
        .contentShape(Rectangle())
        .background {
          GeometryReader { geo in
            Color.clear
              .onAppear { globalMid = mid(of: geo.frame(in: .global)) }
              .onChange(of: geo.frame(in: .global)) { _, frame in
                globalMid = mid(of: frame)
              }
          }
        }
    }
    .buttonStyle(MediaPressStyle())
  }

  private func mid(of frame: CGRect) -> CGPoint {
    CGPoint(x: frame.midX, y: frame.midY)
  }
}
