import CoreGraphics
import Foundation

/// CPU ports of PokeDaisy ScreenShaders (GBA COLORS + UNLIT SCREEN) on RGBA8888 frames.
/// Unlit is optimized for large EXPAND/WIDE buffers (zoom ≥2×): gamma LUTs + one luma plane,
/// so soft-shadow taps never recompute `pow` per sample. Rows run in parallel when the
/// buffer is large enough that a serial pass would hitch audio.
enum FrameShaders {
  private static let gammaValue: Float = 2.2

  /// sRGB byte → linear (γ 2.2)
  private static let decodeLUT: [Float] = {
    var t = [Float](repeating: 0, count: 256)
    for i in 0..<256 {
      t[i] = powf(Float(i) / 255.0, 2.2)
    }
    return t
  }()

  /// Linear [0,1] → sRGB byte (γ 1/2.2), 4096 steps
  private static let encodeLUT: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 4096)
    let inv: Float = 1.0 / 2.2
    let last = Float(4095)
    for i in 0..<4096 {
      let v = Float(i) / last
      let encoded = powf(v, inv) * 255.0 + 0.5
      t[i] = UInt8(max(0, min(255, Int(encoded))))
    }
    return t
  }()

  private static let backingR: Float = powf(0.82, 2.2)
  private static let backingG: Float = powf(0.84, 2.2)
  private static let backingB: Float = powf(0.77, 2.2)

  private static let gbaDecodeDark: [Float] = {
    var t = [Float](repeating: 0, count: 256)
    for i in 0..<256 {
      t[i] = powf(Float(i) / 255.0, 2.2 + 0.5)
    }
    return t
  }()

  private static let gbaEncodeDark: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 4096)
    let exp: Float = Float(1.0 / 2.5 + 0.5 * 0.125)
    let last = Float(4095)
    for i in 0..<4096 {
      let v = Float(i) / last
      let encoded = powf(max(v, 0), exp) * 255.0 + 0.5
      t[i] = UInt8(max(0, min(255, Int(encoded))))
    }
    return t
  }()

  /// Apply optional GBA colour matrix and/or unlit reflective backing in-place on RGBA bytes.
  static func apply(
    rgba: inout [UInt8],
    width: Int,
    height: Int,
    gbaColors: Bool,
    unlit: Bool
  ) {
    guard width > 0, height > 0, rgba.count >= width * height * 4 else { return }
    if gbaColors {
      applyGbaColors(&rgba, count: width * height)
    }
    if unlit {
      applyUnlit(&rgba, width: width, height: height)
    }
  }

  /// mGBA gba-color defaults (Pokefan531 / hunterk) as used by PokeDaisy.
  private static func applyGbaColors(_ rgba: inout [UInt8], count: Int) {
    let lum: Float = 0.99
    let lcd00: Float = 0.84, lcd01: Float = 0.18, lcd02: Float = 0.00
    let lcd10: Float = 0.09, lcd11: Float = 0.67, lcd12: Float = 0.26
    let lcd20: Float = 0.15, lcd21: Float = 0.10, lcd22: Float = 0.73
    let decodeDark = gbaDecodeDark
    let encodeDark = gbaEncodeDark
    let encMax = Float(encodeDark.count - 1)
    for i in 0..<count {
      let o = i * 4
      var r = decodeDark[Int(rgba[o])] * lum
      var g = decodeDark[Int(rgba[o + 1])] * lum
      var b = decodeDark[Int(rgba[o + 2])] * lum
      r = min(1, max(0, r))
      g = min(1, max(0, g))
      b = min(1, max(0, b))
      let nr = lcd00 * r + lcd01 * g + lcd02 * b
      let ng = lcd10 * r + lcd11 * g + lcd12 * b
      let nb = lcd20 * r + lcd21 * g + lcd22 * b
      rgba[o] = encodeDark[Int(min(1, max(0, nr)) * encMax)]
      rgba[o + 1] = encodeDark[Int(min(1, max(0, ng)) * encMax)]
      rgba[o + 2] = encodeDark[Int(min(1, max(0, nb)) * encMax)]
    }
  }

  /// PokeDaisy `ScreenShaders.UNLIT`: grey-green backing × transmission × soft shadow (0.6, 0.8).
  private static func applyUnlit(_ rgba: inout [UInt8], width: Int, height: Int) {
    let shadowOx: Float = 0.6
    let shadowOy: Float = 0.8
    let soft: Float = 0.4
    let strength: Float = 0.6
    let br = backingR
    let bg = backingG
    let bb = backingB
    let n = width * height
    let parallel = n > 80_000

    var luma = [Float](repeating: 0, count: n)

    // Pass 1: linear luma plane (LUT decode — no pow in the hot loop).
    rgba.withUnsafeBufferPointer { srcBuf in
      guard let src = srcBuf.baseAddress else { return }
      luma.withUnsafeMutableBufferPointer { lumaBuf in
        guard let lumaPtr = lumaBuf.baseAddress else { return }
        let decode = decodeLUT
        let buildRow: (Int) -> Void = { y in
          let row = y * width
          for x in 0..<width {
            let i = row + x
            let o = i * 4
            let r = decode[Int(src[o])]
            let g = decode[Int(src[o + 1])]
            let b = decode[Int(src[o + 2])]
            lumaPtr[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
          }
        }
        if parallel {
          DispatchQueue.concurrentPerform(iterations: height, execute: buildRow)
        } else {
          for y in 0..<height { buildRow(y) }
        }
      }
    }

    // Pass 2: soft shadow from precomputed luma + backing.
    rgba.withUnsafeMutableBufferPointer { dstBuf in
      guard let dst = dstBuf.baseAddress else { return }
      luma.withUnsafeBufferPointer { lumaBuf in
        guard let lumaPtr = lumaBuf.baseAddress else { return }
        let decode = decodeLUT
        let encode = encodeLUT
        let encMax = Float(encode.count - 1)
        let wMinus = width - 1
        let hMinus = height - 1

        let sampleLuma: (Float, Float) -> Float = { sx, sy in
          let xf = min(Float(wMinus), max(0, sx))
          let yf = min(Float(hMinus), max(0, sy))
          let x0 = Int(xf)
          let y0 = Int(yf)
          let x1 = min(wMinus, x0 + 1)
          let y1 = min(hMinus, y0 + 1)
          let tx = xf - Float(x0)
          let ty = yf - Float(y0)
          let a = lumaPtr[y0 * width + x0]
          let bSamp = lumaPtr[y0 * width + x1]
          let c = lumaPtr[y1 * width + x0]
          let d = lumaPtr[y1 * width + x1]
          let top = a + (bSamp - a) * tx
          let bot = c + (d - c) * tx
          return top + (bot - top) * ty
        }

        let shadeRow: (Int) -> Void = { y in
          for x in 0..<width {
            let o = (y * width + x) * 4
            let r = decode[Int(dst[o])]
            let g = decode[Int(dst[o + 1])]
            let b = decode[Int(dst[o + 2])]
            let sx = Float(x) - shadowOx
            let sy = Float(y) - shadowOy
            let t = 0.25 * (
              sampleLuma(sx - soft, sy - soft) +
              sampleLuma(sx + soft, sy - soft) +
              sampleLuma(sx - soft, sy + soft) +
              sampleLuma(sx + soft, sy + soft)
            )
            let mixT = (1 - strength) + strength * t
            dst[o] = encode[Int(min(1, max(0, r * br * mixT)) * encMax)]
            dst[o + 1] = encode[Int(min(1, max(0, g * bg * mixT)) * encMax)]
            dst[o + 2] = encode[Int(min(1, max(0, b * bb * mixT)) * encMax)]
          }
        }

        if parallel {
          DispatchQueue.concurrentPerform(iterations: height, execute: shadeRow)
        } else {
          for y in 0..<height { shadeRow(y) }
        }
      }
    }
  }
}
