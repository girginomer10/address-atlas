// Composes the README images from the synthetic review screenshots in
// docs/design/screenshots. It reads only those PNGs, the app icon and the
// bundled OFL fonts, so no live data, wallet address or key can appear.
//
// The banner and the hero GIF show six different views, one per theme (Map in
// Chain colours, Ring in Candy brutal, Bubbles in Riso zine, Calendar in
// Heatmap, Flow in Pixel, Atlas map in Acid). Their Mac screenshots come from
// MacScreenRenderTests; from native/AddressAtlasMac:
//
//   ATLAS_WRITE_SCREENSHOTS=1 swift test --filter MacScreenRenderTests
//
//   (writes portfolio-ring-candy, -calendar-heatmap, -flow-pixel and
//   -atlas-map-acid next to the older portfolio-map-* files)
//
// From the repository root:
//
//   swiftc -O docs/assets/make-readme-images.swift -o /tmp/make-readme-images
//   /tmp/make-readme-images . /tmp/readme-images all
//
// Targets: banner, frames, themes, views, phones, coin, all. Then copy:
//   banner.png      -> docs/assets/github-social-preview.png
//   views.png       -> docs/assets/views-14.png
//   phones.png      -> docs/assets/iphone-themes.png
//   coin-widgets.png -> docs/assets/coin-widgets.png
//   theme-<id>.png  -> docs/assets/themes/ (chain-colours, candy-brutal,
//                      riso-zine, heatmap, pixel, acid)
// and build the animated GIF from the six frames (1.8 s each, per-frame palette; leave out
// `diff_mode=rectangle`, which left a wrong-coloured strip under one frame):
//
//   ffmpeg -framerate 1/1.8 -i /tmp/readme-images/frame-%d.png \
//     -vf "split[a][b];[a]palettegen=stats_mode=single[p];[b][p]paletteuse=new=1:dither=none" \
//     -loop 0 -fps_mode vfr docs/assets/hero-themes.gif

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 4 else {
  FileHandle.standardError.write(Data("usage: make-readme-images <repo-root> <out-dir> <what>\n".utf8))
  exit(2)
}
let root = args[1]
let outDir = args[2]
let what = args[3]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let macShots = root + "/docs/design/screenshots/phase3/mac/"
let iosShots = root + "/docs/design/screenshots/phase3/ios/"
let chartShots = root + "/docs/design/screenshots/phase2/"
let fontDir = root + "/native/AddressAtlasMac/Sources/AddressAtlasMac/Fonts/"

// MARK: Helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
  CGColor(
    colorSpace: sRGB,
    components: [
      CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
    ])!
}

func loadImage(_ path: String) -> CGImage {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
  else { fatalError("cannot load \(path)") }
  return img
}

