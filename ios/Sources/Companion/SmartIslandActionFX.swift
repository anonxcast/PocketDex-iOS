import SwiftUI

/// One-shot Smart Island FX (never sticky coaching).
enum SmartIslandFXKind: Equatable {
  case pokeBallThrow
  case catchFail
  case catchSuccess
  case healPulse
  case nurseJoyHeal
  case cureSpark
  case celebrateBurst
  case moneyRain
  case battleFlash
  case switchSwap
  case criticalPulse
  case areaWhoosh
}

/// Pulse published by Smart Island memory — survives urgent tip overrides.
struct SmartIslandFXPulse: Equatable {
  var kind: SmartIslandFXKind
  var nonce: UInt64
}

extension Gen3BattleCoach.Advice {
  /// FX only for real transitions — not held tips like CATCH coaching or WELCOME.
  var islandFX: SmartIslandFXKind? {
    guard let id = tipId else { return nil }
    switch id {
    case "evt.ball":
      return nil
    case "evt.heal", "bat.revive":
      return .healPulse
    case "evt.heal.nurse":
      return .nurseJoyHeal
    case "evt.cure":
      return .cureSpark
    case "bat.status":
      return nil
    case "evt.money":
      return .moneyRain
    case "evt.battle.wild", "evt.battle.trainer":
      return .battleFlash
    case "evt.lead", "bat.faint":
      return .switchSwap
    case "evt.area":
      return .areaWhoosh
    case "bat.win":
      return .celebrateBurst
    case "bat.lose":
      return .criticalPulse
    default:
      if id.hasPrefix("evt.done.") { return .celebrateBurst }
      return nil
    }
  }

  /// Key for one-shot FX. Repeatable spends include line text so a second throw still animates.
  var islandFXTrigger: String {
    guard let id = tipId, !id.isEmpty else { return "" }
    switch id {
    case "evt.ball", "evt.heal", "evt.heal.nurse", "evt.cure", "evt.money", "evt.lead":
      return [id, headline, detail].joined(separator: "¦")
    default:
      return id
    }
  }
}

// MARK: - Overlay

struct SmartIslandFXOverlay: View {
  let kind: SmartIslandFXKind?
  let token: Int
  var onFinished: (() -> Void)? = nil

