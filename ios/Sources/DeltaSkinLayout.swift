import CoreGraphics
import Foundation
import ImageIO
import UIKit

struct SkinRect: Equatable {
  var x: CGFloat
  var y: CGFloat
  var width: CGFloat
  var height: CGFloat

  var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

  init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    self.x = x; self.y = y; self.width = width; self.height = height
  }

  init?(_ dict: [String: Any]?) {
    guard let dict,
          let x = SkinRect.num(dict["x"]),
          let y = SkinRect.num(dict["y"]),
          let w = SkinRect.num(dict["width"]),
          let h = SkinRect.num(dict["height"]) else { return nil }
    self.init(x: x, y: y, width: w, height: h)
  }

  private static func num(_ any: Any?) -> CGFloat? {
    if let n = any as? NSNumber { return CGFloat(truncating: n) }
    if let d = any as? Double { return CGFloat(d) }
    if let i = any as? Int { return CGFloat(i) }
    return nil
  }

  func insetBy(edges: SkinEdges, defaults: SkinEdges) -> SkinRect {
    let t = edges.top ?? defaults.top ?? 0
    let b = edges.bottom ?? defaults.bottom ?? 0
    let l = edges.left ?? defaults.left ?? 0
    let r = edges.right ?? defaults.right ?? 0
    return SkinRect(x: x - l, y: y - t, width: width + l + r, height: height + t + b)
  }
}

struct SkinEdges {
  var top: CGFloat?
  var bottom: CGFloat?
  var left: CGFloat?
  var right: CGFloat?

  init(_ dict: [String: Any]?) {
    top = SkinEdges.num(dict?["top"])
    bottom = SkinEdges.num(dict?["bottom"])
    left = SkinEdges.num(dict?["left"])
    right = SkinEdges.num(dict?["right"])
  }

  private static func num(_ any: Any?) -> CGFloat? {
    if let n = any as? NSNumber { return CGFloat(truncating: n) }
    if let d = any as? Double { return CGFloat(d) }
    if let i = any as? Int { return CGFloat(i) }
    return nil
  }
}

enum SkinInput: Hashable {
  case button(String)
  case dpad
  case menu
  case touchScreen
  case ignored
}

struct SkinControlItem {
  let input: SkinInput
  let frame: SkinRect
  let hitFrame: SkinRect
  /// For dpad: directional string mapping
  let dpadMap: [String: String]
  /// Per-control artwork (Duo Folio 2: `btn_d-pad.jxl`, `btn_n/e/s/w.jxl`). Drawn over chrome holes.
  let assetImage: UIImage?
  /// `circle` / `rectangle` from info.json — decorative hint only.
  let mask: String?
}

/// One game LCD placement (Delta / Manic: crop `inputFrame` from the core buffer into `outputFrame`).
struct SkinScreen: Equatable {
  /// Region of the core framebuffer (NDS full buffer is 256×384; top y=0, bottom y=192).
  var inputFrame: SkinRect?
  /// Where that crop appears in skin mapping coordinates.
  var outputFrame: SkinRect
}

struct DeltaSkinRepresentation {
  let mappingSize: CGSize
  let assetImage: UIImage?
  /// First screen output (compat). Prefer `screens`.
  let screenFrame: SkinRect?
  /// All screens — NDS skins usually have two (top + bottom / touch).
  let screens: [SkinScreen]
  let items: [SkinControlItem]
  let defaultEdges: SkinEdges

  /// Explicit touchScreen item frame, else the second screen's output (Delta convention).
  var touchScreenFrame: SkinRect? {
    for item in items {
      if case .touchScreen = item.input { return item.frame }
    }
    if screens.count >= 2 { return screens[1].outputFrame }
    return screenFrame
  }
}