/// Opaque canvas with a top-left origin.
func makeCanvas(_ w: Int, _ h: Int, background: CGColor) -> CGContext {
  let ctx = CGContext(
    data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.setFillColor(background)
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.translateBy(x: 0, y: CGFloat(h))
  ctx.scaleBy(x: 1, y: -1)
  ctx.interpolationQuality = .high
  ctx.setShouldAntialias(true)
  return ctx
}

func savePNG(_ ctx: CGContext, _ name: String) {
  let url = URL(fileURLWithPath: outDir + "/" + name)
  guard let img = ctx.makeImage(),
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
  else { fatalError("cannot write \(name)") }
  CGImageDestinationAddImage(dest, img, nil)
  guard CGImageDestinationFinalize(dest) else { fatalError("cannot finalize \(name)") }
  print("wrote \(name) \(ctx.width)x\(ctx.height)")
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
  CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Draws `src` (top-left pixel rect, nil for all) into `dst`, optionally rounded.
func draw(_ ctx: CGContext, _ image: CGImage, src: CGRect? = nil, dst: CGRect, radius: CGFloat = 0) {
  ctx.saveGState()
  if radius > 0 {
    ctx.addPath(roundedPath(dst, radius))
    ctx.clip()
  }
  let piece = src.map { image.cropping(to: $0)! } ?? image
  ctx.translateBy(x: dst.minX, y: dst.maxY)
  ctx.scaleBy(x: 1, y: -1)
  ctx.interpolationQuality = .high
  ctx.draw(piece, in: CGRect(x: 0, y: 0, width: dst.width, height: dst.height))
  ctx.restoreGState()
}

/// Source rect of `image` that fills an aspect ratio, centred (cover fit).
func coverRect(_ image: CGImage, aspect: CGFloat, anchorTop: Bool = false) -> CGRect {
  let w = CGFloat(image.width), h = CGFloat(image.height)
  if w / h > aspect {
    let nw = h * aspect
    return CGRect(x: (w - nw) / 2, y: 0, width: nw, height: h)
  }
  let nh = w / aspect
  return CGRect(x: 0, y: anchorTop ? 0 : (h - nh) / 2, width: w, height: nh)
}

func fillRounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ color: CGColor) {
  ctx.setFillColor(color)
  ctx.addPath(roundedPath(rect, radius))
  ctx.fillPath()
}

func strokeRounded(_ ctx: CGContext, _ rect: CGRect, _ radius: CGFloat, _ color: CGColor, _ width: CGFloat) {
  ctx.setStrokeColor(color)
  ctx.setLineWidth(width)
  ctx.addPath(roundedPath(rect.insetBy(dx: width / 2, dy: width / 2), radius))
  ctx.strokePath()
}

// MARK: Fonts (the app's own bundled, OFL-licensed faces)

func variableFont(_ file: String, size: CGFloat, weight: CGFloat, opticalSize: CGFloat? = nil) -> CTFont {
  let url = URL(fileURLWithPath: fontDir + file)
  guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
    var descriptor = descriptors.first
  else { fatalError("cannot load font \(file)") }
  descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, 0x7767_6874 as CFNumber, weight)  // wght
  if let opticalSize {
    descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, 0x6F70_737A as CFNumber, opticalSize)  // opsz
  }
  return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

func staticFont(_ file: String, size: CGFloat) -> CTFont {
  let url = URL(fileURLWithPath: fontDir + file)
  guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
    let descriptor = descriptors.first
  else { fatalError("cannot load font \(file)") }
  return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

enum Align { case left, center, right }

func textLine(_ text: String, font: CTFont, color: CGColor, kern: CGFloat = 0) -> CTLine {
  let attrs =
    [
      kCTFontAttributeName: font,
      kCTForegroundColorAttributeName: color,
      kCTKernAttributeName: kern,
    ] as CFDictionary
  return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attrs))
}

func textWidth(_ text: String, font: CTFont, kern: CGFloat = 0) -> CGFloat {
  CGFloat(CTLineGetTypographicBounds(textLine(text, font: font, color: rgb(0)), nil, nil, nil))
}

/// Draws text with its baseline at y (top-left canvas). Returns the width.
@discardableResult
func drawText(
  _ ctx: CGContext, _ text: String, x: CGFloat, baseline: CGFloat, font: CTFont, color: CGColor,
  kern: CGFloat = 0, align: Align = .left
) -> CGFloat {
  let line = textLine(text, font: font, color: color, kern: kern)
  let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  let originX: CGFloat
  switch align {
  case .left: originX = x
  case .center: originX = x - width / 2
  case .right: originX = x - width
  }
  ctx.saveGState()
  ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
  ctx.textPosition = CGPoint(x: originX, y: baseline)
  CTLineDraw(line, ctx)
  ctx.restoreGState()
  return width
}

