import SwiftUI

/// RetroAchievements username + web API key (Keychain), mirrored after SteamGridDB login card.
struct RetroAchievementsSettingsCard: View {
  @State private var usernameDraft = ""
  @State private var keyDraft = ""
  @State private var profile: RetroAchievementsClient.Profile?
  @State private var status = ""
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Image(systemName: profile != nil ? "trophy.fill" : "trophy")
          .foregroundStyle(profile != nil ? Color(red: 0.95, green: 0.78, blue: 0.25) : CETheme.accent)
        VStack(alignment: .leading, spacing: 2) {
          Text("RetroAchievements")
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(CETheme.text)
          if let profile {
            Text("Signed in as \(profile.displayName)")
              .font(CETheme.sans(12, weight: .medium))
              .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.55))
          } else {
            Text("Track achievement progress on each game page")
              .font(CETheme.sans(12))
              .foregroundStyle(CETheme.muted)
          }
        }
        Spacer()
      }

      if let profile {
        HStack(spacing: 8) {
          Image(systemName: "person.crop.circle.fill")
            .foregroundStyle(CETheme.crystal)
          Text("\(profile.totalPoints) pts")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(CETheme.text)
          Text("·")
            .foregroundStyle(CETheme.muted)
          Text("\(profile.softcorePoints) softcore")
            .font(CETheme.sans(13))
            .foregroundStyle(CETheme.muted)
          Spacer()
        }
        .padding(12)
        .background(Color(red: 0.12, green: 0.18, blue: 0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.30, green: 0.45, blue: 0.30), lineWidth: 1))
      }

      TextField("Username", text: $usernameDraft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(CETheme.mono(13))
        .foregroundStyle(CETheme.text)
        .padding(12)
        .background(CETheme.hover, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CETheme.border, lineWidth: 1))

      SecureField("Web API key", text: $keyDraft)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(CETheme.mono(13))
        .foregroundStyle(CETheme.text)
        .padding(12)
        .background(CETheme.hover, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CETheme.border, lineWidth: 1))

      HStack(spacing: 10) {
        Button {
          Task { await saveAndLogin() }
        } label: {
          Text(busy ? "…" : "Save & Sign In")
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(CETheme.crystal, in: Capsule())
        }
        .disabled(busy || usernameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if profile != nil {
          Button("Sign Out") {
            Task {
              await RetroAchievementsClient.shared.signOut()
              profile = nil
              usernameDraft = ""
              keyDraft = ""
              status = "Signed out"
            }
          }
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.muted)
        }
      }

      Link(
        "Get your web API key",
        destination: URL(string: "https://retroachievements.org/controlpanel.php")!
      )
      .font(CETheme.sans(12, weight: .semibold))
      .foregroundStyle(CETheme.crystal)

      if !status.isEmpty {
        Text(status)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
      }
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
    .task { await refresh() }
  }

  private func refresh() async {
    if await RetroAchievementsClient.shared.isSignedIn() {
      usernameDraft = await RetroAchievementsClient.shared.cachedUsername() ?? ""
      do {
        profile = try await RetroAchievementsClient.shared.fetchProfile()
        status = ""
      } catch {
        profile = nil
        status = error.localizedDescription
      }
    }
  }

  private func saveAndLogin() async {
    busy = true
    defer { busy = false }
    do {
      profile = try await RetroAchievementsClient.shared.login(
        username: usernameDraft,
        apiKey: keyDraft
      )
      keyDraft = ""
      status = "Signed in"
    } catch {
      profile = nil
      status = error.localizedDescription
    }
  }
}
