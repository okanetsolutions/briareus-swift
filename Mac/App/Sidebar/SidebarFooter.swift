// The sidebar's foot (screen_projects.c sidebar_footer_paint, player_paint and the sessions screen's bulk bar): while ☑
// Select is on, the count, Select all, ⏻ Close, 🗑 Delete and 🗑 Delete all; the player while something plays, with ⏮ ⏯ ⏭
// and under them the Mac's volume (the speaker mutes, the slider drags or clicks to a level, the wheel over the player
// steps it); and `⚙`, `☑ Select`, the version and `⎋` above a border.
import AppKit
import SwiftUI

/// A hairline across the sidebar, 10px in from each side.
private struct FootRule: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 10) }
}

/// Text that reacts to clicks within 4px of itself, as the foot's hit rectangles are inflated.
private struct FootText: View {
    var text: String
    var font: Font
    var color: Color
    var action: (() -> Void)?
    var body: some View {
        let label = Text(text).font(font).foregroundStyle(color).lineLimit(1).frame(height: 18)
        if let action {
            Button(action: action) { label.padding(4).contentShape(Rectangle()) }.buttonStyle(.plain).padding(-4)
        } else { label }
    }
}

struct SidebarFooter: View {
    /// The sessions screen's ☑ Select state and its bar; nil on the projects screen, where ☑ Select does nothing.
    var sessions: SidebarSessions?
    var settings: () -> Void
    var signOut: () -> Void
    @ObservedObject private var media = Media.shared

    var body: some View {
        VStack(spacing: 0) {
            if let sessions { BulkBar(model: sessions) }
            if media.state.available { player }
            foot
        }
        // Its own height only, so the rows above take the rest and the player sits on the foot.
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.sidebar)
    }

    // MARK: Player

    private var player: some View {
        let st = media.state
        let title = !st.title.isEmpty ? st.title : st.spotify ? "Spotify" : "Nothing playing"
        return VStack(spacing: 0) {
            Color.clear.frame(height: 6)
            FootRule()
            Color.clear.frame(height: 8)
            HStack(spacing: 0) {
                // Spotify's green on its own player, the muted note on another's.
                Image(systemName: Glyph.symbol(0xE8D6)).font(.system(size: 14))
                    .foregroundStyle(st.spotify ? Color(.sRGB, red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0) : Theme.muted)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(Theme.captionSemibold).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail).frame(height: 18)
                    if !st.artist.isEmpty {
                        Text(st.artist).font(Theme.caption2).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail).frame(height: 16)
                    } else { Color.clear.frame(height: 16) }
                }
                .padding(.leading, 8).padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                playerButton(Glyph.symbol(0xE892), size: 12, ring: false, tip: "Previous") { media.send(.previous) }
                playerButton(Glyph.symbol(st.playing ? 0xE769 : 0xE768), size: 14, ring: true, tip: st.playing ? "Pause" : "Play") { media.send(.toggle) }
                playerButton(Glyph.symbol(0xE893), size: 12, ring: false, tip: "Next") { media.send(.next) }
            }
            .frame(height: 36)
            .padding(.leading, 16).padding(.trailing, 10)
            if st.hasVolume { VolumeRow(media: media).padding(.leading, 16).padding(.trailing, 10) }
            Color.clear.frame(height: 2)
        }
        // The wheel over the player steps the volume.
        .background(ScrollWheelCatcher { media.stepVolume($0) })
    }

    private func playerButton(_ symbol: String, size: CGFloat, ring: Bool, tip: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(Theme.ink)
                .frame(width: 26, height: 26)
                .background { if ring { Circle().fill(Theme.raise).overlay(Circle().strokeBorder(Theme.line, lineWidth: 1)) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    // MARK: Foot

    private var version: String { "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") }

    private var foot: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 6)
            FootRule()
            Color.clear.frame(height: 10)
            ZStack {
                Text(version).font(Theme.caption2).foregroundStyle(Theme.tertiary).frame(height: 18)
                HStack(spacing: 0) {
                    FootText(text: "⚙", font: Theme.footnote, color: Theme.muted, action: settings).help("Settings")
                    Color.clear.frame(width: 12)
                    SelectToggle(sessions: sessions)
                    Spacer(minLength: 8)
                    FootText(text: "⎋", font: Theme.footnote, color: Theme.muted, action: signOut).help("Sign out")
                }
            }
            .padding(.horizontal, 16)
            Color.clear.frame(height: 12)
        }
    }
}

/// The player's volume, under ⏮ ⏯ ⏭: the speaker mutes, the slider drags or clicks to a level, and the level in percent at
/// the right, under ⏭.
private struct VolumeRow: View {
    @ObservedObject var media: Media

    var body: some View {
        let st = media.state
        HStack(spacing: 0) {
            Button { media.send(.mute) } label: {
                Image(systemName: Glyph.symbol(Self.glyph(st))).font(.system(size: 11))
                    .foregroundStyle(st.muted ? Theme.muted : Theme.ink)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, -4)
            .help(st.muted ? "Unmute" : "Mute")
            GeometryReader { geo in track(st, width: geo.size.width) }
                .frame(height: 22)
                .padding(.trailing, 8)
            Text(verbatim: "\(Int((st.volume * 100).rounded()))%").font(Theme.caption2).foregroundStyle(Theme.muted)
                .lineLimit(1).frame(width: 32, alignment: .trailing)
                .padding(.trailing, 4)
        }
        .frame(height: 22)
    }

