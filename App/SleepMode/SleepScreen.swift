// Sleep mode's screen on a phone or iPad: the clock, a pane per working session typing out the file it touches, and
// the commands they run scrolling beneath. Always dark; a touch anywhere wakes the app. The Mac's twin is
// Mac/App/SleepMode/SleepScreen.swift.
import SwiftUI

struct SleepScreen: View {
    @ObservedObject var model: SleepModel
    @Environment(\.horizontalSizeClass) private var width

    private var compact: Bool { width == .compact }

    var body: some View {
        let panes = model.wall.shown(compact ? 2 : 4)
        VStack(alignment: .leading, spacing: 12) {
            SleepHeader(state: model.wall.state)
            if panes.isEmpty {
                ContentUnavailableView("Nothing running", systemImage: "moon.zzz",
                                       description: Text("Sessions show here as they write code and run commands."))
                    .frame(maxHeight: .infinity)
            } else {
                SleepPaneGrid(panes: panes, columns: compact ? 1 : 2)
            }
            SleepTicker(commands: model.wall.ticker, count: compact ? 4 : 6)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { model.wake() }
        .accessibilityAction(named: "Wake") { model.wake() }
        .statusBarHidden()
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
                Text(context.date, style: .time).font(.largeTitle.weight(.light).monospacedDigit()).foregroundStyle(Theme.ink)
            }
            Spacer()
            Label(label, systemImage: state.symbol)
                .font(.footnote).foregroundStyle(Theme.muted)
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
                line(c)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .opacity(fade(i, of: shown.count))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.25), value: commands.last?.id)
    }

    /// One command as "project  $ text", each part in its own colour.
    private func line(_ command: SleepCommand) -> Text {
        let project: Text = Text(command.project).foregroundStyle(Theme.accent)
        let prompt: Text = Text("  $ ").foregroundStyle(Theme.muted)
        let text: Text = Text(command.text).foregroundStyle(Theme.ink)
        return project + prompt + text
    }

    /// Older commands fade out: the newest is opaque and the oldest shown is at 35%.
    private func fade(_ index: Int, of total: Int) -> Double {
        let position = Double(index + 1) / Double(max(total, 1))
        return 0.35 + 0.65 * position
    }
}
