import CoreGraphics
import Foundation
import UIKit

/// PokeDaisy WideCamera zoom steps: larger window in game pixels = more of the map visible.
enum WideCameraMath {
  static let maxViewW = 800
  static let maxViewH = 800
  private static let minStep: CGFloat = 1.2
  /// Always offer this many zoom slots when the WIDE buffer allows distinct steps.
  static let maxLevels = 4

  /// Convert SwiftUI points → screen pixels (PokeDaisy WideCamera uses pixels).
  static func pixels(fromPoints size: CGSize) -> CGSize {
    // Scene screen — UIScreen.main is wrong when Duo folds between displays.
    let s = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.nativeScale
      ?? UITraitCollection.current.displayScale
    return CGSize(width: size.width * s, height: size.height * s)
  }

  /// Screen pixels per game pixel for each zoom step (1× first = closest).
  /// Prefers whole-number scales (crisp pixels) like PokeDaisy, then fills remaining
  /// slots with fractional scales so 3× / 4× are real steps when the 800×800 buffer allows.
  static func levels(viewW: CGFloat, viewH: CGFloat, frameW: Int, frameH: Int) -> [CGFloat] {
    guard viewW > 0, viewH > 0, frameW > 0, frameH > 0 else { return [1] }
    let fit = min(viewW / CGFloat(frameW), viewH / CGFloat(frameH))
    let minScale = max(viewW / CGFloat(maxViewW), viewH / CGFloat(maxViewH), 0.5)

    // PokeDaisy integer pixel scales first.
    var out: [CGFloat] = [fit]
    var k = Int(floor(fit))
    if CGFloat(k) == fit { k -= 1 }
    while k >= 1 {
      if viewW / CGFloat(k) > CGFloat(maxViewW) || viewH / CGFloat(k) > CGFloat(maxViewH) { break }
      if out.last! / CGFloat(k) >= minStep {
        out.append(CGFloat(k))
      }
      k -= 1
    }

    // Fill up to 4 distinct steps (phones often only get 1–2 integer scales).
    if out.count < maxLevels {
      let targets: [CGFloat] = [2, 3, 4] // map-coverage factors vs 1×
      for factor in targets {
        guard out.count < maxLevels else { break }
        let s = max(minScale, fit / factor)
        if let last = out.last, last / s >= 1.08 {
          out.append(s)
        }
      }
    }

    // Cap at 4; drop near-duplicates from clamping against minScale.
    var unique: [CGFloat] = []
    for s in out.prefix(maxLevels) {
      if let last = unique.last, abs(last - s) < 0.05 { continue }
      unique.append(s)
    }
    return unique.isEmpty ? [fit] : unique
  }

  /// Window onto the WIDE scene in game pixels, centred on the core frame.
  /// `viewW` / `viewH` must be in **screen pixels** (see `pixels(fromPoints:)`).
  static func window(
    level: Int,
    viewW: CGFloat,
    viewH: CGFloat,
    frameW: Int,
    frameH: Int,
    forceClose: Bool
  ) -> (x: Int, y: Int, w: Int, h: Int, scale: CGFloat)? {
    let steps = levels(viewW: viewW, viewH: viewH, frameW: frameW, frameH: frameH)
    guard !steps.isEmpty else { return nil }
    let scale = forceClose ? steps[0] : steps[min(max(0, level), steps.count - 1)]
    let fw = viewW / scale
    let fh = viewH / scale
    let fx = CGFloat(frameW) / 2 - fw / 2
    let fy = CGFloat(frameH) / 2 - fh / 2
    let x = Int(floor(fx))
    let y = Int(floor(fy))
    let w = min(maxViewW, Int(ceil(fx + fw)) - x)
    let h = min(maxViewH, Int(ceil(fy + fh)) - y)
    guard w > 0, h > 0 else { return nil }
    return (x, y, w, h, scale)
  }

  /// How much more map step `level` shows vs 1× (for HUD labels).
  static func factor(level: Int, viewW: CGFloat, viewH: CGFloat, frameW: Int, frameH: Int) -> CGFloat {
    let steps = levels(viewW: viewW, viewH: viewH, frameW: frameW, frameH: frameH)
    guard steps.indices.contains(level), steps[0] > 0 else { return 1 }
    return steps[0] / steps[level]
  }

  static func levelCount(viewW: CGFloat, viewH: CGFloat, frameW: Int, frameH: Int) -> Int {
    levels(viewW: viewW, viewH: viewH, frameW: frameW, frameH: frameH).count
  }

