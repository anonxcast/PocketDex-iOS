import Foundation

extension Notification.Name {
  /// Posted after Drive sync writes/downloads files so the library UI rescans.
  static let pocketDexLibraryNeedsReload = Notification.Name("pocketDexLibraryNeedsReload")
}

/// Two-way sync of ROMs / Saves / States / scraped Artwork / Companion into Drive `PocketDex/`.
@MainActor
final class GoogleDriveSync: ObservableObject {
  static let shared = GoogleDriveSync()

  @Published private(set) var isSyncing = false
  @Published var lastResult: String?

  private let auth = GoogleDriveAuth.shared
  private let apiRoot = URL(string: "https://www.googleapis.com/drive/v3")!
  private let uploadRoot = URL(string: "https://www.googleapis.com/upload/drive/v3")!

  private init() {}

  /// Upload (and merge) `Artwork/<key>/meta.json` so a library rename sticks on Drive.
  func pushArtworkMeta(forKey key: String) async {
    guard auth.isSignedIn else { return }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let localURL = RomArtworkStore.shared.metaFileURL(forKey: trimmed)
    guard FileManager.default.fileExists(atPath: localURL.path) else { return }
    do {
      let token = try await auth.accessToken()
      let root = try await ensureFolder(named: "PocketDex", parentID: "root", token: token)
      let artRoot = try await ensureFolder(named: "Artwork", parentID: root, token: token)
      let folderID = try await ensureFolder(named: trimmed, parentID: artRoot, token: token)
      let remote = try await listChildren(folderID: folderID, token: token)
      let existing = remote.first {
        $0.name == "meta.json" && $0.mimeType != "application/vnd.google-apps.folder"
      }
      var counts = Counts()
      if let existing {
        try await mergeAndSyncMeta(
          localURL: localURL,
          remoteFile: existing,
          folderID: folderID,
          token: token,
          counts: &counts
        )
      } else {
        try await upload(fileURL: localURL, name: "meta.json", folderID: folderID, existingID: nil, token: token)
      }
    } catch {
      // Next full sync retries; rename is already on disk.
    }
  }

  func syncNow() async {
    guard !isSyncing else { return }
    guard auth.isSignedIn else {
      lastResult = "Sign in to Google Drive first."
      return
    }
    isSyncing = true
    defer { isSyncing = false }
    do {
      let token = try await auth.accessToken()
      let root = try await ensureFolder(named: "PocketDex", parentID: "root", token: token)
      let romsFolder = try await ensureFolder(named: "ROMs", parentID: root, token: token)
      let savesFolder = try await ensureFolder(named: "Saves", parentID: root, token: token)
      let statesFolder = try await ensureFolder(named: "States", parentID: root, token: token)
      let artworkFolder = try await ensureFolder(named: "Artwork", parentID: root, token: token)
      let companionFolder = try await ensureFolder(named: "Companion", parentID: root, token: token)

      var uploaded = 0
      var downloaded = 0

      let upR = try await syncDirectory(
        local: RomLibrary.romsDirectory,
        folderID: romsFolder,
        token: token,
        extensions: ["gba", "gbc", "gb", "nds"]
      )
      uploaded += upR.uploaded
      downloaded += upR.downloaded

      let upS = try await syncDirectory(
        local: RomLibrary.savesDirectory,
        folderID: savesFolder,
        token: token,
        extensions: ["sav"]
      )
      uploaded += upS.uploaded
      downloaded += upS.downloaded

      let upT = try await syncDirectory(
        local: RomLibrary.statesDirectory,
        folderID: statesFolder,
        token: token,
        extensions: ["ss0", "ss1", "ss2", "ss3", "ss4", "ss5", "ss6", "ss7", "ss8", "png"]
      )
      uploaded += upT.uploaded
      downloaded += upT.downloaded

      let upA = try await syncArtworkTree(folderID: artworkFolder, token: token)
      uploaded += upA.uploaded
      downloaded += upA.downloaded

      let upC = try await syncDirectory(
        local: companionDocumentsDirectory,
        folderID: companionFolder,
        token: token,
        extensions: ["json"]
      )
      uploaded += upC.uploaded
      downloaded += upC.downloaded

      if upA.downloaded > 0 || upC.downloaded > 0 {
        RomArtworkStore.shared.reloadFromDisk()
      }

      lastResult = "Synced — ↑\(uploaded) ↓\(downloaded)"
      auth.statusMessage = lastResult
      NotificationCenter.default.post(name: .pocketDexLibraryNeedsReload, object: nil)
    } catch {
      lastResult = error.localizedDescription
      auth.statusMessage = lastResult
    }
  }

  private struct Counts {
    var uploaded = 0
    var downloaded = 0
  }

