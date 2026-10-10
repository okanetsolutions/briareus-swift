// The strip along the top of the sidebar (screen_projects.c sidebar_top): ＋ New session, then WhatsApp, 📊, ⚑ with
// its count, as 26px squares (⚙ Settings is at the foot's left). WhatsApp's mark is drawn, as no font has it.
import SwiftUI

enum StripAction { case newSession, whatsapp, mail, usage, findings }

struct SidebarStrip: View {
    /// The detail pane's root id, for the WhatsApp, 📊 and ⚑ switches' accent.
    var selected: String?
    var waiting: Int
    var action: (StripAction) -> Void

    static let height: CGFloat = 32, iconWidth: CGFloat = 26, gap: CGFloat = 3

    var body: some View {
        HStack(spacing: Self.gap) {
            // The label 6px in, as C draws it. The Mac's system font sets it about 6% wider than Segoe UI does, so it may
            // use the right inset and tighten a little rather than lose "on" to an ellipsis in the width the icons leave.
            StripButton(active: false, action: { action(.newSession) }) {
                Text("＋ New session").font(Theme.footnote).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
                    .allowsTightening(true).minimumScaleFactor(0.85)
                    .padding(.leading, 6).padding(.trailing, 2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .help("New session")
            StripButton(active: selected == "whatsapp", action: { action(.whatsapp) }) { WhatsAppMark() }
                .frame(width: Self.iconWidth).help("WhatsApp")
            // The synced mail, on a server that has it for an Admin token.
            if MailInboxModel.offered || MailSettingsModel.offered {
                StripButton(active: selected == "mail" || selected == "mail-settings", action: { action(.mail) }) {
                    emoji("✉", active: selected == "mail" || selected == "mail-settings")
                }
                .frame(width: Self.iconWidth).help("Mail")
            }
            StripButton(active: selected == "usage", action: { action(.usage) }) { emoji("📊", active: selected == "usage") }
                .frame(width: Self.iconWidth).help("Usage")
            StripButton(active: selected == "findings", badge: waiting, action: { action(.findings) }) { emoji("⚑", active: selected == "findings") }
                .frame(width: Self.iconWidth).help("Findings")
        }
        .frame(height: Self.height)
    }

    private func emoji(_ text: String, active: Bool) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(active ? Theme.accent : Theme.ink)
    }
}

/// paint_strip: a raised rounded square, its border the accent when active, dimmer on hover, with the count badge over its
/// top right corner (`absolute -right-1.5 -top-1.5 min-w-4 rounded-full bg-accent px-1 text-[10px] font-semibold`).
private struct StripButton<Label: View>: View {
    var active: Bool
    var badge = 0
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? Theme.accent : hovered ? Theme.accentDim : Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside != hovered { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            hovered = inside
        }
        .onDisappear { if hovered { NSCursor.pop(); hovered = false } }
        .overlay(alignment: .topTrailing) {
            if badge > 0 {
                Text(verbatim: "\(badge)").font(Theme.tinySemibold).foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16, maxHeight: 16)
                    .background(Capsule().fill(Theme.accent))
                    .offset(x: 6, y: -6)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// paint_whatsapp_mark: a green chat bubble with its tail at the lower left, and a white handset.
struct WhatsAppMark: View {
    static let green = Color(.sRGB, red: 0x25 / 255.0, green: 0xD3 / 255.0, blue: 0x66 / 255.0)
    var body: some View {
        let d: CGFloat = 18
        ZStack {
            Canvas { ctx, _ in
                var tail = Path()
                tail.move(to: CGPoint(x: 4, y: d - 5))
                tail.addLine(to: CGPoint(x: 1, y: d))
                ctx.stroke(tail, with: .color(Self.green), style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                ctx.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: d, height: d)), with: .color(Self.green))
            }
            Image(systemName: "phone.fill").font(.system(size: 11)).foregroundStyle(.white)
        }
        .frame(width: d, height: d)
    }
}
