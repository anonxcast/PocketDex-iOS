import CoreGraphics
import Foundation
import UIKit

/// PokeDaisy WideCamera zoom steps: larger window in game pixels = more of the map visible.
enum WideCameraMath {
  static let maxViewW = 800
  static let maxViewH = 800
  /// Soft melonDS Expand caps (interpreter). PokeDaisy 1.6.1 draws Expand slices on helper
  /// threads while the next frame runs — Gen 4 can open wider while staying near 60 FPS.
  /// Gen 5 stays tighter without A64 JIT (heavier field). JIT can raise Gen5 to ndsGen5Max* later.
  static let ndsMaxViewW = 512
  static let ndsMaxViewH = 320
  static let ndsGen5MaxViewW = 512
  static let ndsGen5MaxViewH = 384
  static let ndsGen5NoJitMaxViewW = 320
  static let ndsGen5NoJitMaxViewH = 240
  private static let minStep: CGFloat = 1.2

  /// Placement of a WIDE window on the view (matches Android `WideCamera.Window`).
  /// `scale` / `offX` / `offY` are in **screen pixels**; convert to points with `/ nativeScale`.
  struct Placement: Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    /// Screen pixels per game pixel.
    var scale: CGFloat
    /// Screen-pixel offset of the window's top-left from the view's top-left (≤ 0 when fractional).
    var offX: CGFloat
    var offY: CGFloat
  }

  /// Convert SwiftUI points → screen pixels (PokeDaisy WideCamera uses pixels).
  /// Prefer the view's `displayScale` (points→pixels SwiftUI actually uses) over
  /// `nativeScale` so Plus/Max devices don't mix 3× layout with ~2.6× sampling.
  static func pixels(fromPoints size: CGSize) -> CGSize {
    let s = displayScale()
    return CGSize(width: size.width * s, height: size.height * s)
  }

  static func nativeScale() -> CGFloat { displayScale() }

  static func displayScale() -> CGFloat {
    (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale
      ?? UITraitCollection.current.displayScale
  }

  /// Screen pixels per game pixel for each zoom step (1× first = closest).
  /// Integer scales only — same as Android `WideCamera.levelsFor` — so the original
  /// 240×160 frame edge lands on whole screen pixels (avoids Expand seam shimmer).
  ///
  /// `sidesOnly`: lock window height to the console frame (width-only Expand). Prefer
  /// false — full Expand keeps the view filled during auto-zoom like GBA.
  static func levels(
    viewW: CGFloat,
    viewH: CGFloat,
    frameW: Int,
    frameH: Int,
    maxW: Int = maxViewW,
    maxH: Int = maxViewH,
    sidesOnly: Bool = false
  ) -> [CGFloat] {
    guard viewW > 0, viewH > 0, frameW > 0, frameH > 0 else { return [1] }
    let vw = viewW
    let vh = sidesOnly ? CGFloat(frameH) * (viewW / CGFloat(frameW)) : viewH
    let fit = min(vw / CGFloat(frameW), vh / CGFloat(frameH))
    var out: [CGFloat] = [fit]
    var k = Int(floor(fit))
    if CGFloat(k) == fit { k -= 1 }
    while k >= 1 {
      if vw / CGFloat(k) > CGFloat(maxW) { break }
      if !sidesOnly, vh / CGFloat(k) > CGFloat(maxH) { break }
      if out.last! / CGFloat(k) >= minStep {
        out.append(CGFloat(k))
      }
      k -= 1
    }
    return out.isEmpty ? [fit] : out
  }

  /// How much more map step `level` shows vs 1× (for HUD labels).
  static func factor(
    level: Int,
    viewW: CGFloat,
    viewH: CGFloat,
    frameW: Int,
    frameH: Int,
    maxW: Int = maxViewW,
    maxH: Int = maxViewH,
    sidesOnly: Bool = false
  ) -> CGFloat {
    let steps = levels(
      viewW: viewW, viewH: viewH, frameW: frameW, frameH: frameH,
      maxW: maxW, maxH: maxH, sidesOnly: sidesOnly
    )
    guard steps.indices.contains(level), steps[0] > 0 else { return 1 }
    return steps[0] / steps[level]
  }

  static func levelCount(
    viewW: CGFloat,
    viewH: CGFloat,
    frameW: Int,
    frameH: Int,
    maxW: Int = maxViewW,
    maxH: Int = maxViewH,
    sidesOnly: Bool = false
  ) -> Int {
    levels(
      viewW: viewW, viewH: viewH, frameW: frameW, frameH: frameH,
      maxW: maxW, maxH: maxH, sidesOnly: sidesOnly
    ).count
  }

  /// HUD / settings label for a zoom index given the current play-area size (points).
  static func title(
    level: Int,
    displayPoints: CGSize,
    frameW: Int,
    frameH: Int,
    maxW: Int = maxViewW,
    maxH: Int = maxViewH,
    sidesOnly: Bool = false
  ) -> String {
    let px = pixels(fromPoints: displayPoints)
    let steps = levels(
      viewW: px.width, viewH: px.height, frameW: frameW, frameH: frameH,
      maxW: maxW, maxH: maxH, sidesOnly: sidesOnly
    )
    let idx = min(max(0, level), max(0, steps.count - 1))
    if idx == 0 { return "1× (close)" }
    let f = steps[0] / steps[idx]
    let rounded = (f * 10).rounded() / 10
    if abs(rounded - rounded.rounded()) < 0.05 {
      return "\(Int(rounded.rounded()))× out"
    }
    return String(format: "%.1f× out", rounded)
  }

  /// Window + on-screen placement for an arbitrary continuous scale (tweening).
  static func placement(
    scale: CGFloat,
    viewW: CGFloat,
    viewH: CGFloat,
    frameW: Int,
    frameH: Int,
    maxW: Int = maxViewW,
    maxH: Int = maxViewH,
    sidesOnly: Bool = false
  ) -> Placement? {
    guard scale > 0.01, viewW > 0, viewH > 0, frameW > 0, frameH > 0 else { return nil }
    let fw = viewW / scale
    // Sides-only: classic Expand — height stays the console frame; only widen left/right.
    let fh = sidesOnly ? CGFloat(frameH) : viewH / scale
    let fx = CGFloat(frameW) / 2 - fw / 2
    let fy = sidesOnly ? 0 : CGFloat(frameH) / 2 - fh / 2
    let x = Int(floor(fx))
    let y = Int(floor(fy))
    let w = min(maxW, Int(ceil(fx + fw)) - x)
    let h = sidesOnly ? frameH : min(maxH, Int(ceil(fy + fh)) - y)
    guard w > 0, h > 0 else { return nil }
    // Subpixel nudge so the pasted 240×160 frame edge stays on whole screen pixels.
    let offX = (CGFloat(x) - fx) * scale
    let offY = (CGFloat(y) - fy) * scale
    return Placement(x: x, y: y, w: w, h: h, scale: scale, offX: offX, offY: offY)
  }

  /// Convenience: window integers only (native `pk_ios_set_wide_view`).
  static func window(
    scale: CGFloat,
    viewW: CGFloat,
    viewH: CGFloat,
    frameW: Int,
    frameH: Int,
    maxW: Int = maxViewW,
    maxH: Int = maxViewH,
    sidesOnly: Bool = false
  ) -> (x: Int, y: Int, w: Int, h: Int)? {
    guard let p = placement(
      scale: scale, viewW: viewW, viewH: viewH, frameW: frameW, frameH: frameH,
      maxW: maxW, maxH: maxH, sidesOnly: sidesOnly
    ) else {
      return nil
    }
    return (p.x, p.y, p.w, p.h)
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