  private var companionDocumentsDirectory: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let dir = docs.appendingPathComponent("Companion", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Nested `Documents/Artwork/<romKey>/{cover,banner,icon,logo,meta}` ↔ Drive `PocketDex/Artwork/<romKey>/`.
  private func syncArtworkTree(folderID: String, token: String) async throws -> Counts {
    let fm = FileManager.default
    let localRoot = RomArtworkStore.shared.rootDirectory
    try? fm.createDirectory(at: localRoot, withIntermediateDirectories: true)

    var counts = Counts()
    let remoteKids = try await listChildren(folderID: folderID, token: token)
    var remoteFolders: [String: DriveFile] = [:]
    for f in remoteKids where f.mimeType == "application/vnd.google-apps.folder" {
      remoteFolders[f.name] = f
    }

    let localKeys = (try? fm.contentsOfDirectory(
      at: localRoot,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    var seenKeys = Set<String>()
    for keyURL in localKeys {
      let values = try? keyURL.resourceValues(forKeys: [.isDirectoryKey])
      guard values?.isDirectory == true else { continue }
      let key = keyURL.lastPathComponent
      seenKeys.insert(key)
      let remoteID: String
      if let existing = remoteFolders[key] {
        remoteID = existing.id
        remoteFolders.removeValue(forKey: key)
      } else {
        remoteID = try await createFolder(named: key, parentID: folderID, token: token)
      }
      let sub = try await syncDirectory(
        local: keyURL,
        folderID: remoteID,
        token: token,
        extensions: ["jpg", "jpeg", "png", "webp", "json"],
        mergeMetaJSON: true
      )
      counts.uploaded += sub.uploaded
      counts.downloaded += sub.downloaded
    }

    // Remote-only artwork folders (restore after reinstall, unless tombstoned)
    let blocked = DeletedCloudNames.all()
    for (key, folder) in remoteFolders {
      let tombstone = "Artwork/\(key)"
      if blocked.contains(tombstone) || blocked.contains(key) {
        try? await deleteFolderContents(folderID: folder.id, token: token)
        try? await deleteFile(id: folder.id, token: token)
        continue
      }
      let destDir = localRoot.appendingPathComponent(key, isDirectory: true)
      try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
      let sub = try await syncDirectory(
        local: destDir,
        folderID: folder.id,
        token: token,
        extensions: ["jpg", "jpeg", "png", "webp", "json"],
        mergeMetaJSON: true
      )
      counts.uploaded += sub.uploaded
      counts.downloaded += sub.downloaded
      seenKeys.insert(key)
    }
    _ = seenKeys
    return counts
  }

  private func syncDirectory(
    local: URL,
    folderID: String,
    token: String,
    extensions: Set<String>,
    mergeMetaJSON: Bool = false
  ) async throws -> Counts {
    let fm = FileManager.default
    try? fm.createDirectory(at: local, withIntermediateDirectories: true)
    let remote = try await listChildren(folderID: folderID, token: token)
    var byName: [String: DriveFile] = [:]
    for f in remote where f.mimeType != "application/vnd.google-apps.folder" {
      byName[f.name] = f
    }

    var counts = Counts()
    let localURLs = (try? fm.contentsOfDirectory(
      at: local,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    )) ?? []

    for url in localURLs {
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
      guard values?.isRegularFile == true else { continue }
      let ext = url.pathExtension.lowercased()
      let okExt = extensions.contains(ext) || extensions.contains(where: { url.lastPathComponent.lowercased().hasSuffix(".\($0)") })
      guard okExt else { continue }
      let name = url.lastPathComponent
      let localDate = values?.contentModificationDate ?? .distantPast
      let localSize = values?.fileSize ?? 0
      if let remoteFile = byName[name] {
        if mergeMetaJSON, name == "meta.json" {
          try await mergeAndSyncMeta(
            localURL: url,
            remoteFile: remoteFile,
            folderID: folderID,
            token: token,
            counts: &counts
          )
        } else {
          let remoteDate = remoteFile.modifiedTime ?? .distantPast
          let remoteSize = remoteFile.size ?? 0
          if localDate > remoteDate.addingTimeInterval(2) || (localSize != remoteSize && localDate >= remoteDate) {
            try await upload(fileURL: url, name: name, folderID: folderID, existingID: remoteFile.id, token: token)
            counts.uploaded += 1
          }
        }
        byName.removeValue(forKey: name)
      } else {
        try await upload(fileURL: url, name: name, folderID: folderID, existingID: nil, token: token)
        counts.uploaded += 1
      }
    }

    // Remaining remote-only files → download (skip names the user deleted locally)
    let blocked = DeletedCloudNames.all()
    for (name, file) in byName {
      if blocked.contains(name) {
        try? await deleteFile(id: file.id, token: token)
        continue
      }
      let dest = local.appendingPathComponent(name)
      let remoteDate = file.modifiedTime ?? .distantPast
      if fm.fileExists(atPath: dest.path) {
        let localDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]))?
          .contentModificationDate ?? .distantPast
        if localDate >= remoteDate { continue }
      }
      try await download(fileID: file.id, to: dest, token: token)
      if let remoteDate = file.modifiedTime {
        try? fm.setAttributes([.modificationDate: remoteDate], ofItemAtPath: dest.path)
      }
      counts.downloaded += 1
    }
    return counts
  }

