import AddressAtlasCore
import SwiftUI

/// Coins as rows in one card: mark, name and where it is held, amount, value.
/// Each row opens the coin's detail screen. Used by Portfolio (the largest few)
/// and Assets (all of them).
struct MacCoinList: View {
  var rows: [MacCoinRow]
  var showsHeader = false
  var onOpen: (String) -> Void

  var body: some View {
    Surface(padding: 0) {
      VStack(spacing: 0) {
        if showsHeader {
          header
          Divider().overlay(AtlasTheme.rule)
        }
        ForEach(rows) { row in
          MacCoinRowView(row: row, onOpen: onOpen)
          if row.id != rows.last?.id {
            Divider().overlay(AtlasTheme.ruleSoft)
          }
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 14) {
      TableHeader("Asset")
      TableHeader("Amount", alignment: .trailing, width: 120)
      TableHeader("Value", alignment: .trailing, width: 110)
      Color.clear.frame(width: 12)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 9)
    .background(AtlasTheme.surfaceMuted.opacity(0.5))
    .accessibilityHidden(true)
  }
}

struct MacCoinRowView: View {
  var row: MacCoinRow
  var onOpen: (String) -> Void

  var body: some View {
    MacRowButton(
      accessibilityLabel: row.spokenText,
      accessibilityIdentifier: "coin-row-\(row.id)",
      action: { onOpen(row.id) }
    ) {
      HStack(spacing: 14) {
        CoinMark(symbol: row.summary.symbol, size: 36)
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 8) {
            Text(row.summary.symbol)
              .font(AtlasTheme.font(.body, .body, weight: .semibold))
              .foregroundStyle(AtlasTheme.ink)
              .lineLimit(1)
            if row.name != row.summary.symbol {
              Text(row.name)
                .font(AtlasTheme.font(.body, .callout))
                .foregroundStyle(AtlasTheme.ink3)
                .lineLimit(1)
                .truncationMode(.tail)
            }
          }
          Text(row.whereText)
            .font(AtlasTheme.font(.label, .caption))
            .foregroundStyle(AtlasTheme.ink3)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        MacFigure(
          text: MacFormat.amount(row.summary.totalAmount), size: 13, color: AtlasTheme.ink2
        )
        .frame(width: 120, alignment: .trailing)
        VStack(alignment: .trailing, spacing: 3) {
          if row.isPriced {
            MacFigure(text: money(row.summary.valueUsd), size: 14, weight: .semibold)
            MacFigure(text: MacFormat.percent(row.share), size: 11, color: AtlasTheme.ink3)
          } else {
            MacBadge("No price", color: AtlasTheme.warning)
          }
        }
        .frame(width: 110, alignment: .trailing)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(AtlasTheme.ink3)
          .frame(width: 12)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(minHeight: 58)
    }
  }
}
