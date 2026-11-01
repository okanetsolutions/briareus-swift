// Stat tiles, as the dashboards draw them (📊 Usage, ▤ Server, a session's Resources, CI/CD): the label, the figure, a gauge when
// the figure is a share of something, and the line under it. The values and a gauge's tone are Core's `StatTile`.
import SwiftUI

/// A row of tiles four across, two on a narrow pane; `width` is the pane's.
struct StatTiles: View {
    var width: CGFloat
    var tiles: [StatTile]
    /// A tone for a tile's figure, by tile id (CI/CD's success rate); the rest are in ink.
    var valueTones: [String: RowTone] = [:]
    var body: some View {
        let cols = width >= 640 ? 4 : 2
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(stride(from: 0, to: tiles.count, by: cols)), id: \.self) { start in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(0..<cols, id: \.self) { k in
                        if start + k < tiles.count {
                            StatTileView(tile: tiles[start + k], valueTone: valueTones[tiles[start + k].id])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatTileView: View {
    var tile: StatTile
    var valueTone: RowTone? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tile.label).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            Text(tile.value).font(Theme.stat).foregroundStyle(valueTone.map { Theme.color($0) } ?? Theme.ink).lineLimit(1).truncationMode(.tail).padding(.top, 4)
            if let fraction = tile.fraction {
                StatGauge(fraction: fraction, color: Theme.color(tile.tone)).padding(.top, 6)
            }
            Text(tile.detail).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: BriareusRadius.xxl).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: BriareusRadius.xxl).strokeBorder(Theme.line, lineWidth: 1))
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