  /// Field-merge `meta.json` so a custom library title is kept and pushed to Drive.
  private func mergeAndSyncMeta(
    localURL: URL,
    remoteFile: DriveFile,
    folderID: String,
    token: String,
    counts: inout Counts
  ) async throws {
    let decoder = JSONDecoder()
    let encoder = JSONEncoder()
    let fm = FileManager.default

    let localMeta: RomArtworkMeta = {
      guard let data = try? Data(contentsOf: localURL),
            let meta = try? decoder.decode(RomArtworkMeta.self, from: data)
      else { return RomArtworkMeta() }
      return meta
    }()

    let tmp = fm.temporaryDirectory.appendingPathComponent("pocketdex-meta-\(UUID().uuidString).json")
    defer { try? fm.removeItem(at: tmp) }
    try await download(fileID: remoteFile.id, to: tmp, token: token)
    let remoteMeta: RomArtworkMeta = {
      guard let data = try? Data(contentsOf: tmp),
            let meta = try? decoder.decode(RomArtworkMeta.self, from: data)
      else { return RomArtworkMeta() }
      return meta
    }()

    let merged = RomArtworkMeta.merging(localMeta, remoteMeta)
    let needsLocalWrite = merged != localMeta || !fm.fileExists(atPath: localURL.path)
    let needsUpload = merged != remoteMeta
    if needsLocalWrite || needsUpload {
      let data = try encoder.encode(merged)
      try data.write(to: localURL, options: .atomic)
    }
    if needsLocalWrite {
      counts.downloaded += 1
    }
    if needsUpload {
      try await upload(
        fileURL: localURL,
        name: "meta.json",
        folderID: folderID,
        existingID: remoteFile.id,
        token: token
      )
      counts.uploaded += 1
    }
  }

  /// After a local delete: mark filenames and remove matching Drive files so auto-sync cannot resurrect them.
  func purgeDeletedGame(romFileName: String, relatedNames: [String], artworkKey: String? = nil) async {
    var names = Array(Set([romFileName] + relatedNames).filter { !$0.isEmpty })
    if let artworkKey, !artworkKey.isEmpty {
      names.append("Artwork/\(artworkKey)")
      names.append(artworkKey)
    }
    DeletedCloudNames.mark(names)
    guard auth.isSignedIn else { return }
    do {
      let token = try await auth.accessToken()
      let root = try await ensureFolder(named: "PocketDex", parentID: "root", token: token)
      for folder in ["ROMs", "Saves", "States"] {
        let folderID = try await ensureFolder(named: folder, parentID: root, token: token)
        let remote = try await listChildren(folderID: folderID, token: token)
        for f in remote where names.contains(f.name) {
          try? await deleteFile(id: f.id, token: token)
        }
      }
      if let artworkKey, !artworkKey.isEmpty {
        let artRoot = try await ensureFolder(named: "Artwork", parentID: root, token: token)
        let remote = try await listChildren(folderID: artRoot, token: token)
        if let folder = remote.first(where: {
          $0.name == artworkKey && $0.mimeType == "application/vnd.google-apps.folder"
        }) {
          try? await deleteFolderContents(folderID: folder.id, token: token)
          try? await deleteFile(id: folder.id, token: token)
        }
      }
    } catch {
      // Local tombstone still blocks re-download on the next sync.
    }
  }

  private func deleteFolderContents(folderID: String, token: String) async throws {
    let kids = try await listChildren(folderID: folderID, token: token)
    for f in kids {
      if f.mimeType == "application/vnd.google-apps.folder" {
        try? await deleteFolderContents(folderID: f.id, token: token)
      }
      try? await deleteFile(id: f.id, token: token)
    }
  }

  // MARK: - Drive REST

  private struct DriveFile {
    let id: String
    let name: String
    let mimeType: String?
    let modifiedTime: Date?
    let size: Int?
  }

  private func ensureFolder(named: String, parentID: String, token: String) async throws -> String {
    let q = "name='\(escapeQuery(named))' and '\(parentID)' in parents and mimeType='application/vnd.google-apps.folder' and trashed=false"
    let existing = try await list(query: q, token: token)
    if let id = existing.first?.id { return id }
    return try await createFolder(named: named, parentID: parentID, token: token)
  }

