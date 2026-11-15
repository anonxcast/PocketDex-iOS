import SwiftUI
import UIKit

/// Bundled National Dex menu icons (`Resources/SpeciesIcons/<n>.png`).
enum SpeciesIconStore {
  private static var cache: [Int: UIImage] = [:]

  static func image(nationalDex n: Int) -> UIImage? {
    guard n > 0 else { return nil }
    if let cached = cache[n] { return cached }
    guard let url = Bundle.main.url(forResource: "\(n)", withExtension: "png", subdirectory: "SpeciesIcons")
            ?? Bundle.main.url(forResource: "\(n)", withExtension: "png"),
          let img = UIImage(contentsOfFile: url.path) else {
      return nil
    }
    cache[n] = img
    return img
  }
}

struct SpeciesIconView: View {
  let nationalDex: Int?
  var size: CGFloat = 28
  /// Seen-but-not-caught Pokédex entries render grayscale (classic dex silhouette feel).
  var grayscale: Bool = false
  /// Unseen: hide the sprite entirely.
  var hidden: Bool = false

  var body: some View {
    Group {
      if hidden {
        RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
          .fill(CETheme.border.opacity(0.35))
          .overlay(
            Image(systemName: "questionmark")
              .font(.system(size: size * 0.38, weight: .bold))
              .foregroundStyle(CETheme.muted.opacity(0.7))
          )
      } else if let n = nationalDex, let img = SpeciesIconStore.image(nationalDex: n) {
        Image(uiImage: img)
          .resizable()
          .interpolation(.none)
          .aspectRatio(contentMode: .fit)
          .saturation(grayscale ? 0 : 1)
          .brightness(grayscale ? -0.05 : 0)
      } else {
        Image(systemName: "circle.circle")
          .font(.system(size: size * 0.55, weight: .semibold))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(CETheme.muted)
      }
    }
    .frame(width: size, height: size)
  }
}

/// Lead / “1st party” sprite chip used on the play HUD.
struct StarterBadgeView: View {
  let mon: Mon?
  let tables: Gen3Tables

  var body: some View {
    let national = mon.flatMap { Gen3Names.nationalNumber(species: $0.species, tables: tables) }
    ZStack(alignment: .bottomTrailing) {
      SpeciesIconView(nationalDex: national, size: 30)
        .padding(3)
        .background(CETheme.card.opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(CETheme.border.opacity(0.7), lineWidth: 1)
        )
      Text("1")
        .font(CETheme.mono(7))
        .foregroundStyle(.black)
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(CETheme.crystal.opacity(0.95), in: Capsule())
        .offset(x: 2, y: 2)
    }
    .accessibilityLabel(starterLabel)
  }

  private var starterLabel: String {
    guard let mon else { return "No lead Pokémon" }
    let name = Gen3Names.species(mon.species, tables: tables)
    return "Lead Pokémon \(name)"
  }
}
