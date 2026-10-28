// Settings sign-out controls, kept apart from the resource lists.
import SwiftUI

struct SettingsSidebarFooter: View {
    @EnvironmentObject private var store: Store
    /// The foot, as the Windows client's settings page has it: `Settings` and `⎋ Sign out`, 12px muted, above a border.
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, 10).padding(.top, 6)
            HStack(spacing: 8) {
                Text("Settings").font(Theme.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Button(action: signOut) { Text("⎋ Sign out").font(Theme.caption) }.buttonStyle(HoverInkStyle())
            }
            .frame(height: 18)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
        }
        .background(Theme.sidebar)
    }

    private func signOut() {
        guard Dialogs.confirm("Sign out of this server?",
                              "The device token and the saved conversations are removed from this computer. Revoke the token itself in web Settings.",
                              continueLabel: "Sign out", destructive: true) else { return }
        store.forget()
    }

}
