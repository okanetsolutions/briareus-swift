// The look every Briareus client shares, dark or light as macOS's appearance says: the palette (canvas, sidebar, raise, field,
// sunken, line, ink, muted, accent), the status colours, the type sizes, the columns and the working indicator all come from
// briareus-client-contracts (Mac/Core/BriareusTokens.swift, generated there and copied in by its `node scripts/sync.mjs`).
import AppKit
import SwiftUI

enum Theme {
    // MARK: Palette

    private static func dynamic(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: nsDynamic(dark, light))
    }
    static func nsDynamic(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        }
    }

    static let canvas = dynamic(BriareusPalette.dark.canvas, BriareusPalette.light.canvas)
    static let sidebar = dynamic(BriareusPalette.dark.sidebar, BriareusPalette.light.sidebar)
    static let raise = dynamic(BriareusPalette.dark.raise, BriareusPalette.light.raise)
    static let field = dynamic(BriareusPalette.dark.field, BriareusPalette.light.field)
    static let sunken = dynamic(BriareusPalette.dark.sunken, BriareusPalette.light.sunken)
    static let line = dynamic(BriareusPalette.dark.line, BriareusPalette.light.line)
    static let lineStrong = dynamic(BriareusPalette.dark.lineStrong, BriareusPalette.light.lineStrong)
    static let ink = dynamic(BriareusPalette.dark.ink, BriareusPalette.light.ink)
    static let muted = dynamic(BriareusPalette.dark.muted, BriareusPalette.light.muted)
    static let accent = dynamic(BriareusPalette.dark.accent, BriareusPalette.light.accent)
    static let accentDim = dynamic(BriareusPalette.dark.accentDim, BriareusPalette.light.accentDim)
    static let ok = dynamic(BriareusPalette.dark.ok, BriareusPalette.light.ok)
    static let warn = dynamic(BriareusPalette.dark.warn, BriareusPalette.light.warn)
    static let danger = dynamic(BriareusPalette.dark.danger, BriareusPalette.light.danger)
    static let onAccent = dynamic(BriareusPalette.dark.onAccent, BriareusPalette.light.onAccent)
    static let dot = dynamic(BriareusPalette.dark.dot, BriareusPalette.light.dot)
    static let thumb = dynamic(BriareusPalette.dark.thumb, BriareusPalette.light.thumb)
    /// `text-muted/70`.
    static let tertiary = muted.opacity(0.7)

    /// The status dot's colour, as every client gives it: working in the accent, idle green, waiting amber, failed red, the
    /// rest grey.
    static func statusColor(_ status: String?) -> Color {
        switch BriareusStatusRole(status: status) {
        case .active: return accent
        case .idle: return ok
        case .attention: return warn
        case .failed: return danger
        case .inactive: return dot
        }
    }

    // MARK: Type

    // The shared text styles at their pixel sizes: body 15px, the smallest chrome 13px, the sidebar rows 14px, metadata 12px and
    // 11px. The Mac's system font stands in for Segoe UI and its monospaced one for Cascadia Code.
    private static func font(_ style: BriareusTextStyle, design: Font.Design? = nil) -> Font {
        let weight: Font.Weight
        switch style.weight {
        case ..<450: weight = .regular
        case ..<550: weight = .medium
        default: weight = .semibold
        }
        let font = Font.system(size: CGFloat(style.size), weight: weight, design: design ?? (style.monospaced ? .monospaced : .default))
        return style.italic ? font.italic() : font
    }
    static let body = font(BriareusType.body)
    static let bodyMedium = font(BriareusType.bodyMedium)
    static let bodySemibold = font(BriareusType.bodySemibold)
    static let headline = font(BriareusType.headline)
    static let subheadline = font(BriareusType.subheadline)
    static let subheadlineSemibold = font(BriareusType.subheadlineSemibold)
    static let title3 = font(BriareusType.title3)
    static let largeTitle = font(BriareusType.largeTitle)
    static let callout = font(BriareusType.callout)
    static let footnote = font(BriareusType.footnote)
    static let footnoteSemibold = font(BriareusType.footnoteSemibold)
    static let caption = font(BriareusType.caption)
    static let captionMedium = font(BriareusType.captionMedium)
    static let captionSemibold = font(BriareusType.captionSemibold)
    static let caption2 = font(BriareusType.caption2)
    static let bodyItalic = font(BriareusType.bodyItalic)
    static let mono = font(BriareusType.mono)
    static let monoSmall = font(BriareusType.monoSmall)
    static let monoCaption2 = font(BriareusType.monoCaption2)
    static let tinySemibold = font(BriareusType.tinySemibold)
    /// 23px semibold: a pull request's title.
    static let title = font(BriareusType.title)
    /// 22px semibold: the Windows client tiles.
    static let stat = font(BriareusType.stat)
    /// The project monogram, in the Mac's serif.
    static let monogram = font(BriareusType.monogram, design: .serif)

    // MARK: Layout

    /// The columns: the sidebar, the main column, and the pull request panel beside a conversation.
    static let sidebarWidth = CGFloat(BriareusLayout.sidebarWidth)
    static let panelWidth = CGFloat(BriareusLayout.panelWidth)
    /// Below this width (the Windows client's `lg` breakpoint, 64rem) the columns become one at a time.
    static let narrowWidth = CGFloat(BriareusLayout.narrowWidth)
    /// Pane margins: the sidebar's, and the other panes'.
    static let sidebarMargin = CGFloat(BriareusLayout.sidebarMargin)
    static let paneMargin = CGFloat(BriareusLayout.paneMargin)

    // MARK: Working indicator

    static let workingGlyphs = BriareusWorking.glyphs
    static let workingVerbs = BriareusWorking.verbs
    static func workingGlyph(_ tick: Int) -> String { BriareusWorking.glyph(tick) }
    static func workingVerb(_ tick: Int) -> String { BriareusWorking.verb(tick) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// A GitHub label's "rrggbb".
    init?(hexString: String?) {
        guard var s = hexString?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(nsColor: NSColor(hex: v))
    }
}

