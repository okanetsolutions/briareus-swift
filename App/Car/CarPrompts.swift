// The car needs the iOS 26.4 SDK, which came with the Swift 6.3 compiler.
#if os(iOS) && compiler(>=6.3)
import CarPlay

// An errand that takes words, such as Give feedback, in the car: dictated, or one of the project's saved prompts, as the
// phone's sheet and the Mac's 📚 offer them.
@available(iOS 26.4, *)
extension CarAssistant {
    /// Straight to dictation when the project has no saved prompts; else a list of them, with dictation first.
    func feedback(_ action: BoardAction) {
        Task { [weak self] in
            guard let self else { return }
            let prompts = await SavedPrompts.shared.list(self.project?.repo)
            guard !prompts.isEmpty else { self.dictate(.feedback(action)); return }
            let words = Purpose.feedback(action).confirmation
            let dictated = self.store.canTranscribe
                ? [self.item("Dictate", action.input?.label, symbol: "mic") { [weak self] in self?.dictate(.feedback(action)) }] : []
            let saved = prompts.map { p in
                self.item(p.title, p.everywhere ? "Every project" : nil, symbol: p.everywhere ? "globe" : "text.quote") { [weak self] in
                    self?.ask(CarText.variants(p.title, before: words.before, after: "”?"), yes: words.yes) { self?.run(action, input: p.body) }
                }
            }
            self.third(CPListTemplate(title: action.label, sections: Self.fit([self.section(nil, dictated), self.section("Saved prompts", saved)])))
        }
    }
}
#endif
