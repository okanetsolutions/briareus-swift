// The detail pane's header (pane.c refresh_header): the title and subtitle, the back button, the pills on the right,
// and the environment values that give it its back and pop-out actions.
import SwiftUI

/// A header button: a glyph alone, or a labelled pill when `label` is set and the header has room for the labels.
/// `prominent` fills it with the accent, as the Windows client's `.btn-primary` (Save).
struct HeaderButton: Identifiable {
    var id: String { label ?? glyph }
    var glyph: String           // an SF Symbol
    var label: String? = nil
    var tip: String? = nil
    var enabled = true
    var destructive = false
    var prominent = false
    var action: () -> Void
}

/// The pane's header: `px-[18px] py-2.5` around a 15px title and a 13px subtitle (with a status dot before it), the back
/// button when the pane can go back, a ✎ after the title when it can be renamed, and the `.btn` pills on the right.
struct PaneHeader: View {
    var title: String
    var subtitle: String? = nil
    var status: String? = nil
    var buttons: [HeaderButton] = []
    var titleAction: (() -> Void)? = nil
    var sidebar = false
    @Environment(\.paneBack) private var back
    @Environment(\.paneDetach) private var detach

    private var shownButtons: [HeaderButton] {
        guard let detach else { return buttons }
        return buttons + [HeaderButton(glyph: detach.glyph, tip: detach.tip, action: detach.action)]
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(labels: true)
            row(labels: false)
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        // pane.c refresh_header: a 40px title and subtitle, 32px buttons (or the back button), or a 22px title alone, plus
        // `py-2.5` and the border.
        .frame(minHeight: subtitle != nil ? 61 : !shownButtons.isEmpty || back != nil ? 53 : 43)
        .background(sidebar ? Theme.sidebar : Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func row(labels: Bool) -> some View {
        HStack(spacing: 8) {
            if let back {
                Button(action: back) { Text("‹").font(Theme.body) }.buttonStyle(IconButtonStyle())
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(title).font(Theme.headline).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    if let titleAction {
                        // `#btn-edit-title`: 8px either side of the ✎, from 2px after the title.
                        Button(action: titleAction) {
                            Text("✎").font(Theme.footnote).padding(.horizontal, 8).frame(height: 22).contentShape(Rectangle())
                        }
                        .buttonStyle(HoverInkStyle()).padding(.leading, 2).help("Rename")
                    }
                }
                .frame(minHeight: 22)
                if let subtitle {
                    HStack(spacing: 6) {
                        if let status { StatusDot(status: status) }
                        Text(subtitle).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                    }
                    .frame(minHeight: 18)
                }
            }
            .frame(minWidth: labels ? 120 : 0, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 8)
            ForEach(shownButtons) { b in
                Group {
                    if let label = b.label, labels {
                        Button(action: b.action) { Text(label) }.dashButton(b.prominent ? .prominent : b.destructive ? .destructive : .bordered)
                    } else {
                        Button(action: b.action) { Image(systemName: b.glyph) }
                            .buttonStyle(IconButtonStyle(destructive: b.destructive, prominent: b.prominent))
                    }
                }
                .disabled(!b.enabled)
                .help(b.tip ?? b.label ?? "")
            }
        }
    }
}

/// Muted text that turns to ink on hover, as the ✎ after a title.
struct HoverInkStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hovered ? Theme.ink : Theme.muted).onHover { hovered = $0 }
    }
}

/// The header's last button on a page that can live in a window of its own: pop it out, or dock it back.
struct PaneDetach { var glyph: String; var tip: String; var action: () -> Void }
private struct PaneDetachKey: EnvironmentKey { static let defaultValue: PaneDetach? = nil }
extension EnvironmentValues {
    var paneDetach: PaneDetach? {
        get { self[PaneDetachKey.self] }
        set { self[PaneDetachKey.self] = newValue }
    }
}

private struct PaneBackKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    /// The back button's action when the pane can go back: a pushed screen, or the root in one column.
    var paneBack: (() -> Void)? {
        get { self[PaneBackKey.self] }
        set { self[PaneBackKey.self] = newValue }
    }
}
