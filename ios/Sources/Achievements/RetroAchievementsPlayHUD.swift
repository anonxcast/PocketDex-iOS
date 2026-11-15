import Foundation
import SwiftUI

/// In-play RetroAchievements banners for the battle-tip chrome row.
@MainActor
final class RetroAchievementsPlayHUD: ObservableObject {
  enum Banner: Equatable, Identifiable {
    case tracking(gameTitle: String, iconUrl: String?)
    case unlocked(id: Int, title: String, description: String, points: Int, badgeUrl: String?)

    var id: String {
      switch self {
      case .tracking(let title, _): return "track-\(title)"
      case .unlocked(let id, _, _, _, _): return "unlock-\(id)"
      }
    }
  }

  @Published private(set) var banner: Banner?
  @Published private(set) var isTracking = false

  private var gameId: Int?
  private var knownEarned: Set<Int> = []
  private var pendingUnlocks: [Banner] = []
  private var pollTask: Task<Void, Never>?
  private var dismissTask: Task<Void, Never>?
  private var sessionGeneration = 0

  func start(forRom url: URL) {
    stop()
    sessionGeneration &+= 1
    let gen = sessionGeneration
    pollTask = Task { @MainActor in
      guard await RetroAchievementsClient.shared.isSignedIn() else { return }
      do {
        let info = try await RetroAchievementsClient.shared.supportedGame(forRomAt: url)
        guard gen == sessionGeneration else { return }
        gameId = info.gameId
        isTracking = true

        // Baseline earned set so we only toast new unlocks this session.
        if let progress = try? await RetroAchievementsClient.shared.progress(forGameId: info.gameId) {
          guard gen == sessionGeneration else { return }
          knownEarned = Set(progress.achievements.filter(\.isEarned).map(\.id))
        }

        present(
          .tracking(gameTitle: info.title, iconUrl: info.iconUrl),
          duration: 4.2
        )
        InputHaptics.selectionChange()

        // Poll for newly earned achievements while this play session is open.
        while !Task.isCancelled, gen == sessionGeneration {
          try? await Task.sleep(nanoseconds: 25_000_000_000) // 25s
          guard gen == sessionGeneration, let gameId else { break }
          await pollForUnlocks(gameId: gameId, generation: gen)
        }
      } catch RetroAchievementsClient.RAError.noGame {
        // ROM has no RA set — stay quiet.
      } catch {
        // Network / auth — stay quiet in play.
      }
    }
  }

  func stop() {
    sessionGeneration &+= 1
    pollTask?.cancel()
    pollTask = nil
    dismissTask?.cancel()
    dismissTask = nil
    banner = nil
    pendingUnlocks.removeAll()
    knownEarned.removeAll()
    gameId = nil
    isTracking = false
  }

  private func pollForUnlocks(gameId: Int, generation: Int) async {
    // Prefer progress diff (authoritative for this game).
    if let progress = try? await RetroAchievementsClient.shared.progress(forGameId: gameId) {
      guard generation == sessionGeneration else { return }
      let earned = progress.achievements.filter(\.isEarned)
      let fresh = earned.filter { !knownEarned.contains($0.id) }
      for ach in fresh {
        knownEarned.insert(ach.id)
        enqueueUnlock(ach)
      }
    }

    // Also check recent feed in case progress lags.
    if let recent = try? await RetroAchievementsClient.shared.recentAchievements(forGameId: gameId, minutes: 120) {
      guard generation == sessionGeneration else { return }
      for pair in recent where !knownEarned.contains(pair.achievement.id) {
        knownEarned.insert(pair.achievement.id)
        enqueueUnlock(pair.achievement)
      }
    }
  }

  private func enqueueUnlock(_ ach: RetroAchievementsClient.Achievement) {
    let next: Banner = .unlocked(
      id: ach.id,
      title: ach.title,
      description: ach.description,
      points: ach.points,
      badgeUrl: ach.badgeUrl
    )
    if banner == nil {
      present(next, duration: 5.0)
      InputHaptics.buttonPress()
    } else {
      pendingUnlocks.append(next)
    }
  }

