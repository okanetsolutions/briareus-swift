// The Review List's login, shared by a project's board and the board across every project: the button saying whose
// review the list waits on, and the alert that asks for the GitHub login.
import SwiftUI

struct ReviewLoginButton: View {
    /// Called once a login is saved, so the list is drawn again for it.
    var saved: () -> Void
    @State private var asked = false
    @State private var text = ""

    var body: some View {
        Button { text = GitHubLogin.current ?? ""; asked = true } label: {
            Label(GitHubLogin.current.map { "Reviewing as \($0)" } ?? "Set my GitHub login…", systemImage: "person.crop.circle")
                .font(.footnote)
        }
        .buttonStyle(.borderless)
        .alert("Your GitHub login", isPresented: $asked) {
            TextField("Login", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save") { if GitHubLogin.save(text) { saved() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Review List shows the pull requests waiting on this GitHub user's review.")
        }
    }
}
