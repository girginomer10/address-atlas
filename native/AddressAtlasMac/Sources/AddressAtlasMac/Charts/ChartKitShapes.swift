import SwiftUI

// MARK: - Shapes

/// A ring segment between two radii and two angles (radians, clockwise from
/// 12 o'clock), centred in its frame. The same shape draws, outlines, and
/// hit-tests a segment, so hover and tap follow the visible arc.
struct ChartKitDonutSegment: Shape {
  var arc: ChartKitArc
  var innerRadius: CGFloat
  var outerRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    let centre = CGPoint(x: rect.midX, y: rect.midY)
    guard arc.span > 0, outerRadius > innerRadius, outerRadius > 0 else { return Path() }
    // Angles in SwiftUI's drawing space start at 3 o'clock; ours at 12.
    let start = Angle.radians(arc.start - .pi / 2)
    let end = Angle.radians(arc.end - .pi / 2)
    var path = Path()
    if arc.span >= 2 * .pi - 1e-9 {
      // A whole ring is two circles, so no radial seam is drawn or stroked.
      path.addArc(
        center: centre, radius: outerRadius, startAngle: .zero, endAngle: .degrees(360),
        clockwise: false)
      path.closeSubpath()
      path.addArc(
        center: centre, radius: max(innerRadius, 0), startAngle: .zero,
        endAngle: .degrees(360), clockwise: true)
      path.closeSubpath()
      return path
    }
    path.addArc(
      center: centre, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
    path.addArc(
      center: centre, radius: max(innerRadius, 0), startAngle: end, endAngle: start,
      clockwise: true)
    path.closeSubpath()
    return path
  }
}

/// A shape filled with a chart colour, with the theme's outline, overprint and
/// highlight. Ring segments, bubbles, strip segments and waffle cells all draw
/// through it, so a theme styles every mark the same way.
struct ChartKitMark<S: Shape>: View {
  var shape: S
  var fill: Color
  var style: ChartKitBlockStyle
  var isActive = false
  /// Overrides the theme's outline width, for marks too small for it.
  var borderWidth: CGFloat?

  var body: some View {
    let outline = borderWidth ?? style.borderWidth
    ZStack {
      shape.fill(fill).blendMode(style.multiplies ? .multiply : .normal)
      if outline > 0 {
        shape.stroke(style.borderColor, lineWidth: outline)
      }
      if isActive {
        shape.stroke(style.highlightColor, lineWidth: max(2, outline + 1))
      }
    }
    .accessibilityHidden(true)
  }
}