func glow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: UInt32, alpha: CGFloat) {
  let gradient = CGGradient(
    colorsSpace: sRGB, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
  ctx.drawRadialGradient(
    gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// MARK: Themes

struct Theme {
  let id: String
  let name: String
  let pill: UInt32
  let pillText: UInt32
  var label: UInt32? = nil
  var mac: String { macShots + "portfolio-map-\(id).png" }
}

let themes = [
  Theme(id: "chainColors", name: "Chain colours", pill: 0x627E_EA, pillText: 0xFFFFFF, label: 0x8FA3_FF),
  Theme(id: "candy", name: "Candy brutal", pill: 0xFF9E_CF, pillText: 0x111111),
  Theme(id: "riso", name: "Riso zine", pill: 0xFFE8_00, pillText: 0x1B2A6B),
  Theme(id: "heatmap", name: "Heatmap", pill: 0xF793_1A, pillText: 0x111111),
  Theme(id: "pixel", name: "Pixel", pill: 0x3B5B_FF, pillText: 0xFFFFFF, label: 0x7C90_FF),
  Theme(id: "acid", name: "Acid", pill: 0xC6F4_32, pillText: 0x111111),
]

let panel: UInt32 = 0x0D0E12
let cream: UInt32 = 0xFFF7EA

// The Mac screenshots are 1600x1613; this crop keeps the sidebar, total, view
// tabs and the map, and drops the holdings list. The theme thumbnails use it.
let windowCrop = CGRect(x: 0, y: 0, width: 1600, height: 1174)

// The hero GIF window is 1220 source pixels tall so the tallest chart (Flow) fits whole.
// Each frame is cut in the gap under its own chart card (`Showcase.frameCut`) and the
// last rows of background are stretched down to the common height, so no frame cuts
// through the Holdings heading or its first row.
let frameCrop = CGRect(x: 0, y: 0, width: 1600, height: 1220)

// MARK: Showcase: one view per theme

/// The banner and the hero GIF show six different views in six different
/// themes, each rendered from the same synthetic portfolio on the Mac
/// Portfolio screen. `file` is in docs/design/screenshots/phase3/mac/;
/// `chartTop` is where the banner tile's crop starts (source pixels), found by
/// looking at each screenshot so the whole chart is inside the tile.
struct Showcase {
  let themeIndex: Int
  let view: String
  let file: String
  let chartTop: CGFloat
  /// Where the hero GIF frame is cut: in the gap under the chart card, above "Holdings".
  let frameCut: CGFloat
  /// Horizontal crop of the banner tile (source pixels); Flow needs a wider one to keep its last node.
  var cropX: CGFloat = 285
  var cropW: CGFloat = 1305
  var theme: Theme { themes[themeIndex] }
  var path: String { macShots + file }
  var caption: String { "\(theme.name) \u{00B7} \(view)" }
}

let showcase = [
  Showcase(themeIndex: 0, view: "Map", file: "portfolio-map-chainColors.png", chartTop: 584, frameCut: 1172),
  Showcase(themeIndex: 1, view: "Ring", file: "portfolio-ring-candy.png", chartTop: 572, frameCut: 1166),
  Showcase(themeIndex: 2, view: "Bubbles", file: "portfolio-bubbles-riso.png", chartTop: 590, frameCut: 1184),
  Showcase(themeIndex: 3, view: "Calendar", file: "portfolio-calendar-heatmap.png", chartTop: 592, frameCut: 1080),
  Showcase(themeIndex: 4, view: "Flow", file: "portfolio-flow-pixel.png", chartTop: 588, frameCut: 1218, cropX: 273, cropW: 1327),
  Showcase(themeIndex: 5, view: "Atlas map", file: "portfolio-atlas-map-acid.png", chartTop: 596, frameCut: 1184),
]

/// Banner order, row by row: the two dark themes sit diagonally.
let bannerOrder = [0, 3, 1, 4, 5, 2]

// MARK: Banner (also the social preview)

func makeBanner() {
  let w = 1280, h = 640
  let ctx = makeCanvas(w, h, background: rgb(panel))
  glow(ctx, center: CGPoint(x: 1120, y: 90), radius: 520, color: 0xFF4F_A3, alpha: 0.30)
  glow(ctx, center: CGPoint(x: 700, y: 640), radius: 520, color: 0xC6F4_32, alpha: 0.16)
  glow(ctx, center: CGPoint(x: 80, y: 40), radius: 420, color: 0x627E_EA, alpha: 0.22)

  // Right: a 2x3 grid of six different views, each in its own theme, with a
  // small "View · Theme" label under every tile.
  let gridX: CGFloat = 484, gap: CGFloat = 14, rowGap: CGFloat = 12
  let tileW: CGFloat = (CGFloat(w) - 36 - gridX - gap) / 2
  let tileH: CGFloat = 186, labelH: CGFloat = 24
  let gridY: CGFloat = (CGFloat(h) - (3 * tileH + 2 * rowGap)) / 2
  let labelFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 14, weight: 700)
  for (slot, index) in bannerOrder.enumerated() {
    let item = showcase[index]
    let col = slot % 2, row = slot / 2
    let tile = CGRect(
      x: gridX + CGFloat(col) * (tileW + gap), y: gridY + CGFloat(row) * (tileH + rowGap), width: tileW, height: tileH)
    let imageRect = CGRect(x: tile.minX, y: tile.minY, width: tileW, height: tileH - labelH)
    fillRounded(ctx, tile.offsetBy(dx: 0, dy: 6), 14, rgb(0x000000, 0.35))
    ctx.saveGState()
    ctx.addPath(roundedPath(tile, 14))
    ctx.clip()
    ctx.setFillColor(rgb(0x15171E))
    ctx.fill(tile)
    // The chart part of the Mac screenshot (1600x1613), cropped at the tile aspect.
    draw(
      ctx, loadImage(item.path),
      src: CGRect(x: item.cropX, y: item.chartTop, width: item.cropW, height: item.cropW * imageRect.height / imageRect.width),
      dst: imageRect)
    ctx.restoreGState()
    strokeRounded(ctx, tile, 14, rgb(0xFFFFFF, 0.14), 1.5)

    // Label: theme colour dot, view name, theme name.
    let baseline = tile.maxY - 8
    ctx.setFillColor(rgb(item.theme.pill))
    ctx.fillEllipse(in: CGRect(x: tile.minX + 12, y: baseline - 10, width: 9, height: 9))
    var x = tile.minX + 28
    x += drawText(ctx, item.view, x: x, baseline: baseline, font: labelFont, color: rgb(cream))
    x += 7
    x += drawText(ctx, "\u{00B7}", x: x, baseline: baseline, font: labelFont, color: rgb(0xFFFFFF, 0.45))
    x += 7
    drawText(
      ctx, item.theme.name, x: x, baseline: baseline, font: labelFont, color: rgb(item.theme.label ?? item.theme.pill))
  }

  // Left: icon, title, tagline, counts.
  let icon = loadImage(root + "/native/AddressAtlasMac/Resources/AppIcon.png")
  let iconRect = CGRect(x: 64, y: 58, width: 84, height: 84)
  draw(ctx, icon, dst: iconRect, radius: 20)
  strokeRounded(ctx, iconRect, 20, rgb(0xFFFFFF, 0.18), 1.5)

  var titleSize: CGFloat = 112
  var titleFont = variableFont("BricolageGrotesque/BricolageGrotesque-Variable.ttf", size: titleSize, weight: 800, opticalSize: 96)
  while textWidth("Address", font: titleFont, kern: -3) > 392 {
    titleSize -= 2
    titleFont = variableFont("BricolageGrotesque/BricolageGrotesque-Variable.ttf", size: titleSize, weight: 800, opticalSize: 96)
  }
  drawText(ctx, "Address", x: 60, baseline: 258, font: titleFont, color: rgb(cream), kern: -3)
  drawText(ctx, "Atlas", x: 60, baseline: 258 + titleSize * 0.92, font: titleFont, color: rgb(0xC6F4_32), kern: -3)

  let taglineFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 26, weight: 500)
  drawText(ctx, "A read-only crypto portfolio", x: 66, baseline: 430, font: taglineFont, color: rgb(0xE8E2D5))
  drawText(ctx, "for Mac and iPhone.", x: 66, baseline: 464, font: taglineFont, color: rgb(0xE8E2D5))

  // Count chips in four theme colours, two rows.
  let chipFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 18, weight: 700)
  let chipRows: [[(String, UInt32)]] = [
    [("20 networks", 0xFF9E_CF), ("3 exchanges", 0xC6F4_32)],
    [("6 themes", 0x8FD3_FF), ("14 views", 0xFFE8_00)],
  ]
  for (rowIndex, chips) in chipRows.enumerated() {
    var chipX: CGFloat = 66
    let chipY: CGFloat = 498 + CGFloat(rowIndex) * 48
    for (label, color) in chips {
      let tw = textWidth(label, font: chipFont)
      let rect = CGRect(x: chipX, y: chipY, width: tw + 28, height: 38)
      fillRounded(ctx, rect, 19, rgb(color))
      drawText(ctx, label, x: rect.midX, baseline: chipY + 25.5, font: chipFont, color: rgb(0x111111), align: .center)
      chipX += rect.width + 10
    }
  }

  savePNG(ctx, "banner.png")
}

