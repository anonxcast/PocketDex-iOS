import SwiftUI

/// PokeDaisy-style floating DS touch screen (ONE SCREEN / menu side-by-side).
struct DsTouchWindow: View {
  let open: Bool
  let dualScreens: Bool
  let loading: Bool
  let topImage: CGImage?
  let bottomImage: CGImage?
  let smoothing: SmoothingMode
  let onDismiss: () -> Void
  let onClose: (() -> Void)?
  let onStylusChanged: (CGPoint, CGSize) -> Void
  let onStylusEnded: () -> Void

  @State private var appear = false

  var body: some View {
    if open {
      ZStack {
        Color.black.opacity(0.55 * (appear ? 1 : 0))
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { onDismiss() }

        GeometryReader { geo in
          let pad: CGFloat = 16
          let maxW = geo.size.width - pad * 2
          let maxH = geo.size.height - pad * 2
          Group {
            if dualScreens {
              dualContent(maxW: maxW, maxH: maxH)
            } else {
              singleTouch(maxW: maxW, maxH: maxH)
            }
          }
          .position(x: geo.size.width / 2, y: geo.size.height / 2)
          .scaleEffect(appear ? 1 : 0.92)
          .opacity(appear ? 1 : 0)
        }
        .allowsHitTesting(true)
      }
      .onAppear {
        withAnimation(.easeOut(duration: 0.13)) { appear = true }
      }
      .onDisappear { appear = false }
    }
  }

  @ViewBuilder
  private func singleTouch(maxW: CGFloat, maxH: CGFloat) -> some View {
    let aspect: CGFloat = 256.0 / 192.0
    let w = min(maxW * 0.92, maxH * 0.88 * aspect)
    let h = w / aspect
    framed(width: w, height: h) {
      lcd(bottomImage, size: CGSize(width: w, height: h), touch: true)
      if loading { loadingOverlay(size: CGSize(width: w, height: h)) }
      if let onClose {
        closeButton(action: onClose)
          .offset(x: w / 2 + 18, y: -h / 2 - 4)
      }
    }
  }

  @ViewBuilder
  private func dualContent(maxW: CGFloat, maxH: CGFloat) -> some View {
    let aspect: CGFloat = 256.0 / 192.0
    let pairAspect = aspect * 2
    let wPair = min(maxW * 0.96, maxH * 0.88 * pairAspect)
    let h = wPair / pairAspect
    let eachW = wPair / 2
    framed(width: wPair, height: h) {
      HStack(spacing: 0) {
        lcd(topImage, size: CGSize(width: eachW, height: h), touch: false)
        lcd(bottomImage, size: CGSize(width: eachW, height: h), touch: true)
      }
      if loading { loadingOverlay(size: CGSize(width: wPair, height: h)) }
      if let onClose {
        closeButton(action: onClose)
          .offset(x: wPair / 2 + 18, y: -h / 2 - 4)
      }
    }
  }

  private func framed<Content: View>(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) -> some View {
    let frame: CGFloat = 10
    return ZStack {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color(red: 0.12, green: 0.14, blue: 0.18))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .frame(width: width + frame * 2, height: height + frame * 2)
      content()
    }
  }

  @ViewBuilder
  private func lcd(_ image: CGImage?, size: CGSize, touch: Bool) -> some View {
    let base = ZStack {
      Color.black
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .interpolation(smoothing == .soft ? .medium : .none)
          .frame(width: size.width, height: size.height)
      }
    }
    .frame(width: size.width, height: size.height)
    .clipped()
    .contentShape(Rectangle())

    if touch {
      base.gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
          .onChanged { value in onStylusChanged(value.location, size) }
          .onEnded { _ in onStylusEnded() }
      )
    } else {
      base.allowsHitTesting(false)
    }
  }

  private func loadingOverlay(size: CGSize) -> some View {
    ZStack {
      Color.black.opacity(0.35)
      DsTouchLoaderDots()
    }
    .frame(width: size.width, height: size.height)
    .allowsHitTesting(false)
  }

  private func closeButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(CETheme.text)
        .frame(width: 28, height: 28)
        .background(CETheme.card.opacity(0.9), in: Circle())
        .overlay(Circle().stroke(CETheme.border.opacity(0.6), lineWidth: 1))
    }
    .accessibilityLabel("Close touch screen")
  }
}

private struct DsTouchLoaderDots: View {
  var body: some View {
    TimelineView(.animation(minimumInterval: 0.22, paused: false)) { timeline in
      let t = Int(timeline.date.timeIntervalSinceReferenceDate / 0.22) % 3
      HStack(spacing: 10) {
        ForEach(0..<3, id: \.self) { i in
          Circle()
            .fill(Color.white.opacity(i == t ? 1 : 0.35))
            .frame(width: 7, height: 7)
            .offset(y: i == t ? -4 : 0)
        }
      }
    }
  }
}