    /// The track, the level filled in Spotify's green on its own player, the accent on another's, and the knob; a press
    /// sets the level there and a drag follows it, ending where it is.
    private func track(_ st: Media.State, width: CGFloat) -> some View {
        let x = width * CGFloat(st.volume)
        let level = st.muted ? Theme.muted.opacity(0.4) : st.spotify ? Color(.sRGB, red: 0x1D / 255.0, green: 0xB9 / 255.0, blue: 0x54 / 255.0) : Theme.accent
        return ZStack(alignment: .leading) {
            Capsule().fill(Theme.line).frame(height: 4)
            Capsule().fill(level).frame(width: max(0, x), height: 4)
            Circle().fill(st.muted ? Theme.muted : Theme.ink).frame(width: 12, height: 12).offset(x: x - 6)
        }
        .frame(width: width, height: 22)
        .contentShape(Rectangle().inset(by: -6))
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { g in
            guard width > 0 else { return }
            media.setVolume(Float(g.location.x / width))
        })
    }

    /// The speaker for a level: crossed out when muted, then with one to three waves.
    static func glyph(_ st: Media.State) -> UInt32 {
        if st.muted || st.volume <= 0.001 { return 0xE74F }
        return st.volume < 0.34 ? 0xE993 : st.volume < 0.67 ? 0xE994 : 0xE995
    }
}

/// Hands the wheel's notches over the view it sits behind to `step`, up positive, as the Windows client's footer_wheel: a
/// mouse's line steps one each, a trackpad's fine deltas are summed into steps.
private struct ScrollWheelCatcher: NSViewRepresentable {
    var step: (Int) -> Void

    final class Coordinator {
        var step: (Int) -> Void
        var monitor: Any?
        var sum: CGFloat = 0
        weak var view: NSView?
        init(step: @escaping (Int) -> Void) { self.step = step }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

        func handle(_ event: NSEvent) -> NSEvent? {
            guard let view, let window = view.window, event.window === window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return event }
            var dy = event.scrollingDeltaY
            if event.isDirectionInvertedFromDevice { dy = -dy }
            if event.hasPreciseScrollingDeltas {
                sum += dy
                let notches = Int(sum / 12)
                if notches != 0 { sum -= CGFloat(notches) * 12; step(notches) }
            } else if dy != 0 {
                step(dy > 0 ? max(1, Int(dy.rounded())) : min(-1, Int(dy.rounded())))
            }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(step: step) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let c = context.coordinator
        c.view = view
        c.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak c] event in c?.handle(event) ?? event }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.step = step }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
}

/// `☑ Select`: ink while on. It turns ☑ Select on and off inside a project; on the projects list it is drawn but does nothing.
private struct SelectToggle: View {
    var sessions: SidebarSessions?
    var body: some View {
        if let sessions { Observed(model: sessions) } else { FootText(text: "☑ Select", font: Theme.footnote, color: Theme.muted, action: nil) }
    }
    private struct Observed: View {
        @ObservedObject var model: SidebarSessions
        var body: some View {
            FootText(text: "☑ Select", font: Theme.footnote, color: model.selectMode ? Theme.ink : Theme.muted) { model.toggleSelectMode() }
        }
    }
}

/// The bulk bar above the foot while ☑ Select is on: the count, Select all, ⏻ Close and 🗑 Delete, 🗑 Delete all.
private struct BulkBar: View {
    @ObservedObject var model: SidebarSessions
    private var dim: Color { Theme.muted.opacity(0.5) }

    var body: some View {
        if model.selectMode {
            let can = !model.picked.isEmpty && !model.bulkRunning
            VStack(spacing: 0) {
                Color.clear.frame(height: 6)
                FootRule()
                Color.clear.frame(height: 10)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text(verbatim: "\(model.picked.count) selected").font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                            .frame(height: 18)
                        Spacer(minLength: 8)
                        FootText(text: "Select all", font: Theme.footnote, color: model.sessions.isEmpty ? dim : Theme.muted) { model.selectAll() }
                    }
                    Color.clear.frame(height: 6)
                    HStack(spacing: 6) {
                        bulkButton(model.bulkRunning && !model.bulkDelete ? "Closing…" : "⏻ Close", enabled: can) { model.bulk(delete: false, all: false) }
                        bulkButton(model.bulkRunning && model.bulkDelete ? "Deleting…" : "🗑 Delete", enabled: can) { model.bulk(delete: true, all: false) }
                    }
                    Color.clear.frame(height: 6)
                    HStack {
                        Button { model.bulk(delete: true, all: true) } label: {
                            Text("🗑 Delete all").font(Theme.caption).foregroundStyle(!model.sessions.isEmpty && !model.bulkRunning ? Theme.muted : dim)
                                .frame(height: 18).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer(minLength: 0)
                    }
                    ZStack(alignment: .top) {
                        Color.clear.frame(height: 10)
                        if let error = model.bulkError {
                            Text(error).font(Theme.caption2).foregroundStyle(Theme.danger).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 14).offset(y: -8).help(error)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func bulkButton(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.caption).foregroundStyle(enabled ? Theme.ink : Theme.muted)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raise))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
