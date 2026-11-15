import Foundation

/// Per-ROM companion fingerprint written into Documents so the Mac agent can
/// adapt support after you drop a ROM in the app — no manual scripting needed.
enum CompanionRomIdentity {
  struct Record: Codable, Equatable, Identifiable {
    var fileName: String
    var code: String
    var title: String
    var revision: Int
    var romSize: UInt32
    var sha1: String?
    var configId: String?
    var displayName: String?
    var match: String  // "sha1" | "header" | "best_effort" | "none"
    var updatedAt: String
    /// Whether Expand/WIDE tables existed for this ROM when last opened.
    var wideSupported: Bool?

    var id: String { sha1 ?? "\(fileName)|\(code)|\(romSize)" }

    var needsExactPin: Bool {
      match == "none" || match == "best_effort"
    }

    var matchLabel: String {
      switch match {
      case "sha1": return "Pinned"
      case "header": return "Header"
      case "best_effort": return "Best-effort (unverified)"
      default: return "Needs profile"
      }
    }
  }

  private static var companionDir: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let dir = docs.appendingPathComponent("Companion", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static var lastURL: URL { companionDir.appendingPathComponent("last-rom.json") }
  static var pendingURL: URL { companionDir.appendingPathComponent("pending.json") }
  /// Runtime SHA-1 → config id overlay (agent can push this to the device without a rebuild).
  static var pinsURL: URL { companionDir.appendingPathComponent("pins.json") }

  static func loadPins() -> [String: String] {
    guard let data = try? Data(contentsOf: pinsURL),
          let map = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    var out: [String: String] = [:]
    for (k, v) in map { out[k.lowercased()] = v }
    return out
  }

  static func savePins(_ pins: [String: String]) {
    let normalized = Dictionary(uniqueKeysWithValues: pins.map { ($0.key.lowercased(), $0.value) })
    guard let data = try? JSONEncoder().encode(normalized) else { return }
    try? data.write(to: pinsURL, options: .atomic)
  }

  static func pin(sha1: String, configId: String) {
    var pins = loadPins()
    pins[sha1.lowercased()] = configId
    savePins(pins)
    resolvePending(sha1: sha1)
  }

  static func write(record: Record) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(record) {
      try? data.write(to: lastURL, options: .atomic)
    }

    if record.needsExactPin {
      upsertPending(record)
    } else if let sha1 = record.sha1 {
      resolvePending(sha1: sha1)
    }
  }

  private static func upsertPending(_ record: Record) {
    var pending = loadPending()
    if let sha1 = record.sha1 {
      pending.removeAll { $0.sha1?.lowercased() == sha1.lowercased() }
    } else {
      pending.removeAll {
        $0.fileName == record.fileName && $0.code == record.code && $0.romSize == record.romSize
      }
    }
    pending.insert(record, at: 0)
    if pending.count > 40 { pending = Array(pending.prefix(40)) }
    savePending(pending)
  }

  static func resolvePending(sha1: String) {
    let key = sha1.lowercased()
    var pending = loadPending()
    let before = pending.count
    pending.removeAll { $0.sha1?.lowercased() == key }
    if pending.count != before { savePending(pending) }
  }

  static func clearPending() {
    savePending([])
  }

  static func removePending(id: String) {
    var pending = loadPending()
    pending.removeAll { $0.id == id }
    savePending(pending)
  }

  private static func savePending(_ pending: [Record]) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(pending) {
      try? data.write(to: pendingURL, options: .atomic)
    }
  }

  static func loadPending() -> [Record] {
    guard let data = try? Data(contentsOf: pendingURL),
          let list = try? JSONDecoder().decode([Record].self, from: data)
    else { return [] }
    return list
  }

  /// JSON blob for Share / Files — agent uses this to pin SHA-1 → config id.
  static func exportQueueText() -> String {
    let pending = loadPending()
    let payload: [String: Any] = [
      "format": "pocketdex.companion.support_queue.v1",
      "exportedAt": isoNow(),
      "note": "Pin via Documents/Companion/pins.json as {\"<sha1>\":\"<configId>\"}, or add Poller.kt + regen gen_ios_companion.py. Expand/WIDE still needs a CRC profile in pk_wide.",
      "count": pending.count,
      "pending": pending.map { rec -> [String: Any] in
        var d: [String: Any] = [
          "fileName": rec.fileName,
          "code": rec.code,
          "title": rec.title,
          "revision": rec.revision,
          "romSize": rec.romSize,
          "match": rec.match,
          "updatedAt": rec.updatedAt,
        ]
        if let sha1 = rec.sha1 { d["sha1"] = sha1 }
        if let configId = rec.configId { d["configId"] = configId }
        if let displayName = rec.displayName { d["displayName"] = displayName }
        if let wide = rec.wideSupported { d["wideSupported"] = wide }
        return d
      },
    ]
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8)
    else {
      return "{\"error\":\"encode failed\"}"
    }
    return text
  }

  static func isoNow() -> String {
    ISO8601DateFormatter().string(from: Date())
  }
}