// MARK: Theme frames (GIF) and thumbnails

func themeCaptionBar(_ ctx: CGContext, canvasW: CGFloat, y: CGFloat, height: CGFloat, item: Showcase) {
  ctx.setFillColor(rgb(panel))
  ctx.fill(CGRect(x: 0, y: y, width: canvasW, height: height))
  let theme = item.theme, themeIndex = item.themeIndex
  let nameFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 26, weight: 800)
  let tw = textWidth(item.caption, font: nameFont)
  let pillRect = CGRect(x: 28, y: y + (height - 42) / 2, width: tw + 40, height: 42)
  fillRounded(ctx, pillRect, 21, rgb(theme.pill))
  drawText(
    ctx, item.caption, x: pillRect.midX, baseline: pillRect.minY + 29, font: nameFont, color: rgb(theme.pillText),
    align: .center)

  // Six dots, the current one filled in the theme colour.
  let dotsCenterX = canvasW / 2 + 40
  for index in 0..<6 {
    let cx = dotsCenterX + CGFloat(index - 3) * 30 + 15
    let r: CGFloat = index == themeIndex ? 8 : 5.5
    ctx.setFillColor(index == themeIndex ? rgb(theme.pill) : rgb(0xFFFFFF, 0.28))
    ctx.fillEllipse(in: CGRect(x: cx - r, y: y + height / 2 - r, width: r * 2, height: r * 2))
  }

  let hintFont = staticFont("GeistMono/GeistMono-Variable.ttf", size: 20)
  drawText(
    ctx, "Settings \u{2192} Theme", x: canvasW - 28, baseline: y + height / 2 + 7, font: hintFont,
    color: rgb(0xFFFFFF, 0.55), align: .right)
}