  private func listChildren(folderID: String, token: String) async throws -> [DriveFile] {
    let q = "'\(folderID)' in parents and trashed=false"
    return try await list(query: q, token: token)
  }

  private func list(query: String, token: String) async throws -> [DriveFile] {
    var out: [DriveFile] = []
    var pageToken: String?
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let formatterBasic = ISO8601DateFormatter()
    repeat {
      var comps = URLComponents(url: apiRoot.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
      var items: [URLQueryItem] = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "spaces", value: "drive"),
        URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,modifiedTime,size)"),
        URLQueryItem(name: "pageSize", value: "1000"),
      ]
      if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
      comps.queryItems = items
      var req = URLRequest(url: comps.url!)
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      let (data, resp) = try await URLSession.shared.data(for: req)
      guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw DriveSyncError.api("List failed (\( (resp as? HTTPURLResponse)?.statusCode ?? 0 ))")
      }
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
      let files = json["files"] as? [[String: Any]] ?? []
      for f in files {
        guard let id = f["id"] as? String, let name = f["name"] as? String else { continue }
        let modified: Date? = {
          guard let s = f["modifiedTime"] as? String else { return nil }
          return formatter.date(from: s) ?? formatterBasic.date(from: s)
        }()
        let size = (f["size"] as? String).flatMap(Int.init) ?? f["size"] as? Int
        out.append(DriveFile(
          id: id,
          name: name,
          mimeType: f["mimeType"] as? String,
          modifiedTime: modified,
          size: size
        ))
      }
      pageToken = json["nextPageToken"] as? String
    } while pageToken != nil
    return out
  }

  private func createFolder(named: String, parentID: String, token: String) async throws -> String {
    var req = URLRequest(url: apiRoot.appendingPathComponent("files"))
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "name": named,
      "mimeType": "application/vnd.google-apps.folder",
      "parents": [parentID],
    ]
    req.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = json["id"] as? String
    else {
      throw DriveSyncError.api("Create folder failed")
    }
    return id
  }

  private func upload(fileURL: URL, name: String, folderID: String, existingID: String?, token: String) async throws {
    let data = try Data(contentsOf: fileURL)
    let mime = mimeType(for: name)
    if let existingID {
      var comps = URLComponents(url: uploadRoot.appendingPathComponent("files/\(existingID)"), resolvingAgainstBaseURL: false)!
      comps.queryItems = [URLQueryItem(name: "uploadType", value: "media")]
      var req = URLRequest(url: comps.url!)
      req.httpMethod = "PATCH"
      req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
      req.setValue(mime, forHTTPHeaderField: "Content-Type")
      req.httpBody = data
      let (_, resp) = try await URLSession.shared.data(for: req)
      guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        throw DriveSyncError.api("Upload update failed for \(name)")
      }
      return
    }
    let boundary = "pocketdex-\(UUID().uuidString)"
    var comps = URLComponents(url: uploadRoot.appendingPathComponent("files"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [URLQueryItem(name: "uploadType", value: "multipart")]
    var req = URLRequest(url: comps.url!)
    req.httpMethod = "POST"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let meta: [String: Any] = ["name": name, "parents": [folderID]]
    let metaData = try JSONSerialization.data(withJSONObject: meta)
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
    body.append(metaData)
    body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
    body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    req.httpBody = body
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw DriveSyncError.api("Upload failed for \(name)")
    }
  }

  private func download(fileID: String, to dest: URL, token: String) async throws {
    var comps = URLComponents(url: apiRoot.appendingPathComponent("files/\(fileID)"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [URLQueryItem(name: "alt", value: "media")]
    var req = URLRequest(url: comps.url!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw DriveSyncError.api("Download failed")
    }
    try data.write(to: dest, options: [.atomic])
  }

  private func deleteFile(id: String, token: String) async throws {
    var req = URLRequest(url: apiRoot.appendingPathComponent("files/\(id)"))
    req.httpMethod = "DELETE"
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let (_, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) || http.statusCode == 204 else {
      throw DriveSyncError.api("Delete failed (\( (resp as? HTTPURLResponse)?.statusCode ?? 0 ))")
    }
  }

  private func mimeType(for name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "webp": return "image/webp"
    case "json": return "application/json"
    case "sav": return "application/octet-stream"
    default: return "application/octet-stream"
    }
  }

  private func escapeQuery(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
  }
}

enum DriveSyncError: LocalizedError {
  case api(String)
  var errorDescription: String? {
    switch self {
    case .api(let msg): return msg
    }
  }
}