enum DeltaSkinParser {
  /// - Parameter preferCoverLayout: Duo closed / outer face — prefer `outer`/`cover` over `inner`.
  static func loadRepresentation(
    skinDir: URL,
    landscape: Bool,
    viewSize: CGSize,
    preferCoverLayout: Bool = false
  ) -> DeltaSkinRepresentation? {
    let infoURL = skinDir.appendingPathComponent("info.json")
    guard let data = try? Data(contentsOf: infoURL),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

    let orientationKey = landscape ? "landscape" : "portrait"
    guard let layout = pickLayout(
      from: json,
      orientation: orientationKey,
      preferCoverLayout: preferCoverLayout
    ) else { return nil }

    let mapDict = layout["mappingSize"] as? [String: Any]
    let mapW = cg(mapDict?["width"]) ?? (landscape ? 896 : 414)
    let mapH = cg(mapDict?["height"]) ?? (landscape ? 414 : 896)
    let mappingSize = CGSize(width: mapW, height: mapH)
    let defaultEdges = SkinEdges(layout["extendedEdges"] as? [String: Any])

    let rawScreens = layout["screens"] as? [[String: Any]] ?? []
    let screens: [SkinScreen] = rawScreens.compactMap { dict in
      guard let output = SkinRect(dict["outputFrame"] as? [String: Any]),
            output.width >= 40, output.height >= 40 else { return nil }
      return SkinScreen(inputFrame: SkinRect(dict["inputFrame"] as? [String: Any]), outputFrame: output)
    }
    let screenFrame = screens.first?.outputFrame

    let rawItems = layout["items"] as? [[String: Any]] ?? []
    let items: [SkinControlItem] = rawItems.compactMap { parseItem($0, defaults: defaultEdges, skinDir: skinDir) }

    let image = loadAsset(layout: layout, skinDir: skinDir, viewSize: viewSize)
    return DeltaSkinRepresentation(
      mappingSize: mappingSize,
      assetImage: image,
      screenFrame: screenFrame,
      screens: screens,
      items: items,
      defaultEdges: defaultEdges
    )
  }

  /// Prefer iPhone layouts. Duo Folio uses `inner` / `outer` / `cover` / `splitView`
  /// instead of classic `edgeToEdge` / `standard`.
  private static func pickLayout(
    from json: [String: Any],
    orientation: String,
    preferCoverLayout: Bool
  ) -> [String: Any]? {
    let reps = json["representations"] as? [String: Any] ?? json
    let deviceOrder = ["iphone", "ipad"]
    // Open Duo → inner dual LCDs. Closed outer display → cover/outer face first.
    let sizeOrder = preferCoverLayout
      ? ["outer", "cover", "edgeToEdge", "standard", "splitView", "inner"]
      : ["inner", "edgeToEdge", "standard", "outer", "splitView", "cover"]

    for device in deviceOrder {
      guard let deviceNode = reps[device] as? [String: Any] else { continue }
      for size in sizeOrder {
        if let sizeNode = deviceNode[size] as? [String: Any],
           let orient = sizeNode[orientation] as? [String: Any],
           usableLayout(orient) {
          return orient
        }
      }
      if let orient = deviceNode[orientation] as? [String: Any], usableLayout(orient) {
        return orient
      }
    }

    if let orient = reps[orientation] as? [String: Any], usableLayout(orient) { return orient }

    return deepFind(reps, orientation: orientation)
  }

  /// Reject cover art and broken single-pixel screen placements.
  private static func usableLayout(_ layout: [String: Any]) -> Bool {
    if layout["mappingSize"] == nil && layout["items"] == nil && layout["screens"] == nil {
      return false
    }
    let screens = layout["screens"] as? [[String: Any]] ?? []
    if screens.isEmpty { return (layout["items"] as? [Any])?.isEmpty == false }
    let real = screens.filter { dict in
      guard let out = SkinRect(dict["outputFrame"] as? [String: Any]) else { return false }
      return out.width >= 40 && out.height >= 40
    }
    return real.count >= 1
  }

  private static func deepFind(_ node: [String: Any], orientation: String) -> [String: Any]? {
    if let orient = node[orientation] as? [String: Any],
       orient["mappingSize"] != nil || orient["items"] != nil {
      return orient
    }
    for (_, value) in node {
      if let dict = value as? [String: Any], let found = deepFind(dict, orientation: orientation) {
        return found
      }
    }
    return nil
  }

