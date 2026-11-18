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
  /// Force the short cover-screen layout (also auto when width is narrow).
  var preferCompact: Bool = false
  var onCycleTip: (() -> Void)? = nil

  private let green = Color(red: 0.22, green: 0.92, blue: 0.40)
  private let amber = Color(red: 1.0, green: 0.78, blue: 0.28)
  private let red = Color(red: 1.0, green: 0.32, blue: 0.30)
  private let ice = Color(red: 0.45, green: 0.86, blue: 1.0)

  /// No move chips → overworld / bag coach.
  private var fieldOneRow: Bool { advice.moves.isEmpty }
  private var showChips: Bool { !advice.dataChips.isEmpty }
  private var islandHeight: CGFloat {
    if fieldOneRow { return showChips ? 52 : 40 }
    return preferCompact ? 56 : 86
  }

  var body: some View {
    GeometryReader { geo in
      let compact = fieldOneRow || preferCompact || geo.size.width < 340 || geo.size.height < 64
      Group {
        if fieldOneRow {
          fieldRowBody
        } else if compact {
          compactBody(width: geo.size.width)
        } else {
          fullBody
        }
      }
      .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity)
    .frame(height: islandHeight)
    .contentShape(Rectangle())
    .onTapGesture {
      InputHaptics.buttonPress()
      onCycleTip?()
    }
    .allowsHitTesting(onCycleTip != nil)
  }

  /// Field strip: HP · urgency · headline · chips · bag hint.
  private var fieldRowBody: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        hpStack(width: 36)
        if let urgency = advice.urgency {
          Text(urgency)
            .font(CETheme.sans(7, weight: .bold))
            .tracking(0.35)
            .foregroundStyle(urgencyColor)
            .lineLimit(1)
            .fixedSize()
        }
        Text(advice.headline)
          .font(CETheme.sans(11, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.96))
          .lineLimit(1)
          .minimumScaleFactor(0.7)
        if !advice.detail.isEmpty {
          Text("·")
            .font(CETheme.sans(10, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.35))
          Text(advice.detail)
            .font(CETheme.sans(9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.58))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
        }
        Spacer(minLength: 4)
        if let hint = advice.itemHint, !hint.isEmpty {
          Text(hint)
            .font(CETheme.sans(8, weight: .semibold))
            .foregroundStyle(ice.opacity(0.9))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
      }
      if showChips {
        chipRow(limit: 5)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(islandChrome(corner: 12))
  }

  private var fullBody: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .center, spacing: 8) {
        hpStack(width: 54)
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 5) {
            if let urgency = advice.urgency {
              Text(urgency)
                .font(CETheme.sans(8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(urgencyColor)
                .lineLimit(1)
            }
            if let kind = advice.battleKind {
              Text(kind.uppercased())
                .font(CETheme.sans(7, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
            }
            if let lv = advice.foeLevel, lv > 0 {
              Text("Lv\(lv)")
                .font(CETheme.mono(8))
                .foregroundStyle(Color.white.opacity(0.55))
            }
            if let types = advice.foeTypes, !types.isEmpty {
              Text(types)
                .font(CETheme.sans(7, weight: .semibold))
                .foregroundStyle(ice.opacity(0.85))
                .lineLimit(1)
            }
          }
          Text(advice.headline)
            .font(CETheme.sans(12, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.96))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
          Text(advice.detail)
            .font(CETheme.sans(9, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.62))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if let hint = advice.itemHint, !hint.isEmpty {
          Text(hint)
            .font(CETheme.sans(8, weight: .semibold))
            .foregroundStyle(ice.opacity(0.9))
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: 72, alignment: .trailing)
        }
      }

      if showChips {
        chipRow(limit: 4)
      }

      if !advice.moves.isEmpty {
        HStack(spacing: 4) {
          ForEach(Array(advice.moves.prefix(4))) { mv in
            movePill(mv, highlighted: mv.slot == advice.bestMove?.slot, compact: false)
              .frame(maxWidth: .infinity)
          }
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(islandChrome(corner: 18))
  }

  private func compactBody(width: CGFloat) -> some View {
    HStack(spacing: 6) {
      hpStack(width: 40)
      VStack(alignment: .leading, spacing: 1) {
        HStack(spacing: 4) {
          if let urgency = advice.urgency {
            Text(urgency)
              .font(CETheme.sans(7, weight: .bold))
              .tracking(0.4)
              .foregroundStyle(urgencyColor)
              .lineLimit(1)
          }
          Text(advice.headline)
            .font(CETheme.sans(11, weight: .bold))
            .foregroundStyle(Color.white.opacity(0.96))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        Text(advice.detail)
          .font(CETheme.sans(8, weight: .medium))
          .foregroundStyle(Color.white.opacity(0.58))
          .lineLimit(1)
          .minimumScaleFactor(0.65)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let best = advice.bestMove ?? advice.moves.first {
        movePill(best, highlighted: true, compact: true)
          .frame(maxWidth: min(110, width * 0.28))
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .background(islandChrome(corner: 14))
  }

  private func chipRow(limit: Int) -> some View {
    HStack(spacing: 4) {
      ForEach(Array(advice.dataChips.prefix(limit)), id: \.self) { chip in
        Text(chip)
          .font(CETheme.sans(7, weight: .semibold))
          .foregroundStyle(Color.white.opacity(0.72))
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Capsule().fill(Color.white.opacity(0.10)))
          .lineLimit(1)
      }
      if !advice.secondaryTips.isEmpty {
        Text("tap ↻")
          .font(CETheme.sans(7, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.35))
      }
      Spacer(minLength: 0)
    }
  }

  private func islandChrome(corner: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: corner, style: .continuous)
      .fill(Color.black.opacity(0.72))
      .overlay(
        RoundedRectangle(cornerRadius: corner, style: .continuous)
          .stroke(borderGlow.opacity(0.55), lineWidth: 1)
      )
      .shadow(color: borderGlow.opacity(0.22), radius: 8, y: 2)
  }

  private func hpStack(width: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      hpBar(label: "YOU", pct: advice.allyHpPct, tint: allyTint)
      hpBar(label: "FOE", pct: advice.foeHpPct ?? -1, tint: red.opacity(0.9))
    }
    .frame(width: width)
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
    HStack(spacing: 2) {
      Text(mv.name)
        .font(CETheme.sans(compact ? 8 : 9, weight: highlighted ? .bold : .semibold))
        .foregroundStyle(Color.white.opacity(mv.pp > 0 ? 0.95 : 0.35))
        .lineLimit(1)
        .minimumScaleFactor(0.55)
      if mv.power > 0 {
        Text(mv.multiplierLabel)
          .font(CETheme.mono(compact ? 8 : 9))
          .fontWeight(.bold)
          .foregroundStyle(accent)
          .fixedSize()
      }
    }
    .padding(.horizontal, compact ? 4 : 5)
    .padding(.vertical, compact ? 2 : 3)
    .frame(maxWidth: .infinity)
    .background(
      Capsule().fill(accent.opacity(highlighted ? 0.28 : 0.12))
    )
    .overlay(
      Capsule().stroke(accent.opacity(highlighted ? 0.95 : 0.35), lineWidth: highlighted ? 1.4 : 1)
    )
  }

  private var urgencyColor: Color {
    switch advice.kind {
    case .heal, .revive, .cure: return amber
    case .catchBall: return ice
    case .switchOut: return Color(red: 1.0, green: 0.55, blue: 0.35)
    case .celebrate: return green
    case .console: return red
    case .field: return CETheme.crystal
    case .attack where (advice.bestMove?.multiplierPct ?? 0) >= 200: return green
    default: return ice.opacity(0.85)
    }
  }

  private var borderGlow: Color {
    switch advice.kind {
    case .heal, .revive, .cure: return amber
    case .catchBall: return ice
    case .switchOut: return Color(red: 1.0, green: 0.55, blue: 0.35)
    case .celebrate: return green
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
