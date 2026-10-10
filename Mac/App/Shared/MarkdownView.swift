// Markdown as doc.c lays it out: paragraphs, headings, bullets and task lists, quotes, code with a copy button, tables and
// rules, with bold, italic, strikethrough, inline code and links inline. Its text selects across blocks (SelectableText.swift).
import AppKit
import SwiftUI

enum MarkdownSize {
    case body, callout, footnote, caption
    var size: CGFloat { switch self { case .body: return 15; case .callout: return 14; case .footnote: return 13; case .caption: return 12 } }
    var mono: CGFloat { self == .body || self == .callout ? 13 : 12 }
}

/// Inline Markdown as one attributed string: links in the accent, strikethrough muted, code in the mono font on the sunken colour.
func richText(_ source: String, size: MarkdownSize = .body, color: Color = Theme.ink, bold: Bool = false) -> AttributedString {
    var out = AttributedString()
    for span in Markdown.inline(source) {
        var a = AttributedString(span.text)
        var font: Font
        if span.flags.contains(.code) {
            font = .system(size: size.mono, design: .monospaced)
            a.backgroundColor = Theme.sunken
        } else {
            font = .system(size: size.size, weight: span.flags.contains(.bold) || bold ? .semibold : .regular)
            if span.flags.contains(.italic) { font = font.italic() }
        }
        a.font = font
        a.foregroundColor = span.flags.contains(.link) && span.url != nil ? Theme.accent : span.flags.contains(.strike) ? Theme.muted : color
        if span.flags.contains(.strike) { a.strikethroughStyle = .single }
        if span.flags.contains(.link), let url = span.url, let u = URL(string: url) { a.link = u }
        out += a
    }
    return out
}

/// Inline Markdown, wrapped and selectable with the rest of the page (`doc_rich`).
struct RichText: View {
    var source: String
    var size: MarkdownSize = .body
    var color: Color = Theme.ink
    var bold = false
    var body: some View {
        SelectableText(selectableRich(source, size: size, color: color, bold: bold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Block Markdown (`doc_markdown`); blocks 6px apart. Its texts select as one, and with the page's when it is on one.
struct MarkdownView: View {
    var source: String
    var size: MarkdownSize = .body
    @Environment(\.textSelectionGroup) private var pageSelection
    @State private var ownSelection = TextSelectionGroup()

    var body: some View {
        let blocks = Markdown.parse(source)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.textSelectionGroup, pageSelection ?? ownSelection)
    }

    @ViewBuilder private func block(_ b: MdBlock) -> some View {
        switch b.kind {
        case .paragraph:
            RichText(source: b.text, size: size)
        case .heading:
            HeadingText(text: b.text)
        case .bullet:
            HStack(alignment: .top, spacing: 0) {
                if b.task != .none {
                    TaskBox(checked: b.task == .checked).padding(.leading, 1).padding(.top, 2).frame(width: 22, alignment: .leading)
                } else {
                    // The marker takes its width and 8px, at least 18px.
                    Text(verbatim: b.marker ?? "\u{2022}").font(.system(size: size.size)).foregroundStyle(Theme.muted)
                        .padding(.trailing, 8).frame(minWidth: 18, alignment: .leading)
                }
                RichText(source: b.text, size: size, color: b.task == .checked ? Theme.muted : Theme.ink)
            }
            .padding(.leading, CGFloat(b.indent) * 16)
        case .quote:
            RichText(source: b.text, size: size, color: Theme.muted)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
        case .code:
            CodeBlock(language: b.language, code: b.text)
        case .rule:
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
        case .table:
            MarkdownTable(block: b, size: size)
        }
    }
}

/// A heading is the title3 size, semibold, whatever the base size, 6px further from what is above it.
private struct HeadingText: View {
    var text: String
    var body: some View {
        SelectableText(selectableRich(text, size: .body, font: SelectableFont.system(17, .semibold)))
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
    }
}

private struct TaskBox: View {
    var checked: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(checked ? Theme.accent : Theme.raise)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(checked ? Theme.accent : Theme.ink.opacity(0.35), lineWidth: 1))
            .overlay { if checked { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) } }
            .frame(width: 14, height: 14)
    }
}