  private static func parseItem(_ dict: [String: Any], defaults: SkinEdges, skinDir: URL) -> SkinControlItem? {
    guard let frame = SkinRect(dict["frame"] as? [String: Any]) else { return nil }
    let edges = SkinEdges(dict["extendedEdges"] as? [String: Any])
    let hit = frame.insetBy(edges: edges, defaults: defaults)
    let mask = dict["mask"] as? String
    let assetImage = loadItemAsset(dict["asset"] as? [String: Any], skinDir: skinDir)

    func item(_ input: SkinInput, dpadMap: [String: String] = [:]) -> SkinControlItem {
      SkinControlItem(
        input: input, frame: frame, hitFrame: hit, dpadMap: dpadMap,
        assetImage: assetImage, mask: mask
      )
    }

    if let inputsObj = dict["inputs"] as? [String: Any] {
      let keys = inputsObj.keys.map { $0.lowercased() }
      // Stylus mapping {"x":"touchScreenX","y":"touchScreenY"} — not a d-pad.
      if keys.contains("touchscreenx") || keys.contains("touchscreeny")
          || "\(inputsObj.values)".lowercased().contains("touchscreen") {
        return item(.touchScreen)
      }
      // D-pad / thumbstick style
      if keys.contains("up") || keys.contains("down") {
        var map: [String: String] = [:]
        for (k, v) in inputsObj {
          map[k.lowercased()] = "\(v)".lowercased()
        }
        return item(.dpad, dpadMap: map)
      }
    }

    if let inputsArr = dict["inputs"] as? [String] {
      let names = inputsArr.map { $0.lowercased() }
      if names.contains("menu") { return item(.menu) }
      if names.contains("touchscreen") || names.contains("touch_screen") {
        return item(.touchScreen)
      }
      if let first = names.first {
        return item(.button(first))
      }
    }

    // Some skins use {"inputs":{"a":"a"}} weirdness — ignore
    return item(.ignored)
  }

  /// Item-level `asset: { name, width, height }` (JPEG XL / PNG overlays).
  private static func loadItemAsset(_ dict: [String: Any]?, skinDir: URL) -> UIImage? {
    guard let name = dict?["name"] as? String, !name.isEmpty else { return nil }
    return loadImageFile(skinDir.appendingPathComponent(name))
  }

  private static func loadAsset(layout: [String: Any], skinDir: URL, viewSize: CGSize) -> UIImage? {
    let assets = layout["assets"] as? [String: Any] ?? [:]
    // PDF resizable
    if let pdfName = assets["resizable"] as? String {
      let url = skinDir.appendingPathComponent(pdfName)
      if let img = renderPDF(url: url, target: viewSize) { return img }
    }
    // PNG / JPEG / JPEG XL sizes (Duo Folio ships `.jxl`)
    // Don’t use UIScreen.main — Duo resizes across displays; read scale from the active scene.
    let scale = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.screen.scale
      ?? UITraitCollection.current.displayScale
    let prefer: [String] = {
      if scale >= 3 { return ["large", "medium", "small"] }
      if scale >= 2 { return ["medium", "large", "small"] }
      return ["small", "medium", "large"]
    }()
    for key in prefer {
      if let name = assets[key] as? String {
        let url = skinDir.appendingPathComponent(name)
        if let img = loadImageFile(url) { return img }
      }
    }
    for (_, value) in assets {
      if let name = value as? String {
        let url = skinDir.appendingPathComponent(name)
        if name.lowercased().hasSuffix(".pdf"), let img = renderPDF(url: url, target: viewSize) { return img }
        if let img = loadImageFile(url) { return img }
      }
    }
    return nil
  }

  /// UIImage + ImageIO (JPEG XL on iOS 17+).
  private static func loadImageFile(_ url: URL) -> UIImage? {
    if let img = UIImage(contentsOfFile: url.path) { return img }
    guard FileManager.default.fileExists(atPath: url.path),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(src) > 0,
          let cg = CGImageSourceCreateImageAtIndex(
            src, 0,
            [kCGImageSourceShouldCache: true] as CFDictionary
          ) else { return nil }
    return UIImage(cgImage: cg)
  }

