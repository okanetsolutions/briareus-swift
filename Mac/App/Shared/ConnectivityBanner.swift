// The one notice across the top of a window while the link to the server is lost (Core's ConnectivityNotice):
// offline, or a server that stopped answering, and when what is on screen was saved. The iPhone's twin is in App/Shared.
import SwiftUI

struct ConnectivityBanner: View {
    let notice: ConnectivityNotice
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: notice.symbol).foregroundStyle(Theme.color(notice.tone))
            Text(notice.title).font(Theme.footnoteSemibold)
            Text(notice.detail()).font(Theme.footnote).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Theme.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectivityBanner")
    }
}

private struct ConnectivityBannerInset: ViewModifier {
    @EnvironmentObject private var store: Store

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if let notice = store.linkNotice { ConnectivityBanner(notice: notice) }
        }
    }
}

extension View {
    func withConnectivityBanner() -> some View { modifier(ConnectivityBannerInset()) }
}