func makeFrames() {
  // Laid out on a 1000x800 logical canvas and rendered at 1.28x.
  let scale: CGFloat = 1.28
  // Each frame is a different view in a different theme (see `showcase`).
  let logicalW: CGFloat = 1000, bar: CGFloat = 66
  let shotH = logicalW * frameCrop.height / frameCrop.width
  for (index, item) in showcase.enumerated() {
    let ctx = makeCanvas(Int(logicalW * scale), Int((shotH + bar) * scale), background: rgb(panel))
    ctx.scaleBy(x: scale, y: scale)
    let image = loadImage(item.path)
    let drawn = logicalW * item.frameCut / frameCrop.width
    draw(
      ctx, image, src: CGRect(x: 0, y: 0, width: frameCrop.width, height: item.frameCut),
      dst: CGRect(x: 0, y: 0, width: logicalW, height: drawn))
    if drawn < shotH {
      // Stretch the last rows (sidebar, its edge line and the page background) down to the common height.
      draw(
        ctx, image, src: CGRect(x: 0, y: item.frameCut - 5, width: frameCrop.width, height: 4),
        dst: CGRect(x: 0, y: drawn - 0.5, width: logicalW, height: shotH - drawn + 0.5))
    }
    themeCaptionBar(ctx, canvasW: logicalW, y: shotH, height: bar, item: item)
    savePNG(ctx, "frame-\(index).png")
  }
}

