// Stat tiles, as the dashboards draw them (Usage, Server, a session's Resources), the Mac's StatTiles in system text styles:
// the label, the figure, a gauge when the figure is a share of something, and the line under it. The values and a gauge's
// tone are Core's `StatTile`.
import SwiftUI

/// Tiles two across.
struct StatTiles: View {
    var tiles: [StatTile]
    /// A tone for a tile's figure, by tile id (CI/CD's success rate); the rest are in the primary colour.
    var valueTones: [String: RowTone] = [:]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(tiles) { StatTileView(tile: $0, valueTone: valueTones[$0.id]) }
        }
    }
}

struct StatTileView: View {
    var tile: StatTile
    var valueTone: RowTone? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(tile.value).font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(valueTone.map { Theme.color($0) } ?? .primary).lineLimit(1).minimumScaleFactor(0.6)
            if let fraction = tile.fraction { StatGauge(fraction: fraction, color: Theme.color(tile.tone)) }
            Text(tile.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(Theme.raise, in: RoundedRectangle(cornerRadius: BriareusRadius.xxl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BriareusRadius.xxl, style: .continuous).stroke(Theme.line, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// A thin bar filled to `fraction` of its width.
struct StatGauge: View {
    var fraction: Double
    var color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.line)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
