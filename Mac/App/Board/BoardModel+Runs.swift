// The board's conversation reads, with older answers kept from overwriting a newer reload.
import Foundation

extension BoardModel {
    /// The newest read wins: after a start, C cancels the read in flight and reads again.
    func loadRuns() async {
        runsGen += 1
        let gen = runsGen
        readingRuns = true
        let r = await boardCall("sessions", ["repo": .string(repo)])
        guard gen == runsGen else { return }
        readingRuns = false
        if let v = r.value, let list = Session.parseList(v), runs != list { runs = list }
    }
}
