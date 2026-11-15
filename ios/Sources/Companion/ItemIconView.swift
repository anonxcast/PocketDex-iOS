import SwiftUI
import UIKit

/// Bundled bag icons under `Resources/ItemIcons`.
/// Prefer name-keyed sprites (`ItemIcons/Names/<normalized>.png` from PokéSprite / PokeAPI)
/// so retail, Unbound, Seaglass, and DS item id spaces all resolve. Numeric
/// `ItemIcons/<id>.png` remains as a Gen 3 retail fallback.
enum ItemIconStore {
  private static var cache: [String: UIImage] = [:]

  static func image(itemId: Int, name: String? = nil, tables: Gen3Tables = .retail) -> UIImage? {
    if let name, let img = image(named: name) { return img }
    if itemId > 0 {
      let resolvedName = name ?? Gen3Names.item(itemId, tables: tables)
      if !resolvedName.hasPrefix("Item #"), let img = image(named: resolvedName) {
        return img
      }
      // Unbound remaps many ids onto retail icon numbers.
      let iconId = Gen3Names.itemIconId(itemId, tables: tables)
      if let img = image(numericId: iconId) { return img }
      if iconId != itemId, let img = image(numericId: itemId) { return img }
    }
    return nil
  }

  static func image(named name: String) -> UIImage? {
    let key = normalize(name)
    guard !key.isEmpty else { return nil }
    if let cached = cache[key] { return cached }
    let url = Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "ItemIcons/Names")
      ?? Bundle.main.url(forResource: key, withExtension: "png", subdirectory: "Names")
    guard let url, let img = UIImage(contentsOfFile: url.path) else { return nil }
    cache[key] = img
    return img
  }

  private static func image(numericId: Int) -> UIImage? {
    guard numericId > 0 else { return nil }
    let key = "#\(numericId)"
    if let cached = cache[key] { return cached }
    guard let url = Bundle.main.url(forResource: "\(numericId)", withExtension: "png", subdirectory: "ItemIcons")
            ?? Bundle.main.url(forResource: "\(numericId)", withExtension: "png"),
          let img = UIImage(contentsOfFile: url.path) else {
      return nil
    }
    cache[key] = img
    return img
  }

  /// Match the Python packer: strip diacritics, keep [a-z0-9] only.
  static func normalize(_ name: String) -> String {
    let folded = name.folding(options: .diacriticInsensitive, locale: .current).lowercased()
    var out = ""
    out.reserveCapacity(folded.count)
    for ch in folded where ch.isLetter || ch.isNumber {
      out.append(ch)
    }
    return out
  }
}

struct ItemIconView: View {
  let itemId: Int
  var tables: Gen3Tables = .retail
  var size: CGFloat = 28

  private var resolvedName: String {
    itemId > 0 ? Gen3Names.item(itemId, tables: tables) : ""
  }

  var body: some View {
    Group {
      if itemId <= 0 {
        Image(systemName: "circle.dashed")
          .font(.system(size: size * 0.45, weight: .semibold))
          .foregroundStyle(CETheme.muted)
      } else if let img = ItemIconStore.image(itemId: itemId, name: resolvedName, tables: tables) {
        Image(uiImage: img)
          .resizable()
          .interpolation(.none)
          .aspectRatio(contentMode: .fit)
      } else {
        // Quiet fallback (no bright blue box) when a hack-only item has no art.
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(CETheme.elevated)
          .overlay(
            Image(systemName: "shippingbox")
              .font(.system(size: size * 0.38, weight: .medium))
              .foregroundStyle(CETheme.muted)
          )
      }
    }
    .frame(width: size, height: size)
  }
}
