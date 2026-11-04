import SwiftUI

// MARK: - Labels
//
// The text drawn on and beside marks. Every label here is offered in several
// sizes, largest first, ending in an empty view, and `ViewThatFits` draws the
// first one that fits whole. It measures the real text (including Dynamic Type
// on iOS and a missing font), so a label is hidden rather than clipped,
// wrapped or squeezed.

/// "BTC · 57%": the name in the theme's label face and the share in its figure
/// face, so a pixel or all-capitals label face never has to draw a digit or a
/// percent sign.
struct ChartKitNameAndShare: View {
  @Environment(\.atlasTheme) private var tokens

  var name: String
  var share: Double
  var size: CGFloat
  var weight: Font.Weight = .semibold

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(name)
        .font(tokens.chartKitLabelFont(size, weight: weight))
      Text(" · " + ChartKitFormat.percent(share))
        .font(tokens.chartKitNumberFont(size, weight: weight))
    }
    .lineLimit(1)
    .fixedSize()
  }
}

/// The text inside a block: name and share on top, value at the bottom, with
/// every size from a big figure down to nothing offered in order.
struct ChartKitBlockLabel: View {
  @Environment(\.atlasTheme) private var tokens

  var name: String
  var share: Double
  var valueUsd: Double
  var ink: Color
  /// The block the label sits in, for scaling the figures.
  var size: CGSize
  var density: PortfolioChartDensity
  /// False to leave the value out (compact density, or a nested header).
  var showsValue = true

  var body: some View {
    let scale = max(0, min(size.width, size.height * 1.7))
    let nameSize = min(14, max(10.5, scale / 12))
    let valueSize = min(28, max(12, scale / 8))
    if showsValue {
      ViewThatFits {
        stacked(nameSize: nameSize, valueSize: valueSize)
        stacked(nameSize: nameSize, valueSize: valueSize * 0.72)
        stacked(nameSize: 10.5, valueSize: 11)
        shareLine(nameSize: nameSize)
        nameLine(nameSize: nameSize)
        nameLine(nameSize: 10)
        Color.clear.frame(width: 0, height: 0)
      }
    } else {
      ViewThatFits {
        shareLine(nameSize: nameSize)
        nameLine(nameSize: nameSize)
        nameLine(nameSize: 10)
        Color.clear.frame(width: 0, height: 0)
      }
    }
  }

  private func stacked(nameSize: CGFloat, valueSize: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ChartKitNameAndShare(name: name, share: share, size: nameSize)
      Spacer(minLength: 4)
      Text(ChartKitFormat.usd(valueUsd))
        .font(tokens.chartKitFigureFont(valueSize))
        .lineLimit(1)
        .fixedSize()
    }
    .foregroundStyle(ink)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func shareLine(nameSize: CGFloat) -> some View {
    ChartKitNameAndShare(name: name, share: share, size: nameSize)
      .foregroundStyle(ink)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func nameLine(nameSize: CGFloat) -> some View {
    Text(name)
      .font(tokens.chartKitLabelFont(nameSize, weight: .semibold))
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(ink)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}
