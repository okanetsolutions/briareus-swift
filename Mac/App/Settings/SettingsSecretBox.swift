// A settings form's write-only box: one the server keeps sealed and never sends back (a token, a password, a set of
// headers). Empty, its cue says what is stored; under it, when something is, a check removes it on save.
import SwiftUI

struct SettingsSecretBox<FocusKey: Hashable>: View {
    /// The field, its cue already saying what is stored or that it goes on save.
    var def: SettingsField
    @Binding var text: String
    var hint: String? = nil
    var focus: FocusState<FocusKey?>.Binding
    var key: FocusKey
    /// Whether the server holds a value for it, which the check offers to remove.
    var stored: Bool
    var removing: Bool
    var removeLabel: String
    var onToggleRemove: () -> Void
    var onSubmit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsFieldBox(def: def, text: $text, hint: hint, focus: focus, key: key, onSubmit: onSubmit)
            if stored {
                SettingsCheck(label: removeLabel, on: removing, height: 24, action: onToggleRemove)
                    .padding(.top, -6).padding(.bottom, 10)
            }
        }
    }
}
