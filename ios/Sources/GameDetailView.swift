import SwiftUI

/// Per-game hub — Apple TV show page / Music album layout: hero, action pills, rich sections.
struct GameDetailView: View {
  @EnvironmentObject private var engine: EmulatorEngine
  @Environment(\.dismiss) private var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @ObservedObject private var artworkStore = RomArtworkStore.shared
  @ObservedObject private var recentlyPlayed = RecentlyPlayedStore.shared
  let rom: RomItem
  let onPlay: (RomItem) -> Void
  var onEditSave: ((RomItem) -> Void)? = nil

  @State private var artworkTarget: ArtworkTarget?
  @State private var screenshots: [UIImage] = []
  @State private var screenshotsStatus = ""
  @State private var screenshotViewer: ScreenshotViewerSelection?
  @State private var summaryTitle = ""
  @State private var summaryBody = ""
  @State private var summaryBusy = false
  @State private var summarySource: URL?
  @State private var aboutExpanded = false
  @State private var raProgress: RetroAchievementsClient.GameProgress?
  @State private var raStatus = ""
  @State private var raBusy = false
  @State private var hingeClosed = false
  @State private var saveMissingAlert = false
  /// Visible column size — updated from the scroll viewport (not a sticky portrait width).
  @State private var pageSize: CGSize = .zero
  /// Bumped on hinge / orientation changes to rebuild hero + pills for the new bounds.
  @State private var layoutEpoch: Int = 0

  /// Duo closed outer / front face. Hinge is the source of truth — never clear from size class
  /// (cover landscape often reports `.regular` and used to drop outer layout → side bezels).
  private var outerDisplay: Bool { hingeClosed }

  /// Cover display turned sideways: wide + short. Use full width, short hero, row pills.
  private var outerLandscape: Bool {
    guard hingeClosed else { return false }
    if verticalSizeClass == .compact { return true }
    let s = pageSize
    return s.width > 1 && s.height > 1 && s.width > s.height * 1.05
  }

  /// Stacked / compact chrome: phone portrait, or cover portrait. Not cover landscape.
  private var narrowChrome: Bool {
    if hingeClosed { return !outerLandscape }
    return horizontalSizeClass == .compact
  }

  private var pagePad: CGFloat {
    if outerLandscape { return 10 }
    return narrowChrome ? 12 : 16
  }

  private var hasSave: Bool {
    FileManager.default.fileExists(atPath: RomLibrary.savePath(forRom: rom.url).path)
  }

  private var optimizedEntry: OptimizedRomEntry? {
    OptimizedRomCatalog.entry(
      fileName: rom.url.lastPathComponent,
      displayName: rom.displayName
    )
  }

  private var fileSizeLabel: String {
    ByteCountFormatter.string(fromByteCount: rom.byteCount, countStyle: .file)
  }

