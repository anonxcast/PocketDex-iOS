import SwiftUI

/// Overlay filters (LCD / LCD Paper / Scanlines / CRT) drawn over the game surface.
struct GameShaderOverlay: View {
  let filter: ScreenFilter
  let grid: GridStrength
  let pixelSize: CGSize

  var body: some View {
    switch filter {
    case .none:
      EmptyView()
    case .lcd:
      LCDGridOverlay(darken: grid.lcdDarken, cell: pixelCell)
    case .lcdPaper:
      LCDPaperOverlay(darken: grid.lcdDarken, cell: pixelCell)
    case .scanlines:
      ScanlinesOverlay(cellHeight: max(1, pixelCell.height))
    case .crt:
      CRTOverlay(cell: pixelCell)
    }
  }

  private var pixelCell: CGSize {
    // Approximate one console pixel on screen.
    let cw = max(1, pixelSize.width / 240)
    let ch = max(1, pixelSize.height / 160)
    return CGSize(width: cw, height: ch)
  }
}

private struct LCDGridOverlay: View {
  let darken: CGFloat
  let cell: CGSize

  var body: some View {
    Canvas { ctx, size in
      var path = Path()
      var x: CGFloat = 0
      while x < size.width {
        path.addRect(CGRect(x: x, y: 0, width: max(1, cell.width / 3), height: size.height))
        x += cell.width
      }
      var y: CGFloat = 0
      while y < size.height {
        path.addRect(CGRect(x: 0, y: y, width: size.width, height: max(1, cell.height / 3)))
        y += cell.height
      }
      ctx.fill(path, with: .color(.black.opacity(darken)))
    }
    .allowsHitTesting(false)
  }
}

private struct LCDPaperOverlay: View {
  let darken: CGFloat
  let cell: CGSize

  var body: some View {
    ZStack {
      // Soft desaturate / paper wash (unlit-like backing tint)
      Color(red: 0.82, green: 0.84, blue: 0.77).opacity(0.10)
      LCDGridOverlay(darken: darken * 0.85, cell: cell)
    }
    .allowsHitTesting(false)
  }
}

private struct ScanlinesOverlay: View {
  let cellHeight: CGFloat

  var body: some View {
    Canvas { ctx, size in
      var path = Path()
      var y: CGFloat = 0
      let h = max(1, cellHeight / 2)
      while y < size.height {
        path.addRect(CGRect(x: 0, y: y, width: size.width, height: h))
        y += cellHeight
      }
      ctx.fill(path, with: .color(.black.opacity(0.45)))
    }
    .allowsHitTesting(false)
  }
}

private struct CRTOverlay: View {
  let cell: CGSize

  var body: some View {
    ZStack {
      // Soft vignette
      RadialGradient(
        colors: [.clear, .black.opacity(0.35)],
        center: .center,
        startRadius: 20,
        endRadius: 420
      )
      // RGB mask stripes
      Canvas { ctx, size in
        let stripe = max(1, cell.width / 3)
        var x: CGFloat = 0
        var i = 0
        while x < size.width {
          let color: Color
          switch i % 3 {
          case 0: color = Color.red.opacity(0.06)
          case 1: color = Color.green.opacity(0.06)
          default: color = Color.blue.opacity(0.06)
          }
          ctx.fill(Path(CGRect(x: x, y: 0, width: stripe, height: size.height)), with: .color(color))
          x += stripe
          i += 1
        }
        var y: CGFloat = 0
        while y < size.height {
          ctx.fill(
            Path(CGRect(x: 0, y: y, width: size.width, height: max(1, cell.height * 0.15))),
            with: .color(.black.opacity(0.25))
          )
          y += cell.height
        }
      }
    }
    .allowsHitTesting(false)
  }
}

struct GameStatusBarStrip: View {
  let location: String?
  let money: Int?
  let inBattle: Bool
  var lead: Mon? = nil
  var tables: Gen3Tables = .retail
  var advice: Gen3BattleCoach.Advice? = nil
  var preferCompactIsland: Bool = false
  var onCycleIslandTip: (() -> Void)? = nil

