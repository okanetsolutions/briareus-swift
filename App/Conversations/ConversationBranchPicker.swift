// The branch a new conversation starts on, pushed from the New conversation sheet: the mode's default (a new branch off
// the default, or a local checkout's current branch), the default branch, or one the project has, found by name.
import SwiftUI

/// The branch to start on: the mode's default, or one the project has, found by name.
struct ConversationBranchPicker: View {
    let branches: [String]
    let defaultBranch: String?
    /// The row for no pick, which differs per workspace mode.
    let noBranchLabel: String
    @Binding var selection: String?
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [String] {
        let list = branches.filter { $0 != defaultBranch }
        return search.isEmpty ? list : list.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                row(nil, label: noBranchLabel)
                if let defaultBranch { row(defaultBranch, label: defaultBranch) }
            }
            Section {
                ForEach(filtered, id: \.self) { row($0, label: $0) }
                if branches.isEmpty { Text("No other branches.").foregroundStyle(.secondary) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(Theme.canvas)
        .navigationTitle("Branch").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .pinned, prompt: "Find a branch")
        .textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private func row(_ value: String?, label: String) -> some View {
        Button { selection = value; dismiss() } label: {
            HStack {
                Text(label).font(value == nil ? .subheadline : .subheadline.monospaced()).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                if selection == value { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.row)
    }
}