func makeThemeThumbs() {
  let w = 560
  let h = Int((CGFloat(w) * windowCrop.height / windowCrop.width).rounded())
  for theme in themes {
    let ctx = makeCanvas(w, h, background: rgb(panel))
    draw(ctx, loadImage(theme.mac), src: windowCrop, dst: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    savePNG(ctx, "theme-\(theme.id).png")
  }
}

// MARK: Views mosaic

struct ViewTile {
  let title: String
  let file: String
}

let viewTiles = [
  ViewTile(title: "Map", file: "map-candy-light-full.png"),
  ViewTile(title: "Ring", file: "ring-heatmap-dark-full.png"),
  ViewTile(title: "Strip", file: "strip-candy-light-full.png"),
  ViewTile(title: "Grid", file: "grid-pixel-light-full.png"),
  ViewTile(title: "Bubbles", file: "bubbles-riso-light-full.png"),
  ViewTile(title: "Rings in rings", file: "ringsInRings-chainColors-light-full.png"),
  ViewTile(title: "List", file: "list-heatmap-dark-full.png"),
  ViewTile(title: "Flow", file: "flow-candy-light-full.png"),
  ViewTile(title: "Atlas map", file: "atlas-map-heatmap-dark-full.png"),
  ViewTile(title: "Over time", file: "over-time-chainColors-light-full.png"),
  ViewTile(title: "What changed", file: "what-changed-candy-light-full.png"),
  ViewTile(title: "Slope", file: "slope-chainColors-light-compact.png"),
  ViewTile(title: "Concentration", file: "concentration-chainColors-light-full.png"),
  ViewTile(title: "Calendar", file: "calendar-chainColors-light-full.png"),
]

func makeViewsMosaic() {
  let cols = 4
  let margin: CGFloat = 22, gap: CGFloat = 14
  let tileW: CGFloat = 280, tileH: CGFloat = 187, labelH: CGFloat = 38
  let rows = 4
  let w = Int(2 * margin + CGFloat(cols) * tileW + CGFloat(cols - 1) * gap)
  let h = Int(2 * margin + CGFloat(rows) * (tileH + labelH) + CGFloat(rows - 1) * gap)
  let scale: CGFloat = 1.6  // logical units to pixels, for sharp tiles on high-density screens
  let ctx = makeCanvas(Int(CGFloat(w) * scale), Int(CGFloat(h) * scale), background: rgb(panel))
  ctx.scaleBy(x: scale, y: scale)
  let labelFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 22, weight: 700)
  let numberFont = staticFont("GeistMono/GeistMono-Variable.ttf", size: 18)

  func cell(_ index: Int) -> CGRect {
    CGRect(
      x: margin + CGFloat(index % cols) * (tileW + gap), y: margin + CGFloat(index / cols) * (tileH + labelH + gap),
      width: tileW, height: tileH)
  }

  for (index, tile) in viewTiles.enumerated() {
    let rect = cell(index)
    let image = loadImage(chartShots + tile.file)
    draw(ctx, image, src: coverRect(image, aspect: tileW / tileH), dst: rect, radius: 12)
    strokeRounded(ctx, rect, 12, rgb(0xFFFFFF, 0.14), 1.5)
    let numberWidth = drawText(
      ctx, String(format: "%02d", index + 1), x: rect.minX + 2, baseline: rect.maxY + 27, font: numberFont,
      color: rgb(0xFFFFFF, 0.45))
    drawText(
      ctx, tile.title, x: rect.minX + 2 + numberWidth + 10, baseline: rect.maxY + 28, font: labelFont, color: rgb(cream))
  }

  // Last cell, double width: the group-by choice that most views share.
  let last = cell(14)
  let wide = CGRect(x: last.minX, y: last.minY, width: tileW * 2 + gap, height: tileH)
  fillRounded(ctx, wide, 12, rgb(0x1A1C23))
  strokeRounded(ctx, wide, 12, rgb(0xFFFFFF, 0.14), 1.5)
  let headFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 26, weight: 800)
  drawText(ctx, "Group by", x: wide.minX + 24, baseline: wide.minY + 44, font: headFont, color: rgb(cream))
  let groupFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 20, weight: 700)
  let groups: [(String, UInt32)] = [
    ("Asset", 0xFFE8_00), ("Network", 0x8FD3_FF), ("Wallet or exchange", 0xFF9E_CF), ("State", 0xC6F4_32),
    ("Type", 0xF793_1A),
  ]
  var gx = wide.minX + 24, gy = wide.minY + 64
  for (label, color) in groups {
    let tw = textWidth(label, font: groupFont)
    if gx + tw + 28 > wide.maxX - 20 {
      gx = wide.minX + 24
      gy += 46
    }
    let chip = CGRect(x: gx, y: gy, width: tw + 28, height: 36)
    fillRounded(ctx, chip, 18, rgb(color))
    drawText(ctx, label, x: chip.midX, baseline: chip.minY + 25, font: groupFont, color: rgb(0x111111), align: .center)
    gx += chip.width + 10
  }
  let noteFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 17, weight: 500)
  drawText(
    ctx, "Most views regroup the same holdings this way.", x: wide.minX + 24, baseline: wide.maxY - 16, font: noteFont,
    color: rgb(0xFFFFFF, 0.6))

  savePNG(ctx, "views.png")
}

