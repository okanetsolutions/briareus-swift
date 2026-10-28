// Personal integrations and sharing are reachable without entering an Admin-only resource form.
import SwiftUI

struct ClientSettingsRows: View {
    let selected: String?
    @ObservedObject private var store = Store.shared
    var body: some View {
        Color.clear.frame(height: 8)
        SectionHeader(title: "Accounts and access", onNew: nil)
        ForEach(PersonalConnectionKind.allCases) { kind in
            if store.supports(kind.read) {
                ItemRow(label: kind.title, sub: "Your personal connection", enabled: true,
                        selected: selected == Screen.personalConnection(kind).id) { Navigator.shared.show(.personalConnection(kind)) }
            }
        }
        if store.supports("shares") && store.supports("users") {
            ItemRow(label: "Sharing", sub: "Project and server access", enabled: true, selected: selected == Screen.sharing.id) { Navigator.shared.show(.sharing) }
        }
        if store.supports("ssh_monitoring") {
            ItemRow(label: "SSH monitoring", sub: "Remote host resources", enabled: true,
                    selected: selected == Screen.sshMonitoring(serverID: nil).id) { Navigator.shared.show(.sshMonitoring(serverID: nil)) }
        }
    }
}