  var body: some View {
    // Island coaches in battle and on the field (party / bag tips).
    if let advice {
      SmartBattleIsland(
        advice: advice,
        preferCompact: preferCompactIsland,
        onCycleTip: onCycleIslandTip
      )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CETheme.elevated.opacity(0.92))
        .overlay(alignment: .bottom) {
          Rectangle().fill(CETheme.border).frame(height: 1)
        }
    } else {
      HStack(spacing: 10) {
        if lead != nil {
          StarterBadgeView(mon: lead, tables: tables)
        }
        if let location, !location.isEmpty {
          Text(location)
            .font(CETheme.sans(12, weight: .semibold))
            .foregroundStyle(CETheme.crystal.opacity(0.95))
            .lineLimit(1)
        } else if inBattle {
          Text("In battle")
            .font(CETheme.sans(11, weight: .semibold))
            .foregroundStyle(Color(red: 0.9, green: 0.35, blue: 0.35))
            .lineLimit(1)
        }
        Spacer(minLength: 4)
        if let money {
          Text("₽\(money)")
            .font(CETheme.mono(11))
            .foregroundStyle(CETheme.accent)
        }
        if inBattle {
          Text("BATTLE")
            .font(CETheme.sans(10, weight: .bold))
            .foregroundStyle(Color(red: 0.9, green: 0.35, blue: 0.35))
        }
        TimelineView(.periodic(from: .now, by: 30)) { context in
          Text(Self.timeString(context.date))
            .font(CETheme.mono(11))
            .foregroundStyle(CETheme.muted)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(CETheme.elevated.opacity(0.92))
      .overlay(alignment: .bottom) {
        Rectangle().fill(CETheme.border).frame(height: 1)
      }
    }
  }

  private static func timeString(_ date: Date) -> String {
    let f = DateFormatter()
    f.timeStyle = .short
    return f.string(from: date)
  }
}

/// Compact live route + lead sprite chip (no game title, no outer pill around the sprite).
struct PlayTitleChip: View {
  let location: String?
  let lead: Mon?
  let tables: Gen3Tables
  var inBattle: Bool = false

  var body: some View {
    HStack(spacing: 8) {
      StarterBadgeView(mon: lead, tables: tables)
      if let location, !location.isEmpty {
        Text(location)
          .font(CETheme.sans(12, weight: .semibold))
          .foregroundStyle(CETheme.text.opacity(0.92))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(CETheme.card.opacity(0.55), in: Capsule())
          .overlay(Capsule().stroke(CETheme.border.opacity(0.45), lineWidth: 1))
      } else if inBattle {
        Text("In battle")
          .font(CETheme.sans(11, weight: .semibold))
          .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.4))
          .lineLimit(1)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(CETheme.card.opacity(0.55), in: Capsule())
          .overlay(Capsule().stroke(CETheme.border.opacity(0.45), lineWidth: 1))
      }
    }
  }
}

/// Dynamic-Island-style battle coach: headline action + HP + move chips.
/// Overworld / field tips stay compact; battles use the taller layout with move pills.
/// Tap cycles secondary tips (bag / party / coverage) — does not open the companion drawer.
struct SmartBattleIsland: View {
  let advice: Gen3BattleCoach.Advice
  /// Cover / narrow chrome — keeps the tall tier a bit shorter.
  var preferCompact: Bool = false
  var onCycleTip: (() -> Void)? = nil

  private let green = Color(red: 0.22, green: 0.92, blue: 0.40)
  private let amber = Color(red: 1.0, green: 0.78, blue: 0.28)
  private let red = Color(red: 1.0, green: 0.32, blue: 0.30)
  private let ice = Color(red: 0.45, green: 0.86, blue: 1.0)

  @ObservedObject private var live = CompanionLiveStore.shared
  @State private var fxKind: SmartIslandFXKind?
  @State private var fxToken: Int = 0
  /// Queued FX so throw → fail/success play in order without cutting each other off.
  @State private var fxQueue: [SmartIslandFXKind] = []
  /// Last tipId we already animated — held tips must not loop.
  @State private var fxPlayedTrigger: String = ""
  @State private var fxPlayedPulseNonce: UInt64 = 0

  /// Slim overworld strip → roomier “cozy” → full battle / dense coach.
  private enum SizeTier: Int, Equatable {
    case slim = 0
    case cozy = 1
    case tall = 2
  }

  private var showChips: Bool { !advice.dataChips.isEmpty }
  private var hasMoves: Bool { !advice.moves.isEmpty }

