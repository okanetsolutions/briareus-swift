// Find in a conversation, as the Mac's find bar (⌘F there): a field over the transcript, how many places match and
// which one is shown, and the steps between them. The search is Core's `TranscriptFind`, over the text each block draws.
// Every place the query occurs is marked in the messages and replies, and a step brings the current match's block into
// view; the Mac also marks which occurrence is the current one, which its own text view can and SwiftUI's Text cannot
// scroll to.
import SwiftUI

/// The find bar's state: the query, its matches and the block to bring into view.
@MainActor
final class ConversationFindModel: ObservableObject {
    @Published private(set) var showing = false
    @Published var query = ""
    @Published private(set) var find = TranscriptFind()
    /// Bumped whenever the current match should be scrolled to.
    @Published private(set) var jump = 0

    /// The block holding the current match.
    var target: Int? { find.currentMatch?.block }
    /// What the transcript marks: the query searched for, while the bar is up.
    var highlight: String { showing ? find.query : "" }

    func open() { showing = true }
    func close() {
        showing = false
        query = ""
        find = TranscriptFind()
    }
    /// A new query: its matches, from the first.
    func search(_ blocks: TranscriptRows, expanded: Set<Int>) {
        find.search(query, in: transcriptFindBlocks(blocks, expanded: expanded))
        if target != nil { jump += 1 }
    }
    /// The transcript changed under an open bar: the matches again, the current one kept where it was.
    func refresh(_ blocks: TranscriptRows, expanded: Set<Int>) {
        guard showing, !find.query.isEmpty else { return }
        find.rebuild(transcriptFindBlocks(blocks, expanded: expanded))
    }
    func step(backward: Bool) {
        guard !find.matches.isEmpty else { return }
        find.step(backward: backward)
        jump += 1
    }
}

/// The bar over the transcript while finding: the field, "3 / 12", previous and next, and Done.
struct ConversationFindBar: View {
    @ObservedObject var find: ConversationFindModel
    let blocks: TranscriptRows
    let expanded: Set<Int>
    @FocusState private var focused: Bool

    var body: some View {
        if find.showing {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Find in conversation", text: $find.query)
                    .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).focused($focused)
                    .onSubmit { find.step(backward: false); focused = true }
                if !find.find.query.isEmpty {
                    Text(find.find.status).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Button { find.step(backward: true) } label: { Image(systemName: "chevron.up") }
                    .disabled(find.find.matches.isEmpty).accessibilityLabel("Previous match")
                Button { find.step(backward: false) } label: { Image(systemName: "chevron.down") }
                    .disabled(find.find.matches.isEmpty).accessibilityLabel("Next match")
                Button("Done") { find.close() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
            .onAppear { focused = true }
            // Typing searches once it pauses: a long transcript is not walked again for every letter.
            .task(id: find.query) {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { find.search(blocks, expanded: expanded) }
            }
            .onChange(of: blocks) { _, now in find.refresh(now, expanded: expanded) }
            .onChange(of: expanded) { _, now in find.refresh(blocks, expanded: now) }
        }
    }
}

// MARK: - Marking the matches

private struct FindHighlightKey: EnvironmentKey {
    static let defaultValue = ""
}
extension EnvironmentValues {
    /// What a find bar over these views is looking for; empty when none is.
    var findHighlight: String {
        get { self[FindHighlightKey.self] }
        set { self[FindHighlightKey.self] = newValue }
    }
}

extension AttributedString {
    /// The text with every place `query` occurs marked, found as the search finds them (Core's `findOccurrences`).
    func marking(_ query: String) -> AttributedString {
        guard !query.isEmpty else { return self }
        let plain = String(characters)
        let found = findOccurrences(of: query, in: plain)
        guard !found.isEmpty else { return self }
        var out = self
        let length = (query as NSString).length
        for start in found {
            let from = plain.distance(from: plain.startIndex, to: String.Index(utf16Offset: start, in: plain))
            let to = plain.distance(from: plain.startIndex, to: String.Index(utf16Offset: start + length, in: plain))
            let lower = out.index(out.startIndex, offsetByCharacters: from)
            out[lower..<out.index(lower, offsetByCharacters: to - from)].backgroundColor = Theme.warn.opacity(0.35)
        }
        return out
    }
}

/// Plain text that marks what the find bar over it is looking for.
struct FindMarkedText: View {
    let text: String
    @Environment(\.findHighlight) private var finding
    var body: some View {
        if finding.isEmpty { Text(text) } else { Text(AttributedString(text).marking(finding)) }
    }
}

extension ScrollViewProxy {
    /// Brings a transcript block into view. Rows far away are not laid out yet and their heights are estimates, so one
    /// jump can land short; a second, once they are, settles on it unless another step was taken meanwhile.
    @MainActor func reveal(_ seq: Int?) async {
        guard let seq else { return }
        withAnimation(.easeOut(duration: 0.25)) { scrollTo(seq, anchor: .center) }
        guard (try? await Task.sleep(for: .milliseconds(350))) != nil else { return }
        scrollTo(seq, anchor: .center)
    }
}
