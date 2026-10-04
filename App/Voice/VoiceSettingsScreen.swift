// Settings › Voice: the OpenAI API key the voice mode connects with, its voice, how long a silence ends a conversation,
// and what the conversations have taken in time and cost.
import SwiftUI

struct VoiceSettingsScreen: View {
    @ObservedObject private var settings = VoiceSettings.shared
    @ObservedObject private var history = VoiceHistory.shared
    @State private var key = ""
    @State private var error: String?
    @State private var clearing = false

    var body: some View {
        Form {
            Section {
                if settings.hasKey {
                    Label("API key saved on this iPhone", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.success)
                }
                SecureField(settings.hasKey ? "Replace the API key" : "OpenAI API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .accessibilityIdentifier("openAIKey")
                Button("Save key") { attempt { try settings.save(key: key); key = "" } }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                if settings.hasKey {
                    Button("Remove key", role: .destructive) { attempt { try settings.removeKey() } }
                }
                if let error { ErrorNotice(message: error) }
            } header: {
                Text("OpenAI")
            } footer: {
                Text("The voice mode talks to OpenAI with this key, which stays in this iPhone's Keychain.")
            }
            .listRowBackground(Theme.row)

            Section {
                LabeledContent("Model", value: Voice.title)
                Picker("Voice", selection: $settings.voice) {
                    ForEach(Voice.voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Stepper(value: $settings.idleMinutes, in: 0...30) {
                    LabeledContent("End after silence", value: settings.idleMinutes == 0 ? "Never" : "\(settings.idleMinutes) min")
                }
            } header: {
                Text("Conversation")
            } footer: {
                Text("GPT-Realtime mini chooses the actions itself and bills the audio and text it hears and says, and the transcription of your speech apart. A change of voice applies to the next conversation.")
            }
            .listRowBackground(Theme.row)

            usage
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear the usage?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { history.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The time and cost of every voice conversation kept on this iPhone are removed.")
        }
    }

    // MARK: Usage

    private var usage: some View {
        let row = history.tally
        return Section {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Model")
                    Text("Time").gridColumnAlignment(.trailing)
                    Text("Cost").gridColumnAlignment(.trailing)
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Voice.title).font(.subheadline.weight(.medium))
                        Text("\(row.conversations) conversation\(row.conversations == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(VoiceCost.time(row.seconds)).font(.subheadline.monospacedDigit())
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(VoiceCost.dollars(row.dollars)).font(.subheadline.monospacedDigit())
                        Text(row.perMinute.map { "\(VoiceCost.dollars($0))/min" } ?? "—")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .padding(.vertical, 4)
            if !history.records.isEmpty {
                Button("Clear usage", role: .destructive) { clearing = true }
            }
        } header: {
            Text("Usage")
        } footer: {
            Text("Every voice conversation on this iPhone: how long they ran and what they cost, estimated at OpenAI's published prices. OpenAI's bill is the reference.")
        }
        .listRowBackground(Theme.row)
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work(); error = nil } catch { self.error = error.localizedDescription }
    }
}
