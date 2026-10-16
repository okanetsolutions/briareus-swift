// Sleep mode's screen on the Mac: the clock, a pane per working session typing out the file it touches (two columns, or
// one in a narrow window), and the commands they run scrolling beneath. Always dark; any key, click or scroll wakes the
// app. The iPhone's twin is App/SleepMode/SleepScreen.swift.
import SwiftUI

/// The window's cover while the app sleeps, faded in and out.
struct SleepOverlay: View {
    @ObservedObject private var model = SleepModel.shared
    var body: some View {
        ZStack { if model.asleep { SleepScreen(model: model).transition(.opacity) } }
            .animation(.easeInOut(duration: 0.6), value: model.asleep)
    }
}

struct SleepScreen: View {
    @ObservedObject var model: SleepModel
    @EnvironmentObject private var navigator: Navigator

    private var compact: Bool { navigator.isNarrow }

    var body: some View {
        let panes = model.wall.shown(compact ? 2 : 4)
        VStack(alignment: .leading, spacing: 12) {
            SleepHeader(state: model.wall.state)
            if panes.isEmpty {
                EmptyNote(title: "Nothing running", detail: "Sessions show here as they write code and run commands.")
                    .frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SleepPaneGrid(panes: panes, columns: compact ? 1 : 2)
            }
            SleepTicker(commands: model.wall.ticker, count: compact ? 4 : 6)
        }
        .padding(Theme.paneMargin * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { model.wake() }
        .accessibilityAction(named: "Wake") { model.wake() }
    }
}

private struct SleepHeader: View {
    var state: SleepWallState

    private var label: String {
        switch state {
        case .working: return "Working"
        case .replaying: return "Replaying recent work"
        case .idle: return "Idle"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, style: .time).font(Theme.largeTitle.monospacedDigit()).foregroundStyle(Theme.ink)
            }
            Spacer()
            Label(label, systemImage: state.symbol)
                .font(Theme.footnote).foregroundStyle(Theme.muted)
        }
    }
}

private struct SleepPaneGrid: View {
    var panes: [SleepPane]
    var columns: Int

    var body: some View {
        let rows = stride(from: 0, to: panes.count, by: columns).map { Array(panes[$0..<min($0 + columns, panes.count)]) }
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { SleepPaneView(pane: $0) }
                    if row.count < columns { Color.clear }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct SleepTicker: View {
    var commands: [SleepCommand]
    var count: Int

    var body: some View {
        let shown = Array(commands.suffix(count))
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                (Text(c.project).foregroundStyle(Theme.accent) + Text("  $ ").foregroundStyle(Theme.muted) + Text(c.text).foregroundStyle(Theme.ink))
                    .font(Theme.monoSmall)
                    .lineLimit(1)
                    .opacity(0.35 + 0.65 * Double(i + 1) / Double(max(shown.count, 1)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: commands.last?.id)
    }
}