  private static func renderPDF(url: URL, target: CGSize) -> UIImage? {
    guard let doc = CGPDFDocument(url as CFURL), let page = doc.page(at: 1) else { return nil }
    let pdfRect = page.getBoxRect(.mediaBox)
    guard pdfRect.width > 1, pdfRect.height > 1, target.width > 1, target.height > 1 else { return nil }
    // Aspect-fit into the target (Delta does not stretch PDFs to fill).
    let displayScale = min(UITraitCollection.current.displayScale, 3)
    let maxEdge: CGFloat = 2048
    var scale = min(target.width / pdfRect.width, target.height / pdfRect.height) * displayScale
    var size = CGSize(width: pdfRect.width * scale, height: pdfRect.height * scale)
    let longest = max(size.width, size.height)
    if longest > maxEdge {
      scale *= maxEdge / longest
      size = CGSize(width: pdfRect.width * scale, height: pdfRect.height * scale)
    }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { ctx in
      UIColor.clear.setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
      ctx.cgContext.translateBy(x: 0, y: size.height)
      ctx.cgContext.scaleBy(x: scale, y: -scale)
      ctx.cgContext.drawPDFPage(page)
    }
  }

  private static func cg(_ any: Any?) -> CGFloat? {
    if let n = any as? NSNumber { return CGFloat(truncating: n) }
    if let d = any as? Double { return CGFloat(d) }
    if let i = any as? Int { return CGFloat(i) }
    return nil
  }
}

/// Maps skin mapping coordinates ↔ view coordinates.
struct SkinViewTransform {
  let mappingSize: CGSize
  let displayRect: CGRect

  /// Delta fits `mappingSize` into the container (aspect-fit). Stretching warps screens + hitboxes.
  init(mappingSize: CGSize, viewSize: CGSize, fill: Bool = false, in bounds: CGRect? = nil) {
    self.mappingSize = mappingSize
    let container = bounds ?? CGRect(origin: .zero, size: viewSize)
    if fill {
      displayRect = container
    } else {
      let sx = container.width / max(mappingSize.width, 1)
      let sy = container.height / max(mappingSize.height, 1)
      let s = min(sx, sy)
      let w = mappingSize.width * s
      let h = mappingSize.height * s
      displayRect = CGRect(
        x: container.minX + (container.width - w) / 2,
        y: container.minY + (container.height - h) / 2,
        width: w,
        height: h
      )
    }
  }

  func viewRect(from mapping: SkinRect) -> CGRect {
    let sx = displayRect.width / mappingSize.width
    let sy = displayRect.height / mappingSize.height
    return CGRect(
      x: displayRect.minX + mapping.x * sx,
      y: displayRect.minY + mapping.y * sy,
      width: mapping.width * sx,
      height: mapping.height * sy
    )
  }

  func mappingPoint(from viewPoint: CGPoint) -> CGPoint {
    let sx = mappingSize.width / displayRect.width
    let sy = mappingSize.height / displayRect.height
    return CGPoint(
      x: (viewPoint.x - displayRect.minX) * sx,
      y: (viewPoint.y - displayRect.minY) * sy
    )
  }
}

enum SkinInputMapper {
  static func gbaMask(for name: String) -> UInt32? {
    switch name.lowercased() {
    case "a": return 1 << 0
    case "b": return 1 << 1
    case "select": return 1 << 2
    case "start": return 1 << 3
    case "right": return 1 << 4
    case "left": return 1 << 5
    case "up": return 1 << 6
    case "down": return 1 << 7
    case "r", "r1": return 1 << 8
    case "l", "l1": return 1 << 9
    case "x": return 1 << 10
    case "y": return 1 << 11
    default: return nil
    }
  }

  /// Delta divides a dpad frame into a 3×3 grid; corners = diagonals, center = neutral.
  static func dpadMask(at mappingPoint: CGPoint, frame: SkinRect, map: [String: String]) -> UInt32 {
    let relX = (mappingPoint.x - frame.x) / max(frame.width, 1)
    let relY = (mappingPoint.y - frame.y) / max(frame.height, 1)
    let col = relX < (1.0 / 3.0) ? 0 : (relX < (2.0 / 3.0) ? 1 : 2)
    let row = relY < (1.0 / 3.0) ? 0 : (relY < (2.0 / 3.0) ? 1 : 2)
    if col == 1 && row == 1 { return 0 }

    var mask: UInt32 = 0
    func add(_ key: String) {
      let mapped = map[key] ?? key
      if let bit = gbaMask(for: mapped) { mask |= bit }
    }
    if row == 0 { add("up") }
    if row == 2 { add("down") }
    if col == 0 { add("left") }
    if col == 2 { add("right") }
    return mask
  }
}
