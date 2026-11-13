// The project settings form's tabs as a strip of chips under the bar (ProjectSettingsScreen): six do not fit a segmented
// control on a phone. A dot marks a tab holding unsaved changes, and the open tab scrolls into view.
import SwiftUI

struct ProjectSettingsTabStrip: View {
    @Binding var tab: ProjectTab
    /// Whether a tab holds unsaved changes.
    let dot: (ProjectTab) -> Bool
    /// Called before the tab changes, so the form drops its focus first.
    let willSwitch: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ProjectTab.allCases, id: \.self) { t in
                        let on = tab == t
                        Button {
                            willSwitch()
                            tab = t
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: Self.symbol(t)).font(.caption)
                                Text(t.title).font(.subheadline.weight(on ? .semibold : .regular))
                                if dot(t) { Circle().fill(Theme.accent).frame(width: 6, height: 6) }
                            }
                            .padding(.horizontal, 12).frame(minHeight: 34)
                            .foregroundStyle(on ? Color.white : .primary)
                            .background(on ? Theme.accent : Theme.field, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(t)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityValue(dot(t) ? "Unsaved changes" : "")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .onChange(of: tab) { _, t in withAnimation { proxy.scrollTo(t, anchor: .center) } }
            .onAppear { proxy.scrollTo(tab, anchor: .center) }
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    static func symbol(_ t: ProjectTab) -> String {
        switch t {
        case .project: return "folder"
        case .database: return "cylinder.split.1x2"
        case .review: return "magnifyingglass"
        case .orchestrator: return "point.3.connected.trianglepath.dotted"
        case .env: return "doc.text"
        case .run: return "play"
        }
    }
}