  /// HUD / settings label for a zoom index given the current play-area size (points).
  static func title(level: Int, displayPoints: CGSize, frameW: Int, frameH: Int) -> String {
    let px = pixels(fromPoints: displayPoints)
    let steps = levels(viewW: px.width, viewH: px.height, frameW: frameW, frameH: frameH)
    let idx = min(max(0, level), max(0, steps.count - 1))
    if idx == 0 { return "1× (close)" }
    let f = steps[0] / steps[idx]
    let rounded = (f * 10).rounded() / 10
    if abs(rounded - rounded.rounded()) < 0.05 {
      return "\(Int(rounded.rounded()))× out"
    }
    return String(format: "%.1f× out", rounded)
  }

  /// Window for an arbitrary continuous scale (used while tweening).
  static func window(
    scale: CGFloat,
    viewW: CGFloat,
    viewH: CGFloat,
    frameW: Int,
    frameH: Int
  ) -> (x: Int, y: Int, w: Int, h: Int)? {
    guard scale > 0.01, viewW > 0, viewH > 0, frameW > 0, frameH > 0 else { return nil }
    let fw = viewW / scale
    let fh = viewH / scale
    let fx = CGFloat(frameW) / 2 - fw / 2
    let fy = CGFloat(frameH) / 2 - fh / 2
    let x = Int(floor(fx))
    let y = Int(floor(fy))
    let w = min(maxViewW, Int(ceil(fx + fw)) - x)
    let h = min(maxViewH, Int(ceil(fy + fh)) - y)
    guard w > 0, h > 0 else { return nil }
    return (x, y, w, h)
  }
}

/// PokeDaisy-style eased zoom (log-space smoothstep) so auto zoom doesn't jump.
@MainActor
final class WideZoomTween {
  /// Pull-in to 1× (~0.42s).
  private static let pullIn: CFTimeInterval = 0.42
  /// Zoom back out (~0.65s).
  private static let zoomOut: CFTimeInterval = 0.65
  /// Hold close after leaving battle/menu before easing out.
  private static let returnDelay: CFTimeInterval = 0.50

  private var scale: CGFloat = 0
  private var tweenFrom: CGFloat = 0
  private var tweenTarget: CGFloat = 0
  private var tweenStart: CFTimeInterval = 0
  private var tweenDuration: CFTimeInterval = 0
  private var closeOverSince: CFTimeInterval = 0

  func reset() {
    scale = 0
    tweenFrom = 0
    tweenTarget = 0
    tweenStart = 0
    tweenDuration = 0
    closeOverSince = 0
  }

  /// Advance the tween and return the current continuous scale.
  func tick(
    now: CFTimeInterval,
    steps: [CGFloat],
    level: Int,
    wantsClose: Bool,
    holdZoom: Bool
  ) -> CGFloat {
    guard let fit = steps.first, fit > 0 else { return 1 }

    // Fade / overlay: don't start a new close/open — hold the current target.
    if !holdZoom {
      if wantsClose {
        closeOverSince = 0
      } else if closeOverSince == 0 {
        closeOverSince = now
      }
    }

    let close = closeOverSince == 0 || now - closeOverSince < Self.returnDelay
    let target: CGFloat = {
      if holdZoom {
        // Keep easing toward whatever we already aimed at.
        return tweenTarget > 0 ? tweenTarget : (scale > 0 ? scale : fit)
      }
      return close ? fit : steps[min(max(0, level), steps.count - 1)]
    }()

    if abs(target - tweenTarget) > 0.001 {
      tweenFrom = scale <= 0 ? target : scale
      tweenTarget = target
      tweenStart = now
      if scale <= 0 {
        tweenDuration = 0 // snap on first frame
      } else if target > tweenFrom + 0.001 {
        tweenDuration = Self.pullIn
      } else {
        tweenDuration = Self.zoomOut
      }
    }

    let p: CGFloat
    if tweenDuration <= 0 {
      p = 1
    } else {
      p = CGFloat(min(1, max(0, (now - tweenStart) / tweenDuration)))
    }
    let s = smoothstep(p)
    if tweenFrom <= 0 || tweenTarget <= 0 {
      scale = tweenTarget
    } else {
      // Log-space ease: same feel at every zoom step (PokeDaisy WideCamera).
      scale = tweenFrom * pow(tweenTarget / tweenFrom, s)
    }
    if abs(scale - tweenTarget) < 0.002 { scale = tweenTarget }
    return scale
  }

  private func smoothstep(_ p: CGFloat) -> CGFloat {
    p * p * (3 - 2 * p)
  }
}