  private var lastPlayedLabel: String? {
    guard let date = recentlyPlayed.lastPlayed(for: rom) else { return nil }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        heroHeader
        actionPills
          .padding(.horizontal, pagePad)
          .padding(.top, narrowChrome ? 12 : 16)
        metadataChips
          .padding(.horizontal, pagePad)
          .padding(.top, 12)
        summarySection
          .padding(.horizontal, pagePad)
          .padding(.top, narrowChrome ? 18 : 24)
        if let entry = optimizedEntry {
          optimizedSection(entry)
            .padding(.horizontal, pagePad)
            .padding(.top, narrowChrome ? 16 : 22)
        }
        saveCard
          .padding(.horizontal, pagePad)
          .padding(.top, narrowChrome ? 16 : 22)
        screenshotsSection
          .padding(.top, narrowChrome ? 16 : 22)
        achievementsSection
          .padding(.horizontal, pagePad)
          .padding(.top, narrowChrome ? 16 : 22)
          .padding(.bottom, 44)
      }
      // Always span the full scroll viewport — never pin a stale portrait width
      // (that left huge left/right bezels after rotating the cover display).
      .frame(maxWidth: .infinity, alignment: .leading)
      .clipped()
      .id(layoutEpoch)
    }
    .background {
      GeometryReader { geo in
        Color.clear
          .onAppear { pageSize = geo.size }
          .onChange(of: geo.size) { _, size in
            let dw = abs(size.width - pageSize.width)
            let dh = abs(size.height - pageSize.height)
            if dw > 12 || dh > 12 {
              pageSize = size
              layoutEpoch &+= 1
            }
          }
      }
    }
    .background(GlassChrome.canvas.ignoresSafeArea())
    // Custom chrome — system ToolbarItem wraps images in a Liquid Glass circle.
    // Prefer toolbar visibility so pushed destinations (Save Editor) can show the bar again.
    .toolbar(.hidden, for: .navigationBar)
    .navigationSwipeBackEnabled()
    .safeAreaInset(edge: .top, spacing: 0) {
      gamePageChrome
    }
    .accessibilityLabel(rom.displayName)
    .modifier(DuoHingeClosedObserver { closed in
      if hingeClosed != closed {
        hingeClosed = closed
        layoutEpoch &+= 1
      }
    })
    .onChange(of: horizontalSizeClass) { _, _ in
      layoutEpoch &+= 1
    }
    .onChange(of: verticalSizeClass) { _, _ in
      layoutEpoch &+= 1
    }
    .sheet(item: $artworkTarget) { target in
      ArtworkPickerSheet(rom: target.rom, initialKind: target.kind)
    }
    .fullScreenCover(item: $screenshotViewer) { sel in
      ScreenshotViewer(images: screenshots, startIndex: sel.id) {
        screenshotViewer = nil
      }
    }
    .alert("No save yet", isPresented: $saveMissingAlert) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Play once in-game so PocketDex writes a battery .sav, then Edit Save opens the editor for this ROM.")
    }
    .task(id: "\(rom.artworkKey)-\(artworkStore.revision)") {
      await loadExtras()
    }
  }

  /// Plain top chrome: back + large logo on the left (no toolbar glass bubble).
  private var gamePageChrome: some View {
    HStack(alignment: .center, spacing: 10) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(CETheme.accent)
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Back")

      gamePageTitleMark
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, pagePad)
    .padding(.top, outerLandscape ? 6 : 8)
    .padding(.bottom, outerLandscape ? 8 : 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.bg.opacity(0.92))
  }

  /// Official game logo when scraped, otherwise the ROM display name — left-aligned, large.
  @ViewBuilder
  private var gamePageTitleMark: some View {
    if let logo = artworkStore.image(forKey: rom.artworkKey, kind: .logo) {
      Image(uiImage: logo)
        .resizable()
        .interpolation(.high)
        .antialiased(true)
        .scaledToFit()
        .frame(
          maxWidth: outerLandscape ? 380 : (narrowChrome ? 300 : 420),
          maxHeight: outerLandscape ? 64 : (narrowChrome ? 72 : 88),
          alignment: .leading
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(rom.displayName)
    } else {
      Text(rom.displayName)
        .font(CETheme.sans(narrowChrome ? 17 : 20, weight: .semibold))
        .foregroundStyle(CETheme.text)
        .lineLimit(2)
        .minimumScaleFactor(0.7)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Hero

  private var heroHeader: some View {
    let height: CGFloat = {
      if outerLandscape { return 112 }
      if narrowChrome { return 168 }
      return 260
    }()
    return ZStack(alignment: .bottom) {
      // Fixed frame + overlay so scaledToFill cannot widen the scroll content.
      Color.clear
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay {
          Group {
            if let banner = artworkStore.displayImage(forKey: rom.artworkKey, preferred: .banner) {
              Image(uiImage: banner)
                .resizable()
                .scaledToFill()
            } else if let cover = artworkStore.image(forKey: rom.artworkKey, kind: .cover) {
              Image(uiImage: cover)
                .resizable()
                .scaledToFill()
                .blur(radius: 18)
                .scaleEffect(1.08)
            } else {
              LinearGradient(
                colors: [CETheme.card, CETheme.hover],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
              )
            }
          }
        }
        .clipped()

      LinearGradient(
        colors: [
          .clear,
          CETheme.bg.opacity(0.35),
          CETheme.bg.opacity(0.92),
          CETheme.bg,
        ],
        startPoint: .top,
        endPoint: .bottom
      )

      HStack(alignment: .bottom, spacing: narrowChrome ? 10 : 14) {
        coverThumb
          .layoutPriority(1)

        VStack(alignment: .leading, spacing: 6) {
          // When a logo is in the nav bar, skip repeating the title here.
          if !artworkStore.hasArtwork(forKey: rom.artworkKey, kind: .logo) {
            Text(rom.displayName)
              .font(CETheme.sans(narrowChrome ? 18 : 26, weight: .bold))
              .foregroundStyle(CETheme.text)
              .lineLimit(4)
              .minimumScaleFactor(0.72)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
          }

          if let console = rom.console {
            Text(console.title)
              .font(CETheme.sans(narrowChrome ? 11 : 13, weight: .medium))
              .foregroundStyle(CETheme.muted)
              .lineLimit(2)
              .minimumScaleFactor(0.85)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(0)
      }
      .padding(.horizontal, pagePad)
      .padding(.bottom, narrowChrome ? 12 : 16)
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
    .clipped()
  }

  private var coverThumb: some View {
    let w: CGFloat = {
      if outerLandscape { return 56 }
      if narrowChrome { return 72 }
      return 104
    }()
    let h: CGFloat = {
      if outerLandscape { return 84 }
      if narrowChrome { return 108 }
      return 156
    }()
    return Group {
      if let cover = artworkStore.image(forKey: rom.artworkKey, kind: .cover) {
        Image(uiImage: cover).resizable().scaledToFill()
      } else {
        RoundedRectangle(cornerRadius: 14).fill(CETheme.card)
      }
    }
    .frame(width: w, height: h)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(CETheme.border, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
  }

  // MARK: - Actions

  @ViewBuilder
  private var actionPills: some View {
    let playTitle = engine.isPausedRom(rom) ? "Resume" : "Play"
    // Cover portrait / phone portrait: stack. Cover landscape + open/wide: one row so
    // the short wide canvas isn’t wasted with tall stacked pills and empty side margins.
    if narrowChrome {
      VStack(spacing: 8) {
        MediaActionPill(
          title: playTitle,
          systemImage: "play.fill",
          prominent: true,
          compact: true
        ) { onPlay(rom) }
        HStack(spacing: 8) {
          MediaActionPill(
            title: "Save",
            systemImage: "externaldrive.fill.badge.pencil",
            compact: true
          ) { requestEditSave() }
          MediaActionPill(
            title: "Art",
            systemImage: "photo.on.rectangle",
            compact: true
          ) { artworkTarget = ArtworkTarget(rom: rom, kind: .cover) }
        }
      }
    } else {
      HStack(spacing: outerLandscape ? 8 : 10) {
        MediaActionPill(
          title: playTitle,
          systemImage: "play.fill",
          prominent: true,
          compact: outerLandscape
        ) { onPlay(rom) }
        MediaActionPill(
          title: outerLandscape ? "Save" : "Edit Save",
          systemImage: "externaldrive.fill.badge.pencil",
          compact: outerLandscape
        ) { requestEditSave() }
        MediaActionPill(
          title: outerLandscape ? "Art" : "Artwork",
          systemImage: "photo.on.rectangle",
          compact: outerLandscape
        ) { artworkTarget = ArtworkTarget(rom: rom, kind: .cover) }
      }
    }
  }

  private func requestEditSave() {
    guard hasSave else {
      saveMissingAlert = true
      return
    }
    onEditSave?(rom)
  }

  // MARK: - Chips

  private var metadataChips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        if let console = rom.console {
          metaChip(console.shortTitle, tint: CETheme.crystal)
        }
        OptimizedStatusBadge(
          optimized: optimizedEntry != nil,
          compact: true
        )
        if engine.isPausedRom(rom) {
          metaChip("Paused", tint: CETheme.crystal, filled: true)
        }
        metaChip(fileSizeLabel)
        if let last = lastPlayedLabel {
          metaChip("Played \(last)")
        }
        metaChip(hasSave ? "Save ready" : "No .sav yet", tint: hasSave ? CETheme.crystal : CETheme.muted)
      }
      .padding(.vertical, 2)
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
  }

  private func metaChip(_ text: String, tint: Color = CETheme.muted, filled: Bool = false) -> some View {
    Text(text)
      .font(CETheme.mono(10))
      .foregroundStyle(filled ? Color.black.opacity(0.88) : tint)
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(
        filled ? tint : tint.opacity(0.14),
        in: Capsule()
      )
      .overlay(
        Capsule().stroke(tint.opacity(filled ? 0 : 0.35), lineWidth: 1)
      )
  }

  // MARK: - Sections

  private var summarySection: some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionLabel("About")
      if !summaryTitle.isEmpty, summaryTitle != rom.displayName {
        Text(summaryTitle)
          .font(CETheme.sans(outerDisplay ? 15 : 17, weight: .semibold))
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
          .font(CETheme.sans(outerDisplay ? 13 : 15))
          .foregroundStyle(CETheme.text.opacity(0.92))
          .lineLimit(aboutExpanded ? nil : 5)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        if summaryBody.count > 220 {
          Button(aboutExpanded ? "Show Less" : "More") {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
              aboutExpanded.toggle()
            }
          }
          .font(CETheme.sans(13, weight: .semibold))
          .foregroundStyle(CETheme.crystal)
          .buttonStyle(MediaPressStyle())
        }
      }
      if let summarySource {
        Link("Read more on Wikipedia", destination: summarySource)
          .font(CETheme.sans(12, weight: .semibold))
          .foregroundStyle(CETheme.crystal)
      }
      if summaryBusy {
        ProgressView().scaleEffect(0.75)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func optimizedSection(_ entry: OptimizedRomEntry) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      sectionLabel("Optimized")
      Text(entry.detail)
        .font(CETheme.sans(13))
        .foregroundStyle(CETheme.muted)
        .fixedSize(horizontal: false, vertical: true)
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: outerDisplay ? 120 : 140), spacing: 8)],
        spacing: 8
      ) {
        ForEach(entry.features.labels, id: \.self) { label in
          HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(CETheme.crystal)
            Text(label)
              .font(CETheme.sans(12, weight: .semibold))
              .foregroundStyle(CETheme.text)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(CETheme.border, lineWidth: 1)
          )
        }
      }
    }
  }

  private var saveCard: some View {
    Button {
      requestEditSave()
    } label: {
      HStack(spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(CETheme.crystal.opacity(0.14))
          Image(systemName: "externaldrive.fill.badge.pencil")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(CETheme.crystal)
        }
        .frame(width: 48, height: 48)

        VStack(alignment: .leading, spacing: 3) {
          Text("Save Editor")
            .font(CETheme.sans(15, weight: .semibold))
            .foregroundStyle(CETheme.text)
          Text(hasSave
               ? "Edit party, bag, boxes, and money for this ROM."
               : "Play once to create a battery save, then edit it here.")
            .font(CETheme.sans(12))
            .foregroundStyle(CETheme.muted)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(CETheme.muted)
      }
      .padding(12)
      .background(CETheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .stroke(CETheme.crystal.opacity(hasSave ? 0.4 : 0.18), lineWidth: 1)
      )
    }
    .buttonStyle(MediaPressStyle())
  }

  private var screenshotsSection: some View {
    let snapH: CGFloat = outerDisplay ? 108 : 148
    return VStack(alignment: .leading, spacing: 10) {
      sectionLabel("Screenshots")
        .padding(.horizontal, pagePad)
      if screenshots.isEmpty {
        Text(screenshotsStatus.isEmpty ? "No in-game screenshots found for this ROM." : screenshotsStatus)
          .font(CETheme.sans(13))
          .foregroundStyle(CETheme.muted)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, pagePad)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 12) {
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
                  .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                  .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                      .stroke(CETheme.border, lineWidth: 1)
                  )
                  .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
              }
              .buttonStyle(MediaPressStyle())
              .accessibilityLabel("Screenshot \(idx + 1)")
            }
          }
          .padding(.horizontal, pagePad)
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
        sectionLabel("Achievements")
        Spacer(minLength: 0)
        if raBusy {
          ProgressView().scaleEffect(0.8)
        }
      }
      if let progress = raProgress {
        HStack(spacing: 10) {
          progressRing(
            awarded: progress.numAwarded,
            total: max(progress.numAchievements, 1)
          )
          VStack(alignment: .leading, spacing: 2) {
            Text("\(progress.numAwarded) of \(progress.numAchievements)")
              .font(CETheme.sans(15, weight: .semibold))
              .foregroundStyle(CETheme.text)
            Text("\(progress.userScore) / \(progress.totalPossible) pts")
              .font(CETheme.sans(12))
              .foregroundStyle(CETheme.crystal)
          }
          Spacer(minLength: 0)
        }
        .padding(12)
        .background(CETheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(CETheme.border, lineWidth: 1)
        )

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
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(CETheme.border, lineWidth: 1)
          )
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

  private func sectionLabel(_ title: String) -> some View {
    Text(title)
      .font(CETheme.sans(13, weight: .semibold))
      .foregroundStyle(CETheme.muted)
      .textCase(.uppercase)
      .tracking(0.8)
  }

  private func progressRing(awarded: Int, total: Int) -> some View {
    let fraction = min(1, CGFloat(awarded) / CGFloat(max(total, 1)))
    return ZStack {
      Circle()
        .stroke(CETheme.border, lineWidth: 4)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(CETheme.crystal, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .rotationEffect(.degrees(-90))
      Text("\(Int((fraction * 100).rounded()))%")
        .font(CETheme.mono(10))
        .foregroundStyle(CETheme.text)
    }
    .frame(width: 44, height: 44)
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
    // Curated fan-hack blurbs always win so About stays fresh when we expand them.
    if let curated = GameSummaryClient.curatedIfAny(forDisplayName: rom.displayName) {
      summaryTitle = curated.title
      summaryBody = curated.extract
      summarySource = curated.sourceURL
      var m = artworkStore.meta(forKey: rom.artworkKey) ?? RomArtworkMeta()
      m.summary = curated.extract
      m.summaryTitle = curated.title
      artworkStore.saveMeta(m, forKey: rom.artworkKey)
      return
    }

    var meta = artworkStore.meta(forKey: rom.artworkKey) ?? RomArtworkMeta()
    let cachedTitle = meta.summaryTitle ?? ""
    let cachedOK = !cachedTitle.isEmpty
      && GameSummaryClient.cachedTitleLooksValid(cachedTitle, forDisplayName: rom.displayName)
    if let cached = meta.summary, !cached.isEmpty, cachedOK {
      summaryTitle = cachedTitle
      summaryBody = cached
      return
    }
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
      limit: 8
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
