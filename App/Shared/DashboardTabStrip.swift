// A shared, scrollable tab strip for dashboards, readable on narrow phones and at large text sizes.
import SwiftUI

struct DashboardTabStrip<Tab: Identifiable & Hashable>: View {
    var tabs: [Tab]
    @Binding var selection: Tab
    var title: (Tab) -> String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(tabs) { tab in
                        Button { selection = tab } label: {
                            Text(title(tab)).font(.subheadline.weight(selection == tab ? .semibold : .regular))
                                .padding(.horizontal, 12).frame(minHeight: 44)
                                .background(selection == tab ? Theme.accent.opacity(0.12) : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(selection == tab ? Theme.accent : Theme.muted)
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                        .id(tab)
                    }
                }.padding(.horizontal).padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, tab in proxy.scrollTo(tab, anchor: .center) }
        }
        .background(.bar)
    }
}
