// A Markdown table in a reply, the Mac's MarkdownTable in system text styles: the header row tinted, a grid, each column's
// alignment, and Copy table above its right edge. The cells sit in `TableGrid`, which gives each cell its column's set
// width before measuring its height, so a long cell wraps inside its row instead of running over the rows below.
import SwiftUI

/// A table that scrolls sideways when wider than the screen, its header row tinted, with Copy table above its right edge
/// (copying it as Markdown, as the Mac's does). Each cell selects on its own: a long press copies it.
struct MarkdownTable: View {
    let block: MdBlock
    @State private var copied = false
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                Pasteboard.copy(Markdown.tableSource(block)); copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy table", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption).padding(.vertical, 2).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .accessibilityLabel(copied ? "Copied" : "Copy table as Markdown")
            ScrollView(.horizontal, showsIndicators: false) {
                TableGrid(columns: block.cols) {
                    ForEach(Array(block.cells.enumerated()), id: \.offset) { r, row in
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            let align = c < block.aligns.count ? block.aligns[c] : .left
                            Text(inlineMarkdown(cell)).font(.callout.weight(r == 0 ? .semibold : .regular))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: align == .right ? .trailing : align == .center ? .center : .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .background(r == 0 ? Theme.field : .clear)
                                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 0.5))
                        }
                    }
                }
                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
            }
            // A sideways ScrollView doesn't take its content's height on its own; this gives it the grid's measured height
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Cells laid out row by row, `columns` to a row (the parser pads every row to the table's columns). Each column is as wide as
/// its widest cell on one line, 48 to 296pt (a cell's 280pt of text and its padding); each row is as tall as its tallest
/// cell wrapped to its column's width, and every cell fills its row so the borders line up.
struct TableGrid: Layout {
    let columns: Int
    private static let minWidth: CGFloat = 48, maxWidth: CGFloat = 296

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (widths, heights) = measure(subviews)
        return CGSize(width: widths.reduce(0, +), height: heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (widths, heights) = measure(subviews)
        var y = bounds.minY
        for (r, height) in heights.enumerated() {
            var x = bounds.minX
            for c in 0..<columns {
                let i = r * columns + c
                guard i < subviews.count else { return }
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[c], height: height))
                x += widths[c]
            }
            y += height
        }
    }

    /// Each column's width and each row's height.
    private func measure(_ subviews: Subviews) -> ([CGFloat], [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        var widths = Array(repeating: Self.minWidth, count: columns)
        for (i, cell) in subviews.enumerated() {
            let natural = ceil(cell.sizeThatFits(.unspecified).width)
            widths[i % columns] = min(Self.maxWidth, max(widths[i % columns], natural))
        }
        let rows = (subviews.count + columns - 1) / columns
        var heights = Array(repeating: CGFloat(0), count: rows)
        for (i, cell) in subviews.enumerated() {
            let wrapped = cell.sizeThatFits(ProposedViewSize(width: widths[i % columns], height: nil)).height
            heights[i / columns] = max(heights[i / columns], ceil(wrapped))
        }
        return (widths, heights)
    }
}
