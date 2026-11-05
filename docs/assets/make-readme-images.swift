// Composes the README images from the synthetic review screenshots in
// docs/design/screenshots. It reads only those PNGs, the app icon and the
// bundled OFL fonts, so no live data, wallet address or key can appear.
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
// and build the animated GIF from the six frames (1.8 s each, per-frame palette):
//
//   ffmpeg -framerate 1/1.8 -i /tmp/readme-images/frame-%d.png \
//     -vf "split[a][b];[a]palettegen=stats_mode=single[p];[b][p]paletteuse=new=1:dither=none:diff_mode=rectangle" \
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
// tabs and the map, and drops the holdings list.
let windowCrop = CGRect(x: 0, y: 0, width: 1600, height: 1174)

// MARK: Banner (also the GitHub social preview)

func makeBanner() {
  let w = 1280, h = 640
  let ctx = makeCanvas(w, h, background: rgb(panel))
  glow(ctx, center: CGPoint(x: 1120, y: 90), radius: 520, color: 0xFF4F_A3, alpha: 0.30)
  glow(ctx, center: CGPoint(x: 700, y: 640), radius: 520, color: 0xC6F4_32, alpha: 0.16)
  glow(ctx, center: CGPoint(x: 80, y: 40), radius: 420, color: 0x627E_EA, alpha: 0.22)

  // Right: a 2x3 grid of the map in each theme. The crops are fractions of the
  // 1600x1613 screenshot so they follow whatever the theme draws.
  let tileW: CGFloat = 276, tileH: CGFloat = 186, gap: CGFloat = 14
  let gridX: CGFloat = 676, gridY: CGFloat = (CGFloat(h) - (3 * tileH + 2 * gap)) / 2
  for (index, theme) in themes.enumerated() {
    let col = index % 2, row = index / 2
    let rect = CGRect(
      x: gridX + CGFloat(col) * (tileW + gap), y: gridY + CGFloat(row) * (tileH + gap), width: tileW, height: tileH)
    let image = loadImage(theme.mac)
    // Map region, found per theme in the screenshot.
    let source = bannerCrop(theme.id)
    fillRounded(ctx, rect.offsetBy(dx: 0, dy: 6), 16, rgb(0x000000, 0.35))
    draw(ctx, image, src: source, dst: rect, radius: 16)
    strokeRounded(ctx, rect, 16, rgb(0xFFFFFF, 0.14), 1.5)
  }

  // Left: icon, title, tagline, counts.
  let icon = loadImage(root + "/native/AddressAtlasMac/Resources/AppIcon.png")
  let iconRect = CGRect(x: 64, y: 58, width: 84, height: 84)
  draw(ctx, icon, dst: iconRect, radius: 20)
  strokeRounded(ctx, iconRect, 20, rgb(0xFFFFFF, 0.18), 1.5)

  var titleSize: CGFloat = 112
  var titleFont = variableFont("BricolageGrotesque/BricolageGrotesque-Variable.ttf", size: titleSize, weight: 800, opticalSize: 96)
  while textWidth("Address", font: titleFont, kern: -3) > 560 {
    titleSize -= 2
    titleFont = variableFont("BricolageGrotesque/BricolageGrotesque-Variable.ttf", size: titleSize, weight: 800, opticalSize: 96)
  }
  drawText(ctx, "Address", x: 60, baseline: 258, font: titleFont, color: rgb(cream), kern: -3)
  drawText(ctx, "Atlas", x: 60, baseline: 258 + titleSize * 0.92, font: titleFont, color: rgb(0xC6F4_32), kern: -3)

  let taglineFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 27, weight: 500)
  drawText(ctx, "A read-only crypto portfolio", x: 66, baseline: 440, font: taglineFont, color: rgb(0xE8E2D5))
  drawText(ctx, "for Mac and iPhone.", x: 66, baseline: 476, font: taglineFont, color: rgb(0xE8E2D5))

  // Count chips in four theme colours.
  let chipFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 19, weight: 700)
  let chips: [(String, UInt32)] = [
    ("20 networks", 0xFF9E_CF), ("3 exchanges", 0xC6F4_32), ("6 themes", 0x8FD3_FF), ("14 views", 0xFFE8_00),
  ]
  var chipX: CGFloat = 66
  for (label, color) in chips {
    let tw = textWidth(label, font: chipFont)
    let rect = CGRect(x: chipX, y: 522, width: tw + 28, height: 40)
    fillRounded(ctx, rect, 20, rgb(color))
    drawText(ctx, label, x: rect.midX, baseline: 548, font: chipFont, color: rgb(0x111111), align: .center)
    chipX += rect.width + 10
  }

  savePNG(ctx, "banner.png")
}