  private var sizeTier: SizeTier {
    // Tall only for real battle / catch / win surfaces — not overworld field tips.
    // (Field "CRITICAL" / chips / long detail used to force cozy/tall and broke the 36pt chrome match.)
    let tip = advice.tipId ?? ""
    if hasMoves
      || advice.kind == .catchBall
      || advice.kind == .celebrate
      || advice.kind == .attack
      || advice.kind == .console
      || advice.kind == .switchOut
      || advice.urgency == "CATCH"
      || advice.urgency == "YOU WIN"
      || advice.urgency == "DEFEAT"
      || tip.hasPrefix("evt.battle")
      || tip.hasPrefix("bat.")
      || tip == "evt.ball"
      || tip.hasPrefix("evt.catch") {
      return .tall
    }
    // Brief soft events can use a slightly roomier strip; everyday overworld stays slim.
    if tip == "evt.welcome" || tip == "evt.money" || tip == "evt.heal" || tip == "evt.heal.nurse"
        || tip == "evt.cure"
        || advice.kind == .heal || advice.kind == .revive || advice.kind == .cure {
      return .cozy
    }
    return .slim
  }

  private var islandHeight: CGFloat {
    switch sizeTier {
    case .slim: return 36  // matches top chrome action buttons
    case .cozy: return preferCompact ? 42 : 44
    case .tall: return preferCompact ? 68 : 92
    }
  }

  private var sizeSpring: Animation {
    .spring(response: 0.42, dampingFraction: 0.86)
  }

