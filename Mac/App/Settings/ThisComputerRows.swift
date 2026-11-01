// Settings' "This computer" section: what this Mac keeps for itself rather than on the server: when the app falls asleep
// to show the sessions' work.
import SwiftUI

struct ThisComputerRows: View {
    @ObservedObject private var sleep = SleepModel.shared

    var body: some View {
        SectionHeader(title: "This computer", onNew: nil)
        ItemRow(label: "💤 Sleep mode", sub: sleep.sleepAfter > 0 ? "after \(sleepAfterLabel(sleep.sleepAfter)) idle" : "off",
                enabled: sleep.sleepAfter > 0, selected: false) { chooseSleepAfter() }
        Color.clear.frame(height: 16)
    }

    private func chooseSleepAfter() {
        let items = sleepAfterChoices.map { PopupMenu.Item(title: sleepAfterLabel($0), checked: $0 == sleep.sleepAfter) }
        if let i = PopupMenu.choose(items) { sleep.sleepAfter = sleepAfterChoices[i] }
    }
}