/// Tabs, map and the top of the holdings list of each Mac screenshot
/// (1600x1613), at the tile aspect.
func bannerCrop(_ id: String) -> CGRect {
  let aspect: CGFloat = 276.0 / 186.0
  return CGRect(x: 300, y: 572, width: 1300, height: 1300 / aspect)
}

// MARK: Theme frames (GIF) and thumbnails

func themeCaptionBar(_ ctx: CGContext, canvasW: CGFloat, y: CGFloat, height: CGFloat, themeIndex: Int) {
  ctx.setFillColor(rgb(panel))
  ctx.fill(CGRect(x: 0, y: y, width: canvasW, height: height))
  let theme = themes[themeIndex]
  let nameFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 26, weight: 800)
  let tw = textWidth(theme.name, font: nameFont)
  let pillRect = CGRect(x: 28, y: y + (height - 42) / 2, width: tw + 40, height: 42)
  fillRounded(ctx, pillRect, 21, rgb(theme.pill))
  drawText(
    ctx, theme.name, x: pillRect.midX, baseline: pillRect.minY + 29, font: nameFont, color: rgb(theme.pillText),
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
  let logicalW: CGFloat = 1000, shotH: CGFloat = 734, bar: CGFloat = 66
  for (index, theme) in themes.enumerated() {
    let ctx = makeCanvas(Int(logicalW * scale), Int((shotH + bar) * scale), background: rgb(panel))
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx, loadImage(theme.mac), src: windowCrop, dst: CGRect(x: 0, y: 0, width: logicalW, height: shotH))
    themeCaptionBar(ctx, canvasW: logicalW, y: shotH, height: bar, themeIndex: index)
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

let phoneShots: [(String, String)] = [
  ("chainColors", "portfolio-chainColors-light.png"),
  ("candy", "portfolio-candy-light.png"),
  ("riso", "portfolio-riso-light.png"),
  ("heatmap", "portfolio-heatmap-dark.png"),
  ("pixel", "portfolio-pixel-light.png"),
  ("acid", "portfolio-acid-dark.png"),
]

func makePhoneStrip() {
  let margin: CGFloat = 26, gap: CGFloat = 20
  let phoneW: CGFloat = 270
  let cropH: CGFloat = 1900  // of 2622: status bar to the start of the map
  let phoneH = phoneW * cropH / 1206
  let w = Int(2 * margin + 6 * phoneW + 5 * gap)
  let h = Int(2 * margin + phoneH + 44)
  let scale: CGFloat = 1.25
  let ctx = makeCanvas(Int(CGFloat(w) * scale), Int(CGFloat(h) * scale), background: rgb(panel))
  ctx.scaleBy(x: scale, y: scale)
  let nameFont = variableFont("PlusJakartaSans/PlusJakartaSans-Variable.ttf", size: 21, weight: 700)
  for (index, shot) in phoneShots.enumerated() {
    let x = margin + CGFloat(index) * (phoneW + gap)
    let rect = CGRect(x: x, y: margin, width: phoneW, height: phoneH)
    draw(ctx, loadImage(iosShots + shot.1), src: CGRect(x: 0, y: 0, width: 1206, height: cropH), dst: rect, radius: 30)
    strokeRounded(ctx, rect, 30, rgb(0xFFFFFF, 0.2), 2)
    let theme = themes.first { $0.id == shot.0 }!
    drawText(ctx, theme.name, x: rect.midX, baseline: rect.maxY + 32, font: nameFont, color: rgb(theme.label ?? theme.pill), align: .center)
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
