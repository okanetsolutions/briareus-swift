// The CI dashboard's query controls, drawing only the shared query and available projects.
import SwiftUI

struct CIDashboardFilters: View {
    @Binding var query: CIQuery
    let projects: [Project]

    var body: some View {
        Section {
            Picker("Window", selection: $query.days) {
                ForEach([7, 30, 90], id: \.self) { Text("\($0) days").tag($0) }
            }
            Picker("Project", selection: $query.repo) {
                Text("All projects").tag("")
                ForEach(projects, id: \.repo) { Text($0.title).tag($0.repo) }
            }
            Picker("Source", selection: $query.kind) {
                ForEach(CIKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        } footer: {
            Text("Observed GitHub checks only; earlier history may be incomplete. Daily totals use UTC. Durations are execution time, not billed minutes.")
        }
    }
}
