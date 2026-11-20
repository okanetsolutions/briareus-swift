// The one notice at the top of every window while the link to the server is lost (Core's ConnectivityNotice): offline,
// or a server that stopped answering, and when what is on screen was saved. The Mac's twin is in Mac/App/Shared.
import SwiftUI

struct ConnectivityBanner: View {
    let notice: ConnectivityNotice
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.symbol).foregroundStyle(Theme.color(notice.tone))
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).font(.footnote.weight(.semibold))
                Text(notice.detail()).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectivityBanner")
    }
}