  var body: some View {
    GeometryReader { geo in
      let narrow = preferCompact || geo.size.width < 340
      Group {
        switch sizeTier {
        case .slim:
          fieldRowBody(slim: true)
        case .cozy:
          fieldRowBody(slim: false)
        case .tall:
          if hasMoves {
            if narrow { richBattleBody(width: geo.size.width) }
            else { fullBody }
          } else {
            richFieldBody(width: geo.size.width)
          }
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
      .overlay {
        SmartIslandFXOverlay(kind: fxKind, token: fxToken) {
          if fxQueue.isEmpty {
            fxKind = nil
          } else {
            let next = fxQueue.removeFirst()
            fxKind = next
            fxToken &+= 1
          }
        }
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: islandHeight)
    .animation(sizeSpring, value: sizeTier)
    .animation(sizeSpring, value: islandHeight)
    .contentShape(Rectangle())
    .onTapGesture {
      InputHaptics.buttonPress()
      onCycleTip?()
    }
    .allowsHitTesting(onCycleTip != nil)
    .onAppear {
      triggerAdviceFX()
      triggerPulseFX()
    }
    .onChange(of: advice.islandFXTrigger) { _, _ in triggerAdviceFX() }
    .onChange(of: live.islandFXPulse?.nonce) { _, _ in triggerPulseFX() }
  }

  private func triggerAdviceFX() {
    let key = advice.islandFXTrigger
    guard !key.isEmpty, let next = advice.islandFX else { return }
    // Same held event — play once only.
    guard key != fxPlayedTrigger else { return }
    fxPlayedTrigger = key
    playFX(next)
  }

  /// Ball throw / catch result — published even when urgent CATCH tips replace evt.ball text.
  private func triggerPulseFX() {
    let batch = live.islandFXBatch
    if !batch.isEmpty {
      for pulse in batch where pulse.nonce > fxPlayedPulseNonce {
        fxPlayedPulseNonce = pulse.nonce
        playFX(pulse.kind)
      }
      return
    }
    guard let pulse = live.islandFXPulse, pulse.nonce != fxPlayedPulseNonce else { return }
    fxPlayedPulseNonce = pulse.nonce
    playFX(pulse.kind)
  }

  private func playFX(_ kind: SmartIslandFXKind) {
    // Catch result should never sit behind a long throw — cut straight to it.
    // Success always wins over a queued/playing fail (Gotcha after a false miss).
    if kind == .catchSuccess {
      fxQueue.removeAll { $0 == .pokeBallThrow || $0 == .catchSuccess || $0 == .catchFail }
      fxKind = kind
      fxToken &+= 1
      return
    }
    if kind == .catchFail {
      fxQueue.removeAll { $0 == .pokeBallThrow || $0 == .catchFail }
      // Don't clobber a success that's already playing / queued.
      if fxKind == .catchSuccess || fxQueue.contains(.catchSuccess) { return }
      if fxKind == .pokeBallThrow || fxKind == nil {
        fxKind = kind
        fxToken &+= 1
        return
      }
      fxQueue.insert(kind, at: 0)
      return
    }
    if fxKind != nil {
      fxQueue.append(kind)
      return
    }
    fxKind = kind
    fxToken &+= 1
  }

  /// Overworld strip — slim matches the 36pt action buttons; cozy adds a detail line + chips.
  private func fieldRowBody(slim: Bool) -> some View {
    VStack(alignment: .leading, spacing: slim ? 0 : 3) {
      HStack(alignment: .center, spacing: 6) {
        if !slim {
          slimHpStack(width: 28)
        }
        if let urgency = advice.urgency {
          Text(urgency)
            .font(CETheme.sans(slim ? 7 : 8, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(urgencyColor)
            .lineLimit(1)
            .fixedSize()
        }
        Text(advice.headline)
          .font(CETheme.sans(slim ? 12 : 13, weight: .bold))
          .foregroundStyle(Color.white)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        if slim, !advice.detail.isEmpty {
          Text("·")
            .font(CETheme.sans(10, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.28))
          Text(advice.detail)
            .font(CETheme.sans(9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.62))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
        }
        Spacer(minLength: 4)
        if slim, showChips {
          chipRow(limit: 2)
        }
        if let hint = advice.itemHint, !hint.isEmpty {
          Text(hint)
            .font(CETheme.sans(8, weight: .semibold))
            .foregroundStyle(ice.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
      }
      if !slim {
        if !advice.detail.isEmpty {
          Text(advice.detail)
            .font(CETheme.sans(10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.64))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        if showChips {
          chipRow(limit: 5)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, slim ? 4 : 6)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(islandChrome(corner: slim ? 18 : 16))
  }

  /// Tall field events (catch / celebrate / welcome) — room for pixel FX.
  private func richFieldBody(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 7) {
        slimHpStack(width: 30)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            if let urgency = advice.urgency {
              Text(urgency)
                .font(CETheme.sans(8, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(urgencyColor)
                .lineLimit(1)
                .fixedSize()
            }
            Text(advice.headline)
              .font(CETheme.sans(13, weight: .bold))
              .foregroundStyle(Color.white)
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }
          if !advice.detail.isEmpty {
            Text(advice.detail)
              .font(CETheme.sans(10, weight: .medium))
              .foregroundStyle(Color.white.opacity(0.64))
              .lineLimit(2)
              .minimumScaleFactor(0.7)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if let hint = advice.itemHint, !hint.isEmpty {
          Text(hint)
            .font(CETheme.sans(8, weight: .semibold))
            .foregroundStyle(ice.opacity(0.92))
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: min(88, width * 0.22), alignment: .trailing)
        }
      }
      if showChips {
        chipRow(limit: 5)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(islandChrome(corner: 16))
  }

  /// Tall battle in chrome / cover — two text lines + best move, FX-friendly height.
  private func richBattleBody(width: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 7) {
      slimHpStack(width: 30)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          if let urgency = advice.urgency {
            Text(urgency)
              .font(CETheme.sans(8, weight: .bold))
              .tracking(0.5)
              .foregroundStyle(urgencyColor)
              .lineLimit(1)
              .fixedSize()
          }
          Text(advice.headline)
            .font(CETheme.sans(13, weight: .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
        }
        if !advice.detail.isEmpty {
          Text(advice.detail)
            .font(CETheme.sans(10, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.62))
            .lineLimit(1)
            .minimumScaleFactor(0.68)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let best = advice.bestMove ?? advice.moves.first {
        movePill(best, highlighted: true, compact: true)
          .frame(maxWidth: min(120, width * 0.30))
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(islandChrome(corner: 16))
  }

  private var fullBody: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .center, spacing: 9) {
        hpStack(width: 56)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            if let urgency = advice.urgency {
              Text(urgency)
                .font(CETheme.sans(9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(urgencyColor)
                .lineLimit(1)
            }
            if let kind = advice.battleKind {
              Text(kind.uppercased())
                .font(CETheme.sans(8, weight: .bold))
                .tracking(0.3)
                .foregroundStyle(Color.white.opacity(0.42))
            }
            if let lv = advice.foeLevel, lv > 0 {
              Text("Lv\(lv)")
                .font(CETheme.mono(9))
                .foregroundStyle(Color.white.opacity(0.55))
            }
            if let types = advice.foeTypes, !types.isEmpty {
              Text(types)
                .font(CETheme.sans(8, weight: .semibold))
                .foregroundStyle(ice.opacity(0.88))
                .lineLimit(1)
            }
          }
          Text(advice.headline)
            .font(CETheme.sans(15, weight: .bold))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
          if !advice.detail.isEmpty {
            Text(advice.detail)
              .font(CETheme.sans(11, weight: .medium))
              .foregroundStyle(Color.white.opacity(0.64))
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let hint = advice.itemHint, !hint.isEmpty {
          Text(hint)
            .font(CETheme.sans(9, weight: .semibold))
            .foregroundStyle(ice.opacity(0.92))
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 76, alignment: .trailing)
        }
      }

      if showChips {
        chipRow(limit: 4)
      }

      if !advice.moves.isEmpty {
        HStack(spacing: 5) {
          ForEach(Array(advice.moves.prefix(4))) { mv in
            movePill(mv, highlighted: mv.slot == advice.bestMove?.slot, compact: false)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(islandChrome(corner: 18))
  }

  private func chipRow(limit: Int) -> some View {
    HStack(spacing: 5) {
      ForEach(Array(advice.dataChips.prefix(limit)), id: \.self) { chip in
        Text(chip)
          .font(CETheme.sans(8, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.78))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.white.opacity(0.11)))
          .lineLimit(1)
      }
      if !advice.secondaryTips.isEmpty {
        Text("tap ↻")
          .font(CETheme.sans(8, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.38))
      }
      Spacer(minLength: 0)
    }
  }

  private var isCelebrate: Bool { advice.kind == .celebrate }
  private var isWelcome: Bool { advice.urgency == "WELCOME" }
  private var isNurseJoy: Bool {
    advice.urgency == "NURSE JOY" || advice.tipId == "evt.heal.nurse"
  }

  private func islandChrome(corner: CGFloat) -> some View {
    let glow = borderGlow
    let vivid = isCelebrate || isWelcome || isNurseJoy
    return RoundedRectangle(cornerRadius: corner, style: .continuous)
      .fill(
        isCelebrate
          ? LinearGradient(
              colors: [
                Color(red: 0.08, green: 0.24, blue: 0.12).opacity(0.94),
                Color(red: 0.10, green: 0.16, blue: 0.06).opacity(0.90),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          : isWelcome
            ? LinearGradient(
                colors: [
                  Color(red: 0.07, green: 0.16, blue: 0.32).opacity(0.94),
                  Color(red: 0.04, green: 0.09, blue: 0.20).opacity(0.90),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            : LinearGradient(
                colors: [
                  Color.black.opacity(0.78),
                  Color(red: 0.05, green: 0.06, blue: 0.08).opacity(0.74),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
      )
      .overlay(
        RoundedRectangle(cornerRadius: corner, style: .continuous)
          .stroke(
            LinearGradient(
              colors: [
                Color.white.opacity(vivid ? 0.28 : 0.14),
                glow.opacity(vivid ? 0.90 : 0.45),
              ],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: vivid ? 2.0 : 1.1
          )
      )
      .shadow(color: glow.opacity(vivid ? 0.58 : 0.24), radius: vivid ? 14 : 9, y: 2)
  }

  private func hpStack(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      hpBar(label: "YOU", pct: advice.allyHpPct, tint: allyTint)
      hpBar(label: "FOE", pct: advice.foeHpPct ?? -1, tint: red.opacity(0.9))
    }
    .frame(width: width)
  }

  /// Label-free twin bars for the 36pt chrome strip.
  private func slimHpStack(width: CGFloat) -> some View {
    VStack(spacing: 3) {
      slimHpBar(pct: advice.allyHpPct, tint: allyTint)
      slimHpBar(pct: advice.foeHpPct ?? -1, tint: red.opacity(0.9))
    }
    .frame(width: width)
  }

  private func slimHpBar(pct: Int, tint: Color) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.white.opacity(0.14))
        if pct >= 0 {
          Capsule()
            .fill(tint)
            .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, pct))) / 100.0))
        }
      }
    }
    .frame(height: 3)
  }

  private func hpBar(label: String, pct: Int, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 3) {
        Text(label)
          .font(CETheme.sans(7, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.45))
        Spacer(minLength: 0)
        if pct >= 0 {
          Text("\(pct)%")
            .font(CETheme.mono(8))
            .foregroundStyle(Color.white.opacity(0.75))
        } else {
          Text("—")
            .font(CETheme.mono(8))
            .foregroundStyle(Color.white.opacity(0.35))
        }
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.12))
          if pct >= 0 {
            Capsule()
              .fill(tint)
              .frame(width: max(3, geo.size.width * CGFloat(min(100, max(0, pct))) / 100.0))
          }
        }
      }
      .frame(height: 4)
    }
  }

  @ViewBuilder
  private func movePill(
    _ mv: Gen3BattleData.MoveSuggestion,
    highlighted: Bool,
    compact: Bool
  ) -> some View {
    let accent = multColor(mv)
    HStack(spacing: 3) {
      Text(mv.name)
        .font(CETheme.sans(compact ? 9 : 10, weight: highlighted ? .bold : .semibold))
        .foregroundStyle(Color.white.opacity(mv.pp > 0 ? 0.96 : 0.35))
        .lineLimit(1)
        .minimumScaleFactor(0.55)
      if mv.power > 0 {
        Text(mv.multiplierLabel)
          .font(CETheme.mono(compact ? 9 : 10))
          .fontWeight(.bold)
          .foregroundStyle(accent)
          .fixedSize()
      }
    }
    .padding(.horizontal, compact ? 5 : 6)
    .padding(.vertical, compact ? 3 : 4)
    .frame(maxWidth: .infinity)
    .background(
      Capsule().fill(accent.opacity(highlighted ? 0.30 : 0.12))
    )
    .overlay(
      Capsule().stroke(accent.opacity(highlighted ? 0.95 : 0.35), lineWidth: highlighted ? 1.5 : 1)
    )
  }

  /// Electric lime — pops when a talk-tip quest lands.
  private var celebrateLime: Color { Color(red: 0.45, green: 1.0, blue: 0.35) }
  private var celebrateGold: Color { Color(red: 1.0, green: 0.85, blue: 0.25) }

  private var nursePink: Color { Color(red: 1.0, green: 0.55, blue: 0.72) }

  private var urgencyColor: Color {
    if advice.urgency == "WELCOME" { return celebrateGold }
    if advice.urgency == "NURSE JOY" || advice.tipId == "evt.heal.nurse" { return nursePink }
    switch advice.kind {
    case .heal, .revive, .cure: return amber
    case .catchBall: return ice
    case .switchOut: return Color(red: 1.0, green: 0.55, blue: 0.35)
    case .celebrate: return celebrateGold
    case .console: return red
    case .field: return CETheme.crystal
    case .attack where (advice.bestMove?.multiplierPct ?? 0) >= 200: return green
    default: return ice.opacity(0.85)
    }
  }

  private var borderGlow: Color {
    if advice.urgency == "WELCOME" { return ice }
    // Nurse Joy / Pokémon Center heal — pink island outline.
    if advice.urgency == "NURSE JOY" || advice.tipId == "evt.heal.nurse" { return nursePink }
    switch advice.kind {
    case .heal, .revive, .cure: return amber
    case .catchBall: return ice
    case .switchOut: return Color(red: 1.0, green: 0.55, blue: 0.35)
    case .celebrate: return celebrateLime
    case .console: return red
    case .field: return CETheme.crystal
    case .attack where (advice.bestMove?.multiplierPct ?? 0) >= 200: return green
    default: return CETheme.crystal
    }
  }

  private var allyTint: Color {
    if advice.allyHpPct <= 25 { return red }
    if advice.allyHpPct <= 50 { return amber }
    return green
  }

  private func multColor(_ mv: Gen3BattleData.MoveSuggestion) -> Color {
    if mv.power <= 0 { return CETheme.muted }
    if mv.multiplierPct >= 200 { return green }
    if mv.multiplierPct < 100 { return red }
    return Color.white.opacity(0.85)
  }
}
