import SwiftUI

/// Per-game hub: hero art, Play / Edit, summary, real in-game snaps, RetroAchievements progress.
/// Open Duo / phone layouts stay as-is; closed outer face uses a compact safe-area layout.
struct GameDetailView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @ObservedObject private var artworkStore = RomArtworkStore.shared
  let rom: RomItem
  let onPlay: (RomItem) -> Void

  @State private var artworkTarget: ArtworkTarget?
  @State private var screenshots: [UIImage] = []
  @State private var screenshotsStatus = ""
  @State private var screenshotViewer: ScreenshotViewerSelection?
  @State private var summaryTitle = ""
  @State private var summaryBody = ""
  @State private var summaryBusy = false
  @State private var summarySource: URL?
  @State private var raProgress: RetroAchievementsClient.GameProgress?
  @State private var raStatus = ""
  @State private var raBusy = false
  /// Duo hinge closed (front / outer display). Cleared when the device opens.
  @State private var hingeClosed = false

  /// Compact game-page chrome: outer Duo face only.
  /// Open Duo is regular width — keep the full Play / Edit row there.
  private var outerDisplay: Bool {
    hingeClosed && horizontalSizeClass == .compact
  }

  var body: some View {
    // Do NOT wrap in GeometryReader — it expands under Duo’s vertical system chrome
    // and lays content out wider than the visible column (clipped Play/Edit, About, RA).
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        heroHeader
        actionRow
          .padding(.horizontal, outerDisplay ? 12 : 16)
          .padding(.top, outerDisplay ? 10 : 16)
        summarySection
          .padding(.horizontal, outerDisplay ? 12 : 16)
          .padding(.top, outerDisplay ? 14 : 22)
        screenshotsSection
          .padding(.top, outerDisplay ? 14 : 22)
        achievementsSection
          .padding(.horizontal, outerDisplay ? 12 : 16)
          .padding(.top, outerDisplay ? 14 : 22)
          .padding(.bottom, 40)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(GlassChrome.canvas.ignoresSafeArea())
    .navigationTitle(rom.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .modifier(DuoHingeClosedObserver { closed in
      hingeClosed = closed
    })
    .onChange(of: horizontalSizeClass) { _, size in
      // Opening Duo → regular width; drop outer chrome even if hinge lags.
      if size == .regular { hingeClosed = false }
    }
    .sheet(item: $artworkTarget) { target in
      ArtworkPickerSheet(rom: target.rom, initialKind: target.kind)
    }
    .fullScreenCover(item: $screenshotViewer) { sel in
      ScreenshotViewer(images: screenshots, startIndex: sel.id) {
        screenshotViewer = nil
      }
    }
    .task(id: "\(rom.artworkKey)-\(artworkStore.revision)") {
      await loadExtras()
    }
  }

  // MARK: - Header

  private var heroHeader: some View {
    let height: CGFloat = outerDisplay ? 132 : 220
    return ZStack(alignment: .bottomLeading) {
      Group {
        if let banner = artworkStore.displayImage(forKey: rom.artworkKey, preferred: .banner) {
          Image(uiImage: banner)
            .resizable()
            .scaledToFill()
        } else if let cover = artworkStore.image(forKey: rom.artworkKey, kind: .cover) {
          Image(uiImage: cover)
            .resizable()
            .scaledToFill()
        } else {
          LinearGradient(
            colors: [CETheme.card, CETheme.hover],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }
      }
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .clipped()

      LinearGradient(
        colors: [.clear, .black.opacity(0.75)],
        startPoint: .center,
        endPoint: .bottom
      )

      HStack(alignment: .bottom, spacing: outerDisplay ? 10 : 14) {
        coverThumb
        VStack(alignment: .leading, spacing: 6) {
          if let logo = artworkStore.image(forKey: rom.artworkKey, kind: .logo) {
            Image(uiImage: logo)
              .resizable()
              .scaledToFit()
              .frame(
                maxWidth: outerDisplay ? 140 : 200,
                maxHeight: outerDisplay ? 40 : 56,
                alignment: .leading
              )
          } else {
            Text(rom.displayName)
              .font(CETheme.sans(outerDisplay ? 17 : 22, weight: .bold))
              .foregroundStyle(CETheme.text)
              .lineLimit(2)
              .minimumScaleFactor(0.85)
          }
          HStack(spacing: 8) {
            if let console = rom.console {
              Text(console.shortTitle)
                .font(CETheme.mono(10))
                .foregroundStyle(CETheme.crystal)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CETheme.crystal.opacity(0.15), in: Capsule())
            }
            OptimizedStatusBadge(
              optimized: OptimizedRomCatalog.isOptimized(
                fileName: rom.url.lastPathComponent,
                displayName: rom.displayName
              )
            )
            if engine.isPausedRom(rom) {
              Text("PAUSED")
                .font(CETheme.mono(10))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(CETheme.crystal, in: Capsule())
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // Trailing icon eats the narrow outer column — only show on open / phone.
        if !outerDisplay, let icon = artworkStore.image(forKey: rom.artworkKey, kind: .icon) {
          Image(uiImage: icon)
            .resizable()
            .scaledToFill()
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CETheme.border, lineWidth: 1)
            )
        }
      }
      .padding(outerDisplay ? 12 : 16)
    }
  }

  private var coverThumb: some View {
    let w: CGFloat = outerDisplay ? 64 : 86
    let h: CGFloat = outerDisplay ? 96 : 129
    return Group {
      if let cover = artworkStore.image(forKey: rom.artworkKey, kind: .cover) {
        Image(uiImage: cover).resizable().scaledToFill()
      } else {
        RoundedRectangle(cornerRadius: 10).fill(CETheme.card)
      }
    }
    .frame(width: w, height: h)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CETheme.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.4), radius: 8, y: 2)
  }

  // MARK: - Actions

  private var actionRow: some View {
    // Same Play + Edit labels on outer and open — safe-area layout already keeps
    // both on the front face; icon-only Edit was stretching into a tall pill when open.
    HStack(alignment: .center, spacing: outerDisplay ? 8 : 10) {
      Button {
        InputHaptics.selectionChange()
        onPlay(rom)
      } label: {
        Label(engine.isPausedRom(rom) ? "Resume" : "Play", systemImage: "play.fill")
          .font(CETheme.sans(outerDisplay ? 15 : 16, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .frame(maxWidth: .infinity)
          .padding(.vertical, outerDisplay ? 10 : 12)
      }
      .buttonStyle(.borderedProminent)
      .tint(CETheme.crystal)

      Button {
        artworkTarget = ArtworkTarget(rom: rom, kind: .cover)
      } label: {
        Label("Edit", systemImage: "pencil")
          .font(CETheme.sans(outerDisplay ? 15 : 16, weight: .semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.85)
          .frame(maxWidth: .infinity)
          .padding(.vertical, outerDisplay ? 10 : 12)
      }
      .buttonStyle(.bordered)
      .tint(CETheme.text)
    }
  }

  // MARK: - Summary / Screenshots / RA

  private var summarySection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("ABOUT")
          .font(CETheme.sans(11, weight: .bold))
          .tracking(0.8)
          .foregroundStyle(CETheme.muted)
        Spacer(minLength: 0)
        if summaryBusy {
          ProgressView().scaleEffect(0.75)
        }
      }
      if !summaryTitle.isEmpty, summaryTitle != rom.displayName {
        Text(summaryTitle)
          .font(CETheme.sans(outerDisplay ? 15 : 16, weight: .semibold))
          .foregroundStyle(CETheme.text)
          .fixedSize(horizontal: false, vertical: true)
      }
      if summaryBody.isEmpty {
        Text(summaryBusy
             ? "Looking up what this game is about…"
             : "No summary found for this title yet.")
          .font(CETheme.sans(14))
          .foregroundStyle(CETheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text(summaryBody)
          .font(CETheme.sans(outerDisplay ? 13 : 14))
          .foregroundStyle(CETheme.text)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let summarySource {
        Link("Read more on Wikipedia", destination: summarySource)
          .font(CETheme.sans(12, weight: .semibold))
          .foregroundStyle(CETheme.crystal)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var screenshotsSection: some View {
    let snapH: CGFloat = outerDisplay ? 108 : 140
    return VStack(alignment: .leading, spacing: 10) {
      Text("SCREENSHOTS")
        .font(CETheme.sans(11, weight: .bold))
        .tracking(0.8)
        .foregroundStyle(CETheme.muted)
        .padding(.horizontal, outerDisplay ? 12 : 16)
      if screenshots.isEmpty {
        Text(screenshotsStatus.isEmpty ? "No in-game screenshots found for this ROM." : screenshotsStatus)
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, outerDisplay ? 12 : 16)
      } else {
        // Nested horizontal scroll: fixed height + indicators so it can scroll
        // on Duo outer without the parent vertical ScrollView eating the drag.
        ScrollView(.horizontal, showsIndicators: true) {
          HStack(spacing: 10) {
            ForEach(Array(screenshots.enumerated()), id: \.offset) { idx, img in
              Button {
                InputHaptics.selectionChange()
                screenshotViewer = ScreenshotViewerSelection(id: idx)
              } label: {
                Image(uiImage: img)
                  .resizable()
                  .interpolation(.none)
                  .scaledToFit()
                  .frame(height: snapH)
                  .frame(minWidth: snapH)
                  .background(Color.black.opacity(0.35))
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                      .stroke(CETheme.border, lineWidth: 1)
                  )
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Screenshot \(idx + 1)")
            }
          }
          .padding(.horizontal, outerDisplay ? 12 : 16)
          .padding(.bottom, 4)
        }
        .frame(height: snapH + 12)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
      }
    }
  }

  private var achievementsSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("ACHIEVEMENTS")
          .font(CETheme.sans(11, weight: .bold))
          .tracking(0.8)
          .foregroundStyle(CETheme.muted)
        Spacer(minLength: 0)
        if raBusy {
          ProgressView().scaleEffect(0.8)
        }
      }
      if let progress = raProgress {
        Text("\(progress.numAwarded)/\(progress.numAchievements) · \(progress.userScore)/\(progress.totalPossible) pts")
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.crystal)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(progress.achievements.prefix(40)) { ach in
          HStack(alignment: .top, spacing: outerDisplay ? 8 : 10) {
            achievementBadge(ach)
            VStack(alignment: .leading, spacing: 2) {
              Text(ach.title)
                .font(CETheme.sans(outerDisplay ? 13 : 14, weight: .semibold))
                .foregroundStyle(ach.isEarned ? CETheme.text : CETheme.muted)
                .fixedSize(horizontal: false, vertical: true)
              Text(ach.description)
                .font(CETheme.sans(outerDisplay ? 11 : 12))
                .foregroundStyle(CETheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(ach.points)")
              .font(CETheme.mono(outerDisplay ? 11 : 12))
              .foregroundStyle(CETheme.crystal)
              .fixedSize()
          }
          .padding(outerDisplay ? 8 : 10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(CETheme.border, lineWidth: 1))
          .opacity(ach.isEarned ? 1 : 0.72)
        }
        if progress.achievements.count > 40 {
          Text("Showing first 40 of \(progress.achievements.count)")
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
        }
      } else {
        Text(raStatus.isEmpty
             ? "Sign in under Settings › Achievements to track RetroAchievements for this ROM."
             : raStatus)
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func achievementBadge(_ ach: RetroAchievementsClient.Achievement) -> some View {
    let side: CGFloat = outerDisplay ? 34 : 40
    if let urlStr = ach.badgeUrl, let url = URL(string: urlStr) {
      AsyncImage(url: url) { phase in
        switch phase {
        case .success(let img):
          img.resizable().scaledToFill()
        default:
          Color.gray.opacity(0.25)
        }
      }
      .frame(width: side, height: side)
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .grayscale(ach.isEarned ? 0 : 1)
    } else {
      RoundedRectangle(cornerRadius: 8)
        .fill(CETheme.hover)
        .frame(width: side, height: side)
    }
  }

  // MARK: - Load

  private func loadExtras() async {
    await loadSummary()
    await loadScreenshots()
    await loadAchievements()
  }

  private func loadSummary() async {
    summarySource = nil
    var meta = artworkStore.meta(forKey: rom.artworkKey) ?? RomArtworkMeta()
    let cachedTitle = meta.summaryTitle ?? ""
    let cachedOK = !cachedTitle.isEmpty
      && GameSummaryClient.cachedTitleLooksValid(cachedTitle, forDisplayName: rom.displayName)
    if let cached = meta.summary, !cached.isEmpty, cachedOK {
      summaryTitle = cachedTitle
      summaryBody = cached
      return
    }
    // Drop a bad Wikipedia hit (e.g. R.O.W.E. → Pokémon Pokopia) before refetching.
    if !cachedOK, meta.summary != nil || meta.summaryTitle != nil {
      meta.summary = nil
      meta.summaryTitle = nil
      artworkStore.saveMeta(meta, forKey: rom.artworkKey)
    }

    summaryBusy = true
    defer { summaryBusy = false }
    summaryTitle = ""
    summaryBody = ""

    if let found = await GameSummaryClient.shared.summary(
      forDisplayName: rom.displayName,
      console: rom.console
    ) {
      summaryTitle = found.title
      summaryBody = found.extract
      summarySource = found.sourceURL
      var m = artworkStore.meta(forKey: rom.artworkKey) ?? RomArtworkMeta()
      m.summary = found.extract
      m.summaryTitle = found.title
      artworkStore.saveMeta(m, forKey: rom.artworkKey)
    }
  }

  private func loadScreenshots() async {
    screenshots = []
    screenshotsStatus = ""
    guard let console = rom.console else {
      screenshotsStatus = "Screenshots need a known console (GB / GBC / GBA / DS)."
      return
    }
    let result = await GameScreenshotClient.shared.fetch(
      romURL: rom.url,
      artworkKey: rom.artworkKey,
      romName: rom.name,
      displayName: rom.displayName,
      console: console,
      limit: 6
    )
    screenshots = result.images.compactMap { UIImage(data: $0) }
    screenshotsStatus = result.status
  }

  private func loadAchievements() async {
    raProgress = nil
    raBusy = true
    defer { raBusy = false }
    let signedIn = await RetroAchievementsClient.shared.isSignedIn()
    guard signedIn else {
      raStatus = "Sign in under Settings › Achievements to track RetroAchievements for this ROM."
      return
    }
    do {
      raProgress = try await RetroAchievementsClient.shared.progress(forRomAt: rom.url)
      raStatus = ""
    } catch RetroAchievementsClient.RAError.noGame {
      raStatus = "No RetroAchievements set matches this ROM file."
    } catch {
      raStatus = error.localizedDescription
    }
  }
}

private struct ScreenshotViewerSelection: Identifiable {
  let id: Int
}

/// Full-screen swipeable screenshot viewer (pixel art, no wallpaper stretch).
private struct ScreenshotViewer: View {
  let images: [UIImage]
  let startIndex: Int
  let onClose: () -> Void

  @State private var index: Int = 0

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      TabView(selection: $index) {
        ForEach(Array(images.enumerated()), id: \.offset) { i, img in
          Image(uiImage: img)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .padding(12)
            .tag(i)
            .onTapGesture(perform: onClose)
        }
      }
      .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .always : .never))

      VStack {
        HStack {
          Text("\(index + 1) / \(max(images.count, 1))")
            .font(CETheme.mono(12))
            .foregroundStyle(.white.opacity(0.85))
          Spacer()
          Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: 28))
              .symbolRenderingMode(.hierarchical)
              .foregroundStyle(.white)
          }
          .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        Spacer()
      }
    }
    .statusBarHidden(true)
    .onAppear {
      index = min(max(0, startIndex), max(images.count - 1, 0))
    }
  }
}
