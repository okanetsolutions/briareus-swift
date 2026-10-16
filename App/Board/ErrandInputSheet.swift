// The question an errand such as Give feedback asks before its paid session starts: a box for the answer, which the
// project's saved prompts can fill, what it costs, and Start.
import SwiftUI

/// The errand's question: a box for the answer, the saved prompts to fill it, what it costs, and Start, off while a
/// required answer is empty.
struct ErrandInputSheet: View {
    let pending: PendingErrand
    let start: (String) -> Void
    @StateObject private var prompts: SavedPromptsModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool
    private var trimmed: String { text.cTrimmed }
    private var input: ActionInput? { pending.action.input }

    init(pending: PendingErrand, repo: String, start: @escaping (String) -> Void) {
        self.pending = pending; self.start = start
        _prompts = StateObject(wrappedValue: SavedPromptsModel(repo: repo))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(input.flatMap { $0.placeholder.isEmpty ? nil : $0.placeholder } ?? input?.label ?? "", text: $text, axis: .vertical)
                        .lineLimit(5...14).focused($focused)
                    if !prompts.prompts.isEmpty {
                        SavedPromptsMenu(prompts: prompts.prompts) { text = $0.inserted(into: text) }
                    }
                } header: {
                    Text(input?.label ?? "")
                } footer: {
                    Text(paidNote(pending))
                }
                .listRowBackground(Theme.row)
            }
            .scrollContentBackground(.hidden).background(Theme.canvas)
            .navigationTitle(pending.action.label).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { dismiss(); start(trimmed) }.bold()
                        .disabled(trimmed.isEmpty && input?.required == true)
                }
            }
            .onAppear { focused = true }
            .task { await prompts.load() }
        }
    }
}

/// The saved prompts as a menu; choosing one adds it to the box. The ones offered on every project carry a globe.
private struct SavedPromptsMenu: View {
    let prompts: [SavedPrompt]
    let choose: (SavedPrompt) -> Void
    var body: some View {
        Menu {
            ForEach(prompts) { p in
                Button { choose(p) } label: {
                    if p.everywhere { Label(p.title, systemImage: "globe") } else { Text(p.title) }
                }
            }
        } label: {
            Label("Saved prompts", systemImage: "books.vertical")
        }
    }
}