  var body: some View {
    GeometryReader { geo in
      ZStack {
        if let kind {
          LivelyIslandFXStage(
            kind: kind,
            size: geo.size,
            token: token,
            onFinished: onFinished
          )
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .clipped()
    }
    .allowsHitTesting(false)
  }
}

// MARK: - Lively FX (smooth sprites + animated island outline)

private struct LivelyIslandFXStage: View {
  let kind: SmartIslandFXKind
  let size: CGSize
  let token: Int
  var onFinished: (() -> Void)?

  @State private var progress: CGFloat = 0
  @State private var spin: Double = 0
  @State private var shake: CGFloat = 0
  @State private var burst: CGFloat = 0
  @State private var broken: Bool = false
  @State private var opacity: Double = 1
  @State private var rim: CGFloat = 0
  @State private var rimDash: CGFloat = 0

  private var ballSize: CGFloat { min(28, max(18, size.height * 0.5)) }
  private var corner: CGFloat {
    if size.height < 40 { return 12 }
    if size.height < 62 { return 14 }
    return 18
  }

  private var rimColor: Color {
    switch kind {
    case .pokeBallThrow: return Color(red: 1.0, green: 0.42, blue: 0.38)
    case .catchSuccess: return Color(red: 0.45, green: 1.0, blue: 0.55)
    case .celebrateBurst: return Color(red: 1.0, green: 0.86, blue: 0.28)
    case .catchFail, .criticalPulse: return Color(red: 1.0, green: 0.32, blue: 0.34)
    case .healPulse: return Color(red: 0.35, green: 1.0, blue: 0.65)
    case .nurseJoyHeal: return Color(red: 1.0, green: 0.55, blue: 0.72)
    case .cureSpark: return Color(red: 0.78, green: 0.55, blue: 1.0)
    case .moneyRain: return Color(red: 1.0, green: 0.86, blue: 0.30)
    case .battleFlash: return Color(red: 1.0, green: 0.72, blue: 0.28)
    case .switchSwap: return Color(red: 0.45, green: 0.86, blue: 1.0)
    case .areaWhoosh: return Color.white
    }
  }

  var body: some View {
    ZStack {
      islandOutline
      content
    }
    .frame(width: size.width, height: size.height)
    .opacity(opacity)
    .id(token)
    .task(id: token) { await run() }
  }

  /// Traces the Smart Island chrome — pulses / chases with the event.
  private var islandOutline: some View {
    let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
    return ZStack {
      shape
        .stroke(rimColor.opacity(0.18 + 0.55 * Double(rim)), lineWidth: 1.2 + rim * 1.6)
        .blur(radius: rim * 1.2)
      shape
        .stroke(
          AngularGradient(
            colors: [
              rimColor.opacity(0.05),
              rimColor.opacity(0.95),
              Color.white.opacity(0.85),
              rimColor.opacity(0.95),
              rimColor.opacity(0.05),
            ],
            center: .center,
            angle: .degrees(rimDash * 360)
          ),
          lineWidth: 2.0 + rim * 1.2
        )
        .opacity(0.35 + 0.65 * Double(rim))
    }
    .padding(0.5)
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private var content: some View {
    switch kind {
    case .pokeBallThrow: throwBall
    case .catchFail: failBall
    case .catchSuccess: successBall
    case .healPulse: healFX
    case .nurseJoyHeal: nurseJoyFX
    case .cureSpark: cureFX
    case .celebrateBurst: celebrateFX
    case .moneyRain: moneyFX
    case .battleFlash: battleFX
    case .switchSwap: switchFX
    case .criticalPulse: criticalFX
    case .areaWhoosh: whooshFX
    }
  }

  // MARK: Ball

  private var throwBall: some View {
    let t = progress
    let p0 = CGPoint(x: size.width * 0.26, y: size.height * 0.98)
    let p1 = CGPoint(x: size.width * 0.46, y: -size.height * 0.18)
    let p2 = CGPoint(x: size.width * 0.60, y: size.height * 0.30)
    let pos = Self.quad(t, p0, p1, p2)
    let scale = 1.25 - t * 0.88
    let fade = t < 0.84 ? 1.0 : Double((1.0 - t) / 0.16)
    return ZStack {
      // Soft motion trail
      ForEach(0..<4, id: \.self) { i in
        let u = max(0, t - CGFloat(i) * 0.06)
        let tp = Self.quad(u, p0, p1, p2)
        Circle()
          .fill(rimColor.opacity(0.22 - Double(i) * 0.04))
          .frame(width: ballSize * 0.35, height: ballSize * 0.35)
          .scaleEffect(max(0.2, scale * (1 - CGFloat(i) * 0.12)))
          .position(tp)
          .opacity(fade * (t > 0.05 ? 1 : 0))
      }
      SmoothPokeball(size: ballSize)
        .scaleEffect(max(0.2, scale))
        .rotationEffect(.degrees(spin))
        .opacity(fade)
        .position(pos)
        .shadow(color: .black.opacity(0.35 * (1.05 - t)), radius: 3, y: 2)
    }
  }

  private var failBall: some View {
    let cx = size.width * 0.5 + shake
    let cy = size.height * 0.52
    return ZStack {
      SmoothPokeball(size: ballSize, open: broken)
        .rotationEffect(.degrees(broken ? -8 : shake * 12))
        .position(x: cx, y: cy)
      if broken {
        Image(systemName: "xmark")
          .font(.system(size: ballSize * 0.48, weight: .black, design: .rounded))
          .foregroundStyle(Color(red: 1.0, green: 0.30, blue: 0.34))
          .shadow(color: Color.red.opacity(0.45), radius: 4)
          .scaleEffect(0.75 + 0.35 * burst)
          .opacity(0.9)
          .position(x: cx, y: cy)
      }
    }
  }

  private var successBall: some View {
    let cx = size.width * 0.5 + shake
    let cy = size.height * 0.52
    return ZStack {
      // Soft glow under the ball
      Circle()
        .fill(rimColor.opacity(0.35 * Double(burst)))
        .frame(width: ballSize * 2.2, height: ballSize * 1.4)
        .blur(radius: 8)
        .position(x: cx, y: cy)

      SmoothPokeball(size: ballSize)
        .rotationEffect(.degrees(shake * 10))
        .scaleEffect(1.0 + burst * 0.12)
        .position(x: cx, y: cy)

      ForEach(0..<12, id: \.self) { i in
        let ang = Double(i) / 12.0 * 2.0 * Double.pi + Double(burst) * 0.4
        let dist = burst * min(size.width, 86) * 0.38
        Image(systemName: i % 2 == 0 ? "star.fill" : "sparkle")
          .font(.system(size: i % 2 == 0 ? 8 : 5, weight: .bold, design: .rounded))
          .foregroundStyle(sparkColor(i))
          .shadow(color: sparkColor(i).opacity(0.5), radius: 2)
          .position(
            x: cx + CGFloat(cos(ang)) * dist,
            y: cy + CGFloat(sin(ang)) * dist * 0.55
          )
          .opacity(Double(max(0, 1.25 - burst)))
          .scaleEffect(0.6 + burst * 0.5)
      }
    }
  }

  // MARK: Other FX

  private var healFX: some View {
    ZStack {
      ForEach(0..<5, id: \.self) { i in
        let phase = min(1, progress + CGFloat(i) * 0.08)
        Image(systemName: "plus")
          .font(.system(size: 11 + CGFloat(i % 2) * 3, weight: .bold, design: .rounded))
          .foregroundStyle(Color(red: 0.4, green: 1.0, blue: 0.65).opacity(0.9 - Double(i) * 0.1))
          .position(
            x: size.width * (0.55 + CGFloat(i) * 0.07),
            y: size.height * (1.05 - phase * 1.15)
          )
          .scaleEffect(0.7 + phase * 0.4)
      }
    }
  }

  /// Nurse Joy — pink hearts + soft glow (matches Pokémon Center heal).
  private var nurseJoyFX: some View {
    let pink = Color(red: 1.0, green: 0.55, blue: 0.72)
    let pinkDeep = Color(red: 1.0, green: 0.35, blue: 0.58)
    return ZStack {
      Circle()
        .fill(pink.opacity(0.28 * Double(rim)))
        .frame(width: size.width * 0.55, height: size.height * 1.1)
        .blur(radius: 10)
        .position(x: size.width * 0.5, y: size.height * 0.5)

      ForEach(0..<6, id: \.self) { i in
        let phase = min(1, progress + CGFloat(i) * 0.07)
        Image(systemName: i % 2 == 0 ? "heart.fill" : "cross.case.fill")
          .font(.system(size: i % 2 == 0 ? 10 : 8, weight: .semibold, design: .rounded))
          .foregroundStyle(i % 2 == 0 ? pinkDeep : pink)
          .shadow(color: pink.opacity(0.45), radius: 2)
          .position(
            x: size.width * (0.22 + CGFloat(i) * 0.12),
            y: size.height * (1.05 - phase * 1.12)
          )
          .scaleEffect(0.65 + phase * 0.45)
          .opacity(Double(1.05 - phase))
      }
    }
  }

  private var cureFX: some View {
    ZStack {
      ForEach(0..<8, id: \.self) { i in
        let ang = Double(i) / 8.0 * 2.0 * .pi + Double(progress) * 2.5
        let dist = 6 + progress * min(size.width, 70) * 0.28
        Circle()
          .fill(i % 2 == 0 ? Color(red: 0.8, green: 0.55, blue: 1.0) : Color(red: 1.0, green: 0.9, blue: 0.5))
          .frame(width: 5, height: 5)
          .blur(radius: 0.4)
          .position(
            x: size.width * 0.72 + CGFloat(cos(ang)) * dist,
            y: size.height * 0.5 + CGFloat(sin(ang)) * dist * 0.55
          )
          .opacity(Double(1.1 - progress))
      }
    }
  }

  /// Pokémon victory fanfare — ball click, expanding rings, stars, rising sparkles.
  private var celebrateFX: some View {
    let cx = size.width * 0.5
    let cy = size.height * 0.52
    let ball = min(22, max(14, size.height * 0.38))
    return ZStack {
      // Soft sunburst wash (victory flash)
      Circle()
        .fill(
          RadialGradient(
            colors: [
              Color(red: 1.0, green: 0.92, blue: 0.35).opacity(0.55 * Double(burst)),
              Color(red: 0.35, green: 0.95, blue: 0.55).opacity(0.2 * Double(burst)),
              .clear,
            ],
            center: .center,
            startRadius: 2,
            endRadius: min(size.width, 120) * 0.55
          )
        )
        .frame(width: min(size.width, 140), height: size.height * 1.4)
        .position(x: cx, y: cy)

      // Expanding victory rings (like a catch confirmation bloom)
      ForEach(0..<3, id: \.self) { i in
        let t = max(0, burst - CGFloat(i) * 0.12)
        Circle()
          .stroke(
            Color(red: 1.0, green: 0.88, blue: 0.30).opacity(Double(max(0, 0.85 - t))),
            lineWidth: 2.0 - CGFloat(i) * 0.4
          )
          .frame(
            width: ball + t * min(size.width, 100) * 0.55,
            height: ball + t * min(size.width, 100) * 0.35
          )
          .position(x: cx, y: cy)
      }

      // Center Poké Ball bounce / spin
      SmoothPokeball(size: ball)
        .scaleEffect(0.55 + burst * 0.55)
        .rotationEffect(.degrees(spin * 0.35))
        .opacity(Double(min(1, 0.3 + burst * 1.1)))
        .position(x: cx, y: cy - shake)
        .shadow(color: Color(red: 1.0, green: 0.85, blue: 0.2).opacity(0.45 * Double(burst)), radius: 6)

      // Classic ★ burst
      ForEach(0..<10, id: \.self) { i in
        let ang = Double(i) / 10.0 * 2.0 * .pi - Double(progress) * 0.8
        let dist = burst * min(size.width, 90) * 0.40
        Image(systemName: "star.fill")
          .font(.system(size: i % 2 == 0 ? 9 : 6, weight: .bold, design: .rounded))
          .foregroundStyle(i % 3 == 0 ? Color(red: 1.0, green: 0.85, blue: 0.2) : .white)
          .shadow(color: .yellow.opacity(0.5), radius: 2)
          .position(
            x: cx + CGFloat(cos(ang)) * dist,
            y: cy + CGFloat(sin(ang)) * dist * 0.48
          )
          .opacity(Double(max(0, 1.15 - burst)))
          .scaleEffect(0.5 + burst * 0.7)
      }

      // Rising sparkles (EXP / level-up vibe)
      ForEach(0..<7, id: \.self) { i in
        let phase = min(1, progress + CGFloat(i) * 0.06)
        Image(systemName: "sparkle")
          .font(.system(size: 6 + CGFloat(i % 3), weight: .bold))
          .foregroundStyle(sparkColor(i))
          .position(
            x: cx + CGFloat(i - 3) * 11 + sin(phase * 6 + CGFloat(i)) * 3,
            y: size.height * (0.95 - phase * 0.95)
          )
          .opacity(Double(1.05 - phase))
      }
    }
  }

  private var moneyFX: some View {
    ZStack {
      ForEach(0..<5, id: \.self) { i in
        let phase = min(1, progress + CGFloat(i) * 0.07)
        Circle()
          .fill(
            RadialGradient(
              colors: [Color(red: 1.0, green: 0.95, blue: 0.55), Color(red: 1.0, green: 0.78, blue: 0.2)],
              center: .center,
              startRadius: 0,
              endRadius: 7
            )
          )
          .overlay(Circle().stroke(Color(red: 0.65, green: 0.4, blue: 0.05), lineWidth: 1))
          .frame(width: 12, height: 12)
          .rotationEffect(.degrees(spin * (0.4 + Double(i) * 0.1)))
          .position(
            x: 18 + CGFloat(i) * (size.width / 5.2),
            y: -10 + phase * (size.height + 18)
          )
          .shadow(color: .orange.opacity(0.35), radius: 2, y: 1)
      }
    }
  }

  private var battleFX: some View {
    let x = -20 + progress * (size.width + 40)
    return ZStack {
      Capsule()
        .fill(
          LinearGradient(
            colors: [.clear, .white.opacity(0.85), Color(red: 1.0, green: 0.82, blue: 0.3), .clear],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(width: 54, height: 7)
        .rotationEffect(.degrees(28))
        .position(x: x, y: size.height * 0.45)
        .blur(radius: 0.5)
      Capsule()
        .fill(Color.white.opacity(0.55))
        .frame(width: 36, height: 3)
        .rotationEffect(.degrees(28))
        .position(x: x + 8, y: size.height * 0.52)
    }
  }

  private var switchFX: some View {
    let travel = progress * size.width * 0.28
    return ZStack {
      Image(systemName: "chevron.right.2")
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.35))
        .position(x: size.width * 0.32 + travel, y: size.height * 0.5)
      Image(systemName: "chevron.left.2")
        .font(.system(size: 14, weight: .bold, design: .rounded))
        .foregroundStyle(Color(red: 0.45, green: 0.86, blue: 1.0))
        .position(x: size.width * 0.68 - travel, y: size.height * 0.5)
    }
  }

  private var criticalFX: some View {
    ZStack {
      Circle()
        .fill(Color.red.opacity(0.22 * Double(rim)))
        .frame(width: size.width * 0.4, height: size.height * 0.9)
        .blur(radius: 10)
        .position(x: size.width * 0.82, y: size.height * 0.5)
      Image(systemName: "exclamationmark")
        .font(.system(size: 18, weight: .black, design: .rounded))
        .foregroundStyle(Color(red: 1.0, green: 0.35, blue: 0.35))
        .scaleEffect(0.85 + burst * 0.35)
        .opacity(0.4 + 0.6 * Double(rim))
        .position(x: size.width * 0.82, y: size.height * 0.48)
    }
  }

  private var whooshFX: some View {
    ZStack {
      ForEach(0..<6, id: \.self) { i in
        Capsule()
          .fill(Color.white.opacity(0.35 - Double(i) * 0.04))
          .frame(width: 18 + CGFloat(i) * 4, height: 2.5)
          .position(
            x: -12 + progress * (size.width + 28) + CGFloat(i) * 10,
            y: size.height * (0.32 + CGFloat(i % 3) * 0.18)
          )
          .blur(radius: 0.6)
      }
    }
  }

  private func sparkColor(_ i: Int) -> Color {
    let colors: [Color] = [
      Color(red: 1.0, green: 0.85, blue: 0.25),
      Color(red: 0.45, green: 1.0, blue: 0.5),
      .white,
      Color(red: 0.45, green: 0.86, blue: 1.0),
      Color(red: 1.0, green: 0.55, blue: 0.7),
    ]
    return colors[i % colors.count]
  }

  // MARK: Timeline

  private func run() async {
    progress = 0
    spin = 0
    shake = 0
    burst = 0
    broken = false
    opacity = 1
    rim = 0
    rimDash = 0

    withAnimation(.easeInOut(duration: 0.35)) { rim = 1 }
    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { rimDash = 1 }

    switch kind {
    case .pokeBallThrow:
      withAnimation(.easeOut(duration: 1.25)) {
        progress = 1
        spin = 700
      }
      try? await Task.sleep(nanoseconds: 1_250_000_000)

    case .catchFail:
      for _ in 0..<3 {
        withAnimation(.easeInOut(duration: 0.06)) { shake = 5 }
        try? await Task.sleep(nanoseconds: 60_000_000)
        withAnimation(.easeInOut(duration: 0.06)) { shake = -5 }
        try? await Task.sleep(nanoseconds: 60_000_000)
      }
      withAnimation(.easeOut(duration: 0.05)) { shake = 0 }
      broken = true
      withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { burst = 1 }
      try? await Task.sleep(nanoseconds: 420_000_000)

    case .catchSuccess:
      for _ in 0..<3 {
        withAnimation(.easeInOut(duration: 0.055)) { shake = 4 }
        try? await Task.sleep(nanoseconds: 55_000_000)
        withAnimation(.easeInOut(duration: 0.055)) { shake = -4 }
        try? await Task.sleep(nanoseconds: 55_000_000)
      }
      withAnimation(.easeOut(duration: 0.04)) { shake = 0 }
      withAnimation(.spring(response: 0.34, dampingFraction: 0.68)) { burst = 1 }
      try? await Task.sleep(nanoseconds: 480_000_000)

    case .healPulse, .nurseJoyHeal, .moneyRain, .areaWhoosh, .battleFlash, .switchSwap:
      withAnimation(.easeOut(duration: 0.75)) {
        progress = 1
        spin = 220
      }
      try? await Task.sleep(nanoseconds: 780_000_000)

    case .cureSpark:
      withAnimation(.easeOut(duration: 0.7)) { progress = 1 }
      try? await Task.sleep(nanoseconds: 720_000_000)

    case .celebrateBurst:
      // Victory beat: rim flare → ball pop → star bloom → sparkle rise
      withAnimation(.easeOut(duration: 0.18)) { rim = 1; shake = -3 }
      try? await Task.sleep(nanoseconds: 120_000_000)
      withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
        burst = 1
        spin = 420
        shake = 0
        progress = 1
      }
      try? await Task.sleep(nanoseconds: 720_000_000)
      withAnimation(.easeInOut(duration: 0.2)) { rim = 0.55 }
      try? await Task.sleep(nanoseconds: 180_000_000)

    case .criticalPulse:
      withAnimation(.easeInOut(duration: 0.12)) { rim = 1; burst = 1 }
      try? await Task.sleep(nanoseconds: 140_000_000)
      withAnimation(.easeInOut(duration: 0.12)) { rim = 0.35; burst = 0.4 }
      try? await Task.sleep(nanoseconds: 140_000_000)
      withAnimation(.easeInOut(duration: 0.12)) { rim = 1; burst = 1 }
      try? await Task.sleep(nanoseconds: 280_000_000)
    }

    withAnimation(.easeOut(duration: 0.2)) {
      opacity = 0
      rim = 0
    }
    try? await Task.sleep(nanoseconds: 200_000_000)

    guard !Task.isCancelled else { return }
    onFinished?()
  }

  private static func quad(_ t: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGPoint {
    let u = 1 - t
    return CGPoint(
      x: u * u * a.x + 2 * u * t * b.x + t * t * c.x,
      y: u * u * a.y + 2 * u * t * b.y + t * t * c.y
    )
  }
}

/// Classic round Poké Ball — red top, white bottom, belt, button.
private struct SmoothPokeball: View {
  var size: CGFloat
  var open: Bool = false

  private var red: Color { Color(red: 0.92, green: 0.16, blue: 0.18) }
  private var redDeep: Color { Color(red: 0.72, green: 0.08, blue: 0.10) }
  private var ink: Color { Color(red: 0.12, green: 0.12, blue: 0.14) }

  var body: some View {
    let gap = open ? size * 0.14 : 0
    ZStack {
      Circle()
        .fill(
          LinearGradient(
            colors: [Color.white, Color(white: 0.88)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .frame(width: size, height: size)
        .mask(
          VStack(spacing: 0) {
            Color.clear.frame(height: size * 0.5)
            Rectangle().frame(height: size * 0.5)
          }
        )
        .offset(y: gap * 0.5)

      Circle()
        .fill(
          LinearGradient(
            colors: [red, redDeep],
            startPoint: .topLeading,
            endPoint: .bottom
          )
        )
        .frame(width: size, height: size)
        .mask(
          VStack(spacing: 0) {
            Rectangle().frame(height: size * 0.5)
            Color.clear.frame(height: size * 0.5)
          }
        )
        .offset(y: -gap * 0.5)

      if !open {
        Rectangle()
          .fill(ink)
          .frame(width: size, height: max(2.5, size * 0.11))
      }

      Circle()
        .stroke(ink, lineWidth: max(1.4, size * 0.065))
        .frame(width: size, height: size)

      if !open {
        Circle()
          .fill(ink)
          .frame(width: size * 0.34, height: size * 0.34)
        Circle()
          .fill(Color.white)
          .frame(width: size * 0.22, height: size * 0.22)
        Circle()
          .stroke(ink, lineWidth: max(1.0, size * 0.045))
          .frame(width: size * 0.22, height: size * 0.22)
        Circle()
          .fill(Color(white: 0.82))
          .frame(width: size * 0.08, height: size * 0.08)
      }
    }
    .frame(width: size, height: size + gap)
    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
  }
}