  private func present(_ next: Banner, duration: TimeInterval) {
    dismissTask?.cancel()
    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
      banner = next
    }
    dismissTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.28)) {
        banner = nil
      }
      try? await Task.sleep(nanoseconds: 220_000_000)
      guard !Task.isCancelled else { return }
      if let queued = pendingUnlocks.first {
        pendingUnlocks.removeFirst()
        present(queued, duration: 5.0)
        InputHaptics.buttonPress()
      }
    }
  }
}

/// Same chrome row as battle move tips — tracking / unlock toast.
struct RAAchievementChip: View {
  let banner: RetroAchievementsPlayHUD.Banner

  private let gold = Color(red: 0.98, green: 0.78, blue: 0.28)
  private let goldDeep = Color(red: 0.85, green: 0.55, blue: 0.12)

  @State private var pulse = false
  @State private var shimmer = false

  var body: some View {
    HStack(spacing: 8) {
      badge
        .frame(width: 26, height: 26)
        .scaleEffect(pulse ? 1.08 : 0.92)
        .animation(
          .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
          value: pulse
        )

      VStack(alignment: .leading, spacing: 1) {
        Text(headline)
          .font(CETheme.sans(10, weight: .bold))
          .foregroundStyle(gold)
          .lineLimit(1)
        Text(detail)
          .font(CETheme.sans(11, weight: .semibold))
          .foregroundStyle(CETheme.text)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if case .unlocked(_, _, _, let points, _) = banner, points > 0 {
        Text("+\(points)")
          .font(CETheme.mono(12))
          .fontWeight(.bold)
          .foregroundStyle(gold)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(gold.opacity(0.16), in: Capsule())
          .overlay(Capsule().stroke(gold.opacity(0.7), lineWidth: 1))
          .fixedSize()
      } else {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(gold.opacity(0.9))
          .opacity(shimmer ? 1 : 0.45)
          .animation(
            .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
            value: shimmer
          )
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [
          Color.black.opacity(0.72),
          goldDeep.opacity(0.28),
          Color.black.opacity(0.72),
        ],
        startPoint: shimmer ? .leading : .trailing,
        endPoint: shimmer ? .trailing : .leading
      ),
      in: Capsule()
    )
    .overlay(
      Capsule()
        .stroke(
          LinearGradient(
            colors: [gold.opacity(0.95), goldDeep.opacity(0.55), gold.opacity(0.95)],
            startPoint: .leading,
            endPoint: .trailing
          ),
          lineWidth: 1.4
        )
    )
    .shadow(color: gold.opacity(0.35), radius: pulse ? 10 : 4, y: 1)
    .allowsHitTesting(false)
    .onAppear {
      pulse = true
      shimmer = true
    }
  }

  private var headline: String {
    switch banner {
    case .tracking: return "RETROACHIEVEMENTS"
    case .unlocked: return "ACHIEVEMENT UNLOCKED"
    }
  }

  private var detail: String {
    switch banner {
    case .tracking(let title, _):
      return "Tracking · \(title)"
    case .unlocked(_, let title, let description, _, _):
      return description.isEmpty ? title : "\(title) — \(description)"
    }
  }

  @ViewBuilder
  private var badge: some View {
    switch banner {
    case .tracking(_, let iconUrl):
      if let iconUrl, let url = URL(string: iconUrl) {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let img):
            img.resizable().scaledToFill()
          default:
            Image(systemName: "trophy.fill")
              .font(.system(size: 13, weight: .bold))
              .foregroundStyle(gold)
          }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      } else {
        Image(systemName: "trophy.fill")
          .font(.system(size: 14, weight: .bold))
          .foregroundStyle(gold)
          .frame(width: 26, height: 26)
          .background(gold.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
    case .unlocked(_, _, _, _, let badgeUrl):
      if let badgeUrl, let url = URL(string: badgeUrl) {
        AsyncImage(url: url) { phase in
          switch phase {
          case .success(let img):
            img.resizable().scaledToFill()
          default:
            Image(systemName: "star.circle.fill")
              .font(.system(size: 16, weight: .bold))
              .foregroundStyle(gold)
          }
        }
        .frame(width: 26, height: 26)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      } else {
        Image(systemName: "star.circle.fill")
          .font(.system(size: 16, weight: .bold))
          .foregroundStyle(gold)
          .frame(width: 26, height: 26)
      }
    }
  }
}
