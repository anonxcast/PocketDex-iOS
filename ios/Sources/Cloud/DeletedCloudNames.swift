import Foundation

/// Filenames the user deleted locally. Drive sync must not re-download these.
enum DeletedCloudNames {
  private static let key = "cloud.deletedFilenames"

  static func all() -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
  }

  static func contains(_ name: String) -> Bool {
    all().contains(name)
  }

  static func mark(_ names: [String]) {
    var set = all()
    for n in names where !n.isEmpty { set.insert(n) }
    UserDefaults.standard.set(Array(set).sorted(), forKey: key)
  }

  static func unmark(_ name: String) {
    var set = all()
    guard set.remove(name) != nil else { return }
    UserDefaults.standard.set(Array(set).sorted(), forKey: key)
  }
}