// MARK: - Icons

/// The Windows app draws Segoe Fluent Icons by code point; these are the SF Symbols that stand for each.
enum Glyph {
    static func symbol(_ codepoint: UInt32) -> String {
        switch codepoint {
        case 0xE710: return "plus"
        case 0xE711: return "xmark"
        case 0xE713: return "gearshape"
        case 0xE716: return "person.2"
        case 0xE717: return "phone"
        case 0xE71A: return "stop.fill"
        case 0xE71B: return "link"
        case 0xE72A: return "arrow.right"
        case 0xE72C: return "arrow.clockwise"
        case 0xE738: return "minus"
        case 0xE73E: return "checkmark"
        case 0xE74B: return "arrow.down"
        case 0xE74D: return "trash"
        case 0xE74E: return "square.and.arrow.down"
        case 0xE753: return "cloud"
        case 0xE74F: return "speaker.slash.fill"
        case 0xE993: return "speaker.wave.1.fill"
        case 0xE994: return "speaker.wave.2.fill"
        case 0xE995: return "speaker.wave.3.fill"
        case 0xE756: return "terminal"
        case 0xE768: return "play.fill"
        case 0xE769: return "pause.fill"
        case 0xE76C: return "chevron.right"
        case 0xE70D: return "chevron.down"
        case 0xE70E: return "chevron.up"
        case 0xE70F: return "pencil"
        case 0xE774: return "globe"
        case 0xE783: return "exclamationmark.circle"
        case 0xE787: return "calendar"
        case 0xE7A7: return "arrow.uturn.backward"
        case 0xE7BA: return "exclamationmark.triangle"
        case 0xE7C1: return "flag"
        case 0xE7C3: return "doc"
        case 0xE7F4: return "display"
        case 0xE80F: return "house"
        case 0xE81E: return "square.3.layers.3d"
        case 0xE823: return "clock"
        case 0xE838: return "folder"
        case 0xE892: return "backward.end.fill"
        case 0xE893: return "forward.end.fill"
        case 0xE895: return "arrow.triangle.2.circlepath"
        case 0xE896: return "arrow.down.to.line"
        case 0xE898: return "arrow.up.to.line"
        case 0xE8A5: return "doc.text"
        case 0xE8A7: return "arrow.up.right.square"
        case 0xE8AB: return "arrow.triangle.branch"
        case 0xE8B7: return "folder"
        case 0xE8BB: return "xmark"
        case 0xE8BD: return "text.bubble"
        case 0xE8C8: return "doc.on.doc"
        case 0xE8D6: return "music.note"
        case 0xE8D7: return "lock"
        case 0xE8E3: return "list.bullet"
        case 0xE8E4: return "text.alignleft"
        case 0xE8EC: return "tag"
        case 0xE77B: return "person"
        case 0xE8EE: return "repeat"
        case 0xE8F2: return "bubble.left.and.bubble.right"
        case 0xE8F4: return "folder.badge.plus"
        case 0xE8FD: return "list.bullet.rectangle"
        case 0xE90F: return "wrench.and.screwdriver"
        case 0xE930: return "checkmark.circle"
        case 0xE946: return "info.circle"
        case 0xE968: return "network"
        case 0xE97A: return "arrowshape.turn.up.left"
        case 0xE9D5: return "checklist"
        case 0xE9D9: return "chart.bar"
        case 0xEA39: return "xmark.circle"
        case 0xE1D3: return "cylinder.split.1x2"
        case 0xE721: return "magnifyingglass"
        default: return "circle"
        }
    }
}
