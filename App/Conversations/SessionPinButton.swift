// A conversation's pin control uses the same serialized mutation path as its other edits.
import SwiftUI

struct SessionPinButton: View {
    @ObservedObject var model: ConversationScreenModel
    @EnvironmentObject private var store: Store

    var body: some View {
        if store.supports("pin") {
            Button(model.session.pinLabel, systemImage: model.session.pinSymbol) {
                model.mutate("pin", model.session.pinBody)
            }.disabled(!model.can)
        }
    }
}
