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

  var body: some View {
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

/// Same-row landscape strip: move tips next to the route, stretching to the chrome icons.
/// Green = super-effective, red = resisted/immune; always shows 2× / 1× / ½× / 0×.
struct BattleSuggestChip: View {
  let foeName: String
  let moves: [Gen3BattleData.MoveSuggestion]

  private let green = Color(red: 0.22, green: 0.92, blue: 0.40)
  private let red = Color(red: 1.0, green: 0.28, blue: 0.28)

  var body: some View {
    HStack(spacing: 6) {
      Text("vs \(foeName)")
        .font(CETheme.sans(10, weight: .bold))
        .foregroundStyle(CETheme.crystal)
        .lineLimit(1)
        .fixedSize()

      ForEach(Array(moves.prefix(4))) { mv in
        moveCell(mv)
          .frame(maxWidth: .infinity)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.black.opacity(0.55), in: Capsule())
    .overlay(Capsule().stroke(CETheme.border.opacity(0.55), lineWidth: 1))
    .allowsHitTesting(false)
  }

  @ViewBuilder
  private func moveCell(_ mv: Gen3BattleData.MoveSuggestion) -> some View {
    let accent = multColor(mv)
    HStack(spacing: 3) {
      Text(mv.name)
        .font(CETheme.sans(10, weight: .semibold))
        .foregroundStyle(CETheme.text.opacity(mv.pp > 0 ? 0.95 : 0.4))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
      if mv.power > 0 {
        Text(mv.multiplierLabel)
          .font(CETheme.mono(11))
          .fontWeight(.bold)
          .foregroundStyle(accent)
          .lineLimit(1)
          .fixedSize()
      } else {
        Text("—")
          .font(CETheme.mono(10))
          .foregroundStyle(CETheme.muted)
          .fixedSize()
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .frame(maxWidth: .infinity)
    .background(accent.opacity(mv.power > 0 ? 0.18 : 0.08), in: Capsule())
    .overlay(Capsule().stroke(accent.opacity(mv.power > 0 ? 0.75 : 0.25), lineWidth: 1.2))
  }

  private func multColor(_ mv: Gen3BattleData.MoveSuggestion) -> Color {
    if mv.power <= 0 { return CETheme.muted }
    if mv.multiplierPct >= 200 { return green }
    if mv.multiplierPct < 100 { return red }
    return Color.white.opacity(0.85)
  }
}
