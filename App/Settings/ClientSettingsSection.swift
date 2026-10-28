// Personal integrations and sharing are outside the Admin-only project settings section.
import SwiftUI

struct ClientSettingsSection: View {
    @EnvironmentObject private var store: Store
    var body: some View {
        Section("Accounts and access") {
            ForEach(PersonalConnectionKind.allCases) { kind in
                if store.supports(kind.read) {
                    DestinationLink(destination: .personalConnection(kind)) { Text(kind.title) }
                }
            }
            if store.supports("shares") && store.supports("users") {
                DestinationLink(destination: .sharing) { Label("Sharing", systemImage: "person.2") }
            }
            if store.supports("ssh_monitoring") {
                DestinationLink(destination: .sshMonitoring(serverID: nil)) { Label("SSH monitoring", systemImage: "server.rack") }
            }
        }.listRowBackground(Theme.row)
    }
}