/// A code block: its language over a line, the whole line copying the code, then the code, on the sunken colour.
struct CodeBlock: View {
    var language: String?
    var code: String
    @State private var copied = false
    @State private var hovered = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Clipboard.copy(code)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                HStack(spacing: 0) {
                    Text(verbatim: language?.isEmpty == false ? language! : "code").font(Theme.monoCaption2).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
                    Image(systemName: copied ? Glyph.symbol(0xE73E) : Glyph.symbol(0xE8C8)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.ink.opacity(0.06) : .clear))
                }
                .padding(.leading, 12).padding(.trailing, 6).frame(height: 25)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { on in
                hovered = on
                if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Copy")
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            SelectableText(expandTabs(code), font: SelectableFont.mono(13), color: Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 10)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// A table sized to its content: a header tint, a grid, and each column's alignment, with Copy table above its right edge
/// (copying it as Markdown). Each column takes its widest cell, at most 420px, and the columns narrow to fit the width
/// there is, wrapping their cells, before the table scrolls sideways. Each cell is a text of the page's selection, so a
/// drag selects across cells and copies them tab-separated, a line per row; links in cells open as they do elsewhere.
private struct MarkdownTable: View {
    var block: MdBlock
    var size: MarkdownSize
    @State private var available: CGFloat = 0
    private static let pad: CGFloat = 8, maxText: CGFloat = 420, minText: CGFloat = 80

    var body: some View {
        let cellSize: MarkdownSize = size == .body ? .callout : size
        let texts = block.cells.enumerated().map { r, row in
            row.enumerated().map { c, cell in
                cellText(cell, size: cellSize, bold: r == 0, align: c < block.aligns.count ? block.aligns[c] : .left)
            }
        }
        let widths = columnWidths(texts)
        ScrollView(.horizontal, showsIndicators: false) {
            // A table narrower than the button lets it run past its right edge, so the label is not clipped.
            VStack(alignment: .trailing, spacing: 2) {
                TableCopyButton(source: Markdown.tableSource(block))
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(texts.enumerated()), id: \.offset) { r, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { c, text in
                                let align = c < block.aligns.count ? block.aligns[c] : .left
                                // A set width, so each cell measures its height wrapped as it is drawn.
                                SelectableText(text, cell: true)
                                    .frame(width: c < widths.count ? widths[c] : Self.minText,
                                           alignment: align == .right ? .trailing : align == .center ? .center : .leading)
                                    .padding(.horizontal, Self.pad).padding(.vertical, 5)
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .background(r == 0 ? Theme.raise : .clear)
                                    .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 0.5))
                            }
                        }
                    }
                }
                .overlay(Rectangle().strokeBorder(Theme.line, lineWidth: 1))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }

    /// Each column's text width: its widest cell up to 420px; when they do not fit, the widest columns give way first,
    /// down to 80px each (or their own width, if less).
    private func columnWidths(_ texts: [[NSAttributedString]]) -> [CGFloat] {
        let count = texts.map(\.count).max() ?? 0
        var natural = Array(repeating: CGFloat(0), count: count)
        for row in texts {
            for (c, t) in row.enumerated() {
                let w = ceil(t.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading]).width) + 1
                natural[c] = max(natural[c], min(w, Self.maxText))
            }
        }
        natural = natural.map { max($0, 32) }
        let room = available - CGFloat(count) * Self.pad * 2
        guard available > 0, natural.reduce(0, +) > room else { return natural }
        // Fill evenly: columns narrower than an even share keep their width, the rest split what is left.
        var widths = natural, open = Set(0..<count), left = room
        while !open.isEmpty {
            let share = left / CGFloat(open.count)
            let fits = open.filter { natural[$0] <= share }
            if fits.isEmpty {
                for c in open { widths[c] = max(share, min(natural[c], Self.minText)) }
                break
            }
            for c in fits { widths[c] = natural[c]; left -= natural[c]; open.remove(c) }
        }
        return widths.map { floor($0) }
    }

    /// A cell's inline Markdown, aligned as its column.
    private func cellText(_ source: String, size: MarkdownSize, bold: Bool, align: MdAlignment) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: selectableRich(source, size: size, bold: bold))
        guard align != .left, text.length > 0 else { return text }
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.lineBreakMode = .byWordWrapping
        p.alignment = align == .right ? .right : .center
        text.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: text.length))
        return text
    }
}

/// Copy table: a copy glyph and its label in the caption size, tinted under the mouse (paint_table_copy).
private struct TableCopyButton: View {
    var source: String
    @State private var copied = false
    @State private var hovered = false
    var body: some View {
        Button {
            Clipboard.copy(source)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: copied ? Glyph.symbol(0xE73E) : Glyph.symbol(0xE8C8)).font(.system(size: 11)).frame(width: 18)
                Text(copied ? "Copied" : "Copy table").font(Theme.caption).lineLimit(1).fixedSize()
            }
            .foregroundStyle(Theme.muted)
            .padding(.leading, 4).padding(.trailing, 6).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.raise : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { on in
            hovered = on
            if on { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help("Copy the table as Markdown")
    }
}
