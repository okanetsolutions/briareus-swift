// The Usage tab's custom window: a first and a last day, both counted, applied as one range of at most a year.
import SwiftUI

struct UsageRangeSheet: View {
    /// The range on screen before this one, which the pickers start on.
    var current: UsageRange?
    var apply: (UsageRange) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var from = Date()
    @State private var to = Date()

    private var range: UsageRange? { UsageRange.make(from, to) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("From", selection: $from, displayedComponents: .date)
                    DatePicker("To", selection: $to, in: from..., displayedComponents: .date)
                } footer: {
                    if range == nil { Text("Choose a range of at most \(UsageRange.maxDays) days.") }
                }
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { if let range { apply(range) } }.disabled(range == nil)
                }
            }
            .onChange(of: from) { _, new in if to < new { to = new } }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            guard let days = (current ?? .lastWeek()).dates() else { return }
            from = days.from; to = days.to
        }
    }
}
