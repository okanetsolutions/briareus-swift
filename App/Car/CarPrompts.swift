// The car needs the iOS 26.4 SDK, which came with the Swift 6.3 compiler.
#if os(iOS) && compiler(>=6.3)
import CarPlay

// An errand that takes words, such as Give feedback, in the car: dictated, or one of the project's saved prompts, as the
// phone's sheet and the Mac's 📚 offer them.
@available(iOS 26.4, *)
extension CarAssistant {
    /// Straight to dictation when the project has no saved prompts; else a list of them, with dictation first. A failed read
    /// offers dictation beside Retry, so a prompts outage never blocks voice feedback.
    func feedback(_ action: BoardAction) {
        guard case .pull(let number) = focus, let repo = project?.repo, let client = store.client else { return }
        let template = CPListTemplate(title: action.label, sections: [])
        template.emptyViewTitleVariants = ["Loading saved prompts…"]
        guard controller.templates.count == 2 else { return }
        controller.pushTemplate(template, animated: true) { [weak self] pushed, _ in
            Task { @MainActor in
                guard pushed else { return }
                self?.loadFeedback(action, template: template, repo: repo, number: number, client: client)
            }
        }
    }

    private func loadFeedback(_ action: BoardAction, template: CPListTemplate, repo: String, number: Int, client: APIClient) {
        Task { [weak self] in
            guard let self else { return }
            func current() -> Bool {
                guard case .pull(let activeNumber) = self.focus else { return false }
                return activeNumber == number && self.project?.repo == repo && self.store.client === client
                    && self.controller.topTemplate === template
            }
            guard current() else { return }
            template.updateSections([])
            template.emptyViewTitleVariants = ["Loading saved prompts…"]
            template.emptyViewSubtitleVariants = []
            let dictated = self.store.canTranscribe
                ? [self.item("Dictate", action.input?.label, symbol: "mic") { [weak self] in self?.dictate(.feedback(action)) }] : []
            do {
                let prompts = try await SavedPrompts.shared.list(repo)
                guard current() else { return }
                guard !prompts.isEmpty else { self.dictate(.feedback(action)); return }
                let words = Purpose.feedback(action).confirmation
                let saved = prompts.map { p in
                    self.item(p.title, p.everywhere ? "Every project" : nil, symbol: p.everywhere ? "globe" : "text.quote") { [weak self] in
                        self?.ask(CarText.variants(p.title, before: words.before, after: "”?"), yes: words.yes) { self?.run(action, input: p.body) }
                    }
                }
                template.updateSections(Self.fit([self.section(nil, dictated), self.section("Saved prompts", saved)]))
            } catch {
                guard current(), let words = failure(error) else { return }
                template.emptyViewTitleVariants = ["Could not load saved prompts"]
                template.emptyViewSubtitleVariants = [words]
                let retry = self.item("Retry", symbol: "arrow.clockwise") { [weak self, weak template] in
                    guard let template else { return }
                    self?.loadFeedback(action, template: template, repo: repo, number: number, client: client)
                }
                template.updateSections(Self.fit([self.section(words, dictated + [retry])]))
            }
        }
    }
}
#endif
