import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Manic EMU / Cocoon-style artwork picker: Photos, Files, Libretro (free), or SteamGridDB.
struct ArtworkPickerSheet: View {
  let rom: RomItem
  var initialKind: RomArtworkKind = .cover
  var onDone: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var store = RomArtworkStore.shared

  @State private var kind: RomArtworkKind = .cover
  @State private var alsoIcon = true
  @State private var photoItem: PhotosPickerItem?
  @State private var showFiles = false
  @State private var showSGDB = false
  @State private var errorText: String?
  @State private var busy = false
  @State private var busyLabel = "Saving…"
  @State private var editedName = ""

  var body: some View {
    NavigationStack {
      ZStack {
        CETheme.bg.ignoresSafeArea()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            header

            nameEditor

            previewRow

            kindPicker

            if kind == .cover {
              Toggle(isOn: $alsoIcon) {
                VStack(alignment: .leading, spacing: 2) {
                  Text("Also set as icon")
                    .font(CETheme.sans(14, weight: .semibold))
                    .foregroundStyle(CETheme.text)
                  Text("Use the same image for the small badge")
                    .font(CETheme.sans(12))
                    .foregroundStyle(CETheme.muted)
                }
              }
              .tint(CETheme.crystal)
              .padding(14)
              .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
              .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
            }

            sourceSection

            if store.hasArtwork(forKey: rom.artworkKey, kind: kind) {
              Button(role: .destructive) {
                store.clear(forKey: rom.artworkKey, kind: kind)
              } label: {
                Label("Clear \(kind.title)", systemImage: "trash")
                  .font(CETheme.sans(14, weight: .semibold))
                  .frame(maxWidth: .infinity)
                  .padding(14)
                  .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
                  .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
              }
              .foregroundStyle(Color(red: 0.85, green: 0.45, blue: 0.45))
            }
          }
          .padding(16)
        }

        if busy {
          Color.black.opacity(0.35).ignoresSafeArea()
          ProgressView(busyLabel)
            .tint(CETheme.accent)
            .padding(20)
            .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
        }
      }
      .navigationBarHidden(true)
      .safeAreaInset(edge: .top) { chrome }
      .onAppear {
        kind = initialKind
        editedName = store.displayName(forKey: rom.artworkKey) ?? rom.name
      }
      .onChange(of: photoItem) { _, item in
        guard let item else { return }
        Task { await importPhoto(item) }
      }
      .fileImporter(
        isPresented: $showFiles,
        allowedContentTypes: [.image, .jpeg, .png, .webP],
        allowsMultipleSelection: false
      ) { result in
        switch result {
        case .success(let urls):
          if let url = urls.first { Task { await importFile(url) } }
        case .failure(let err):
          errorText = err.localizedDescription
        }
      }
      .sheet(isPresented: $showSGDB) {
        SteamGridDBBrowserView(rom: rom, kind: kind, alsoIcon: alsoIcon) {
          showSGDB = false
        }
      }
      .alert("Artwork", isPresented: Binding(
        get: { errorText != nil },
        set: { if !$0 { errorText = nil } }
      )) {
        Button("OK", role: .cancel) { errorText = nil }
      } message: {
        Text(errorText ?? "")
      }
    }
  }

  private var chrome: some View {
    HStack {
      Button("Done") {
        commitDisplayName()
        onDone?()
        dismiss()
      }
      .font(CETheme.sans(15, weight: .semibold))
      .foregroundStyle(CETheme.accent)
      Spacer()
      Text("Edit Game")
        .font(CETheme.sans(17, weight: .bold))
        .foregroundStyle(CETheme.text)
      Spacer()
      Color.clear.frame(width: 48, height: 1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(CETheme.elevated)
    .overlay(alignment: .bottom) { Rectangle().fill(CETheme.border).frame(height: 1) }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(editedName.isEmpty ? rom.name : editedName)
        .font(CETheme.sans(18, weight: .bold))
        .foregroundStyle(CETheme.text)
        .lineLimit(2)
      Text(rom.console?.title ?? "ROM")
        .font(CETheme.sans(13))
        .foregroundStyle(CETheme.muted)
    }
  }

  private var nameEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Game name")
        .font(CETheme.sans(12, weight: .bold))
        .foregroundStyle(CETheme.muted)
      TextField("Name", text: $editedName)
        .font(CETheme.sans(16, weight: .semibold))
        .foregroundStyle(CETheme.text)
        .padding(12)
        .background(CETheme.hover, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(CETheme.border, lineWidth: 1)
        )
        .onChange(of: editedName) { _, newValue in
          applyEditedNameLocally(newValue)
        }
      if editedName.trimmingCharacters(in: .whitespacesAndNewlines) != rom.name {
        Button {
          editedName = rom.name
          store.setDisplayName(nil, forKey: rom.artworkKey)
        } label: {
          Text("Reset to filename")
            .font(CETheme.sans(12, weight: .semibold))
            .foregroundStyle(CETheme.crystal)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
  }

  private var previewRow: some View {
    HStack(spacing: 14) {
      artworkThumb(kind: kind, width: kind == .logo ? 240 : (kind == .banner ? 180 : 88))
      VStack(alignment: .leading, spacing: 6) {
        Text(kind.title)
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(CETheme.text)
        Text(kind.subtitle)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
      }
      Spacer()
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
  }

  private func artworkThumb(kind: RomArtworkKind, width: CGFloat) -> some View {
    let height = width / max(kind.aspectRatio, 0.01)
    return Group {
      if let img = store.displayImage(forKey: rom.artworkKey, preferred: kind) {
        Image(uiImage: img)
          .resizable()
          .scaledToFit()
          .padding(kind == .logo ? 10 : 0)
      } else {
        CETheme.hover
          .overlay(
            Image(systemName: kind.systemImage)
              .foregroundStyle(CETheme.muted)
          )
      }
    }
    .frame(width: width, height: kind == .logo ? max(min(height, 140), 100) : min(height, 120))
    .background(kind == .logo ? CETheme.hover : Color.clear)
    .clipped()
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(CETheme.border, lineWidth: 1)
    )
  }

  private var kindPicker: some View {
    HStack(spacing: 8) {
      ForEach(RomArtworkKind.allCases) { k in
        Button {
          kind = k
        } label: {
          Text(k.title)
            .font(CETheme.sans(13, weight: .semibold))
            .foregroundStyle(kind == k ? Color.black : CETheme.text)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(kind == k ? CETheme.crystal : CETheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(kind == k ? Color.clear : CETheme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var sourceSection: some View {
    VStack(spacing: 10) {
      Text("SOURCE")
        .font(CETheme.sans(11, weight: .semibold))
        .foregroundStyle(CETheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)

      PhotosPicker(selection: $photoItem, matching: .images) {
        sourceRow(title: "Photos", subtitle: "Pick from your library", systemImage: "photo.on.rectangle")
      }

      Button { showFiles = true } label: {
        sourceRow(title: "Files", subtitle: "Local or iCloud images", systemImage: "folder")
      }
      .buttonStyle(.plain)

      Button { Task { await fetchLibretro() } } label: {
        sourceRow(
          title: "Libretro (free)",
          subtitle: "Auto covers — no account (TrashMan → retail Emerald, …)",
          systemImage: "square.stack.3d.up"
        )
      }
      .buttonStyle(.plain)
      .disabled(busy)

      Button { showSGDB = true } label: {
        sourceRow(title: "SteamGridDB", subtitle: "Search community covers & banners (API key)", systemImage: "globe")
      }
      .buttonStyle(.plain)
    }
  }

  private func fetchLibretro() async {
    busyLabel = "Fetching covers…"
    busy = true
    defer { busy = false; busyLabel = "Saving…" }
    let ok = await LibretroArtworkApplier.applyIfNeeded(to: rom, force: true)
    if !ok {
      errorText = "No Libretro cover matched this ROM name."
    }
  }

  private func sourceRow(title: String, subtitle: String, systemImage: String) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(CETheme.accent)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(CETheme.text)
        Text(subtitle)
          .font(CETheme.sans(12))
          .foregroundStyle(CETheme.muted)
      }
      Spacer()
      Image(systemName: "chevron.right")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(CETheme.muted.opacity(0.7))
    }
    .padding(14)
    .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
    .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
  }

  private func applyEditedNameLocally(_ newValue: String) {
    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == rom.name {
      store.setDisplayName(nil, forKey: rom.artworkKey)
    } else {
      store.setDisplayName(trimmed, forKey: rom.artworkKey)
    }
  }

  /// Persist the library title and push `meta.json` to Google Drive so sync keeps the rename.
  private func commitDisplayName() {
    applyEditedNameLocally(editedName)
    let key = rom.artworkKey
    Task { await GoogleDriveSync.shared.pushArtworkMeta(forKey: key) }
  }

  private func importPhoto(_ item: PhotosPickerItem) async {
    busy = true
    defer { busy = false; photoItem = nil }
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else {
        errorText = "Could not read photo."
        return
      }
      try await apply(data: data)
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func importFile(_ url: URL) async {
    busy = true
    defer { busy = false }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: url)
      try await apply(data: data)
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func apply(data: Data) async throws {
    try store.save(imageData: data, forKey: rom.artworkKey, kind: kind)
    if kind == .cover && alsoIcon {
      try store.save(imageData: data, forKey: rom.artworkKey, kind: .icon)
    }
  }
}

// MARK: - SteamGridDB browser

struct SteamGridDBBrowserView: View {
  let rom: RomItem
  let kind: RomArtworkKind
  let alsoIcon: Bool
  var onDone: (() -> Void)? = nil

  @Environment(\.dismiss) private var dismiss
  @ObservedObject private var store = RomArtworkStore.shared

  @State private var query: String = ""
  @State private var games: [SteamGridDBClient.GameHit] = []
  @State private var images: [SteamGridDBClient.ImageHit] = []
  @State private var selectedGame: SteamGridDBClient.GameHit?
  @State private var busy = false
  @State private var errorText: String?
  @State private var hasKey = false
  @State private var status = ""
  @State private var showKeySettings = false

  var body: some View {
    NavigationStack {
      ZStack {
        CETheme.bg.ignoresSafeArea()
        VStack(spacing: 0) {
          if !hasKey {
            missingKey
          } else if selectedGame == nil {
            searchPane
          } else {
            resultsPane
          }
        }
        if busy {
          Color.black.opacity(0.35).ignoresSafeArea()
          ProgressView(status.isEmpty ? "Loading…" : status)
            .tint(CETheme.accent)
            .padding(20)
            .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
        }
      }
      .navigationBarHidden(true)
      .safeAreaInset(edge: .top) { chrome }
      .task {
        hasKey = await SteamGridDBClient.shared.hasAPIKey()
        query = rom.name
        if hasKey { await runSearch() }
      }
      .sheet(isPresented: $showKeySettings, onDismiss: {
        Task {
          hasKey = await SteamGridDBClient.shared.hasAPIKey()
          if hasKey { await runSearch() }
        }
      }) {
        ArtworkSettingsGate()
          .environmentObject(AppSettings.shared)
      }
      .alert("SteamGridDB", isPresented: Binding(
        get: { errorText != nil },
        set: { if !$0 { errorText = nil } }
      )) {
        Button("OK", role: .cancel) { errorText = nil }
      } message: {
        Text(errorText ?? "")
      }
    }
  }

  private var chrome: some View {
    HStack {
      Button(selectedGame == nil ? "Close" : "Back") {
        if selectedGame != nil {
          selectedGame = nil
          images = []
        } else {
          onDone?()
          dismiss()
        }
      }
      .font(CETheme.sans(15, weight: .semibold))
      .foregroundStyle(CETheme.accent)
      Spacer()
      Text(selectedGame?.name ?? "SteamGridDB")
        .font(CETheme.sans(16, weight: .bold))
        .foregroundStyle(CETheme.text)
        .lineLimit(1)
      Spacer()
      Color.clear.frame(width: 52, height: 1)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(CETheme.elevated)
    .overlay(alignment: .bottom) { Rectangle().fill(CETheme.border).frame(height: 1) }
  }

  private var missingKey: some View {
    VStack(spacing: 16) {
      Spacer()
      Image(systemName: "key.fill")
        .font(.system(size: 36))
        .foregroundStyle(CETheme.muted)
      Text("Connect SteamGridDB to search covers and banners.")
        .font(CETheme.sans(14))
        .foregroundStyle(CETheme.muted)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32)
      Button {
        showKeySettings = true
      } label: {
        Text("Add API Key")
          .font(CETheme.sans(15, weight: .semibold))
          .foregroundStyle(Color.black)
          .padding(.horizontal, 22)
          .padding(.vertical, 12)
          .background(CETheme.crystal, in: Capsule())
      }
      Link("Get a free API key on SteamGridDB", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
        .font(CETheme.sans(13, weight: .semibold))
        .foregroundStyle(CETheme.crystal)
      Spacer()
    }
  }

  private var searchPane: some View {
    VStack(spacing: 12) {
      HStack {
        TextField("Search games…", text: $query)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .font(CETheme.sans(15))
          .foregroundStyle(CETheme.text)
          .padding(12)
          .background(CETheme.card, in: RoundedRectangle(cornerRadius: 10))
          .overlay(RoundedRectangle(cornerRadius: 10).stroke(CETheme.border, lineWidth: 1))
        Button("Search") { Task { await runSearch() } }
          .font(CETheme.sans(14, weight: .semibold))
          .foregroundStyle(CETheme.accent)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)

      ScrollView {
        LazyVStack(spacing: 8) {
          ForEach(games) { game in
            Button {
              Task { await loadImages(for: game) }
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(game.name)
                    .font(CETheme.sans(15, weight: .semibold))
                    .foregroundStyle(CETheme.text)
                    .multilineTextAlignment(.leading)
                  if game.verified == true {
                    Text("Verified")
                      .font(CETheme.sans(11))
                      .foregroundStyle(CETheme.muted)
                  }
                }
                Spacer()
                Image(systemName: "chevron.right")
                  .foregroundStyle(CETheme.muted)
              }
              .padding(14)
              .background(CETheme.card, in: RoundedRectangle(cornerRadius: CETheme.radius))
              .overlay(RoundedRectangle(cornerRadius: CETheme.radius).stroke(CETheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(16)
      }
    }
  }

  private var resultsPane: some View {
    ScrollView {
      if images.isEmpty && !busy {
        Text("No \(kind.title.lowercased()) art found for this title.")
          .font(CETheme.sans(14))
          .foregroundStyle(CETheme.muted)
          .frame(maxWidth: .infinity)
          .padding(40)
      } else {
        LazyVGrid(
          columns: [
            GridItem(
              .adaptive(minimum: kind == .logo ? 220 : (kind == .banner ? 160 : 100)),
              spacing: 12
            )
          ],
          spacing: 12
        ) {
          ForEach(images) { img in
            Button {
              Task { await apply(img) }
            } label: {
              AsyncArtworkThumb(
                // Logos: use full asset so the grid isn’t stuck on a tiny thumb.
                urlString: kind == .logo ? img.url : (img.thumb ?? img.url),
                aspect: kind.aspectRatio,
                fit: kind == .logo
              )
            }
            .buttonStyle(.plain)
          }
        }
        .padding(16)
      }
    }
  }

  private func runSearch() async {
    busy = true
    status = "Searching…"
    defer { busy = false; status = "" }
    do {
      games = try await SteamGridDBClient.shared.search(term: query)
      if games.isEmpty { errorText = "No games matched “\(query)”." }
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func loadImages(for game: SteamGridDBClient.GameHit) async {
    busy = true
    status = "Loading art…"
    defer { busy = false; status = "" }
    do {
      selectedGame = game
      let client = SteamGridDBClient.shared
      switch kind {
      case .cover: images = try await client.grids(gameId: game.id)
      case .banner: images = try await client.heroes(gameId: game.id)
      case .icon: images = try await client.icons(gameId: game.id)
      case .logo: images = try await client.logos(gameId: game.id)
      }
      // Fallback: if heroes empty, try grids for banner slot.
      if images.isEmpty, kind == .banner {
        images = try await client.grids(gameId: game.id)
      }
    } catch {
      errorText = error.localizedDescription
      selectedGame = nil
    }
  }

  private func apply(_ img: SteamGridDBClient.ImageHit) async {
    busy = true
    status = "Downloading…"
    defer { busy = false; status = "" }
    do {
      let data = try await SteamGridDBClient.shared.downloadImage(urlString: img.url)
      try store.save(imageData: data, forKey: rom.artworkKey, kind: kind)
      if kind == .cover && alsoIcon {
        try store.save(imageData: data, forKey: rom.artworkKey, kind: .icon)
      }
      if let game = selectedGame {
        var m = store.meta(forKey: rom.artworkKey) ?? RomArtworkMeta()
        m.steamGridGameId = game.id
        m.steamGridGameName = game.name
        store.saveMeta(m, forKey: rom.artworkKey)
      }
      onDone?()
      dismiss()
    } catch {
      errorText = error.localizedDescription
    }
  }
}

/// SteamGridDB API-key settings sheet.
private struct ArtworkSettingsGate: View {
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    SettingsCategoryDetail(category: .artwork, onBack: { dismiss() })
  }
}

private struct AsyncArtworkThumb: View {
  let urlString: String
  let aspect: CGFloat
  /// Logos keep transparency and must not be crop-zoomed.
  var fit: Bool = false
  @State private var image: UIImage?

  var body: some View {
    Color.clear
      .aspectRatio(aspect, contentMode: .fit)
      .background(fit ? CETheme.hover : Color.clear)
      .overlay {
        if let image {
          if fit {
            Image(uiImage: image)
              .resizable()
              .scaledToFit()
              .padding(14)
          } else {
            Image(uiImage: image)
              .resizable()
              .scaledToFill()
          }
        } else {
          CETheme.hover
            .overlay(ProgressView().tint(CETheme.muted))
        }
      }
      .clipped()
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(CETheme.border, lineWidth: 1)
      )
      .task {
        guard let url = URL(string: urlString) else { return }
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let ui = UIImage(data: data) {
          image = ui
        }
      }
  }
}