// MARK: iPhone strip

/// Six iPhone screens, one view per theme, from the Debug-only demo fixture in the
/// simulator (iPhone 17 Pro, status bar 9:41, page scrolled 330 points so the chart is
/// in view). They are 603x1311, half of the simulator's pixels. To render them again:
///
///   native/AddressAtlasiOS/generate-project.sh && native/AddressAtlasiOS/build-ios-app.sh --simulator --unsigned
///   xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged --batteryLevel 100 \
///     --cellularMode notSupported --wifiMode active --wifiBars 3
///   SIMCTL_CHILD_ADDRESS_ATLAS_UI_LOCALE=en_US xcrun simctl launch --terminate-running-process <udid> \
///     com.addressatlas.ios -AtlasDemoFixture full -display.theme.v1 <theme> -display.appearanceMode.v1 <light|dark> \
///     -display.portfolioVisualization.v1 <view> -AtlasDemoScrollY 330
///   xcrun simctl io <udid> screenshot out.png     # then halve it, e.g. sips -z 1311 603
let phoneShots: [(themeIndex: Int, view: String, file: String)] = [
  (0, "Map", "readme-portfolio-chainColors-light-map.png"),
  (1, "Ring", "readme-portfolio-candy-light-ring.png"),
  (2, "Bubbles", "readme-portfolio-riso-light-bubbles.png"),
  (3, "Over time", "readme-portfolio-heatmap-dark-over-time.png"),
  (4, "Flow", "readme-portfolio-pixel-light-flow.png"),
  (5, "Atlas map", "readme-portfolio-acid-dark-atlas-map.png"),
]

func makePhoneStrip() {
  let margin: CGFloat = 26, gap: CGFloat = 20
  let phoneW: CGFloat = 270
  let phoneH = phoneW * 1311 / 603  // the whole screen, status bar to tab bar
  let w = Int(2 * margin + 6 * phoneW + 5 * gap)
  let h = Int(2 * margin + phoneH + 58)
  let scale: CGFloat = 1.25
  let ctx = makeCanvas(Int(CGFloat(w) * scale), Int(CGFloat(h) * scale), background: rgb(panel))
  ctx.scaleBy(x: scale, y: scale)
  let nameFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 22, weight: 800)
  let viewFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 18, weight: 600)
  for (index, shot) in phoneShots.enumerated() {
    let x = margin + CGFloat(index) * (phoneW + gap)
    let rect = CGRect(x: x, y: margin, width: phoneW, height: phoneH)
    draw(ctx, loadImage(iosShots + shot.file), dst: rect, radius: 36)
    strokeRounded(ctx, rect, 36, rgb(0xFFFFFF, 0.2), 2)
    let theme = themes[shot.themeIndex]
    drawText(ctx, theme.name, x: rect.midX, baseline: rect.maxY + 28, font: nameFont, color: rgb(theme.label ?? theme.pill), align: .center)
    drawText(ctx, shot.view, x: rect.midX, baseline: rect.maxY + 52, font: viewFont, color: rgb(cream, 0.75), align: .center)
  }
  savePNG(ctx, "phones.png")
}

// MARK: Coin detail

/// The five coin widgets on the ATOM detail screen (Candy brutal, Mac).
func makeCoinWidgets() {
  let w = 880
  let source = CGRect(x: 290, y: 270, width: 1300, height: 1720)
  let h = Int((CGFloat(w) * source.height / source.width).rounded())
  let ctx = makeCanvas(w, h, background: rgb(cream))
  draw(ctx, loadImage(macShots + "coin-atom-candy.png"), src: source, dst: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
  savePNG(ctx, "coin-widgets.png")
}

switch what {
case "coin": makeCoinWidgets()
case "banner": makeBanner()
case "frames": makeFrames()
case "themes": makeThemeThumbs()
case "views": makeViewsMosaic()
case "phones": makePhoneStrip()
case "all":
  makeCoinWidgets()
  makeBanner()
  makeFrames()
  makeThemeThumbs()
  makeViewsMosaic()
  makePhoneStrip()
default:
  FileHandle.standardError.write(Data("unknown target \(what)\n".utf8))
  exit(2)
}
