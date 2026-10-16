// Settings kept on this phone or iPad rather than on the server: voice mode, and when the app falls asleep to show the
// sessions' work (SleepMode/).
import SwiftUI

struct DeviceSettingsSections: View {
    @ObservedObject private var sleep = SleepModel.shared

    var body: some View {
        Section {
            DestinationLink(destination: .voiceSettings) {
                Label("Voice", systemImage: "waveform")
            }
        } footer: {
            Text("The OpenAI API key a project's voice conversation talks to GPT-Realtime with, and what its conversations have cost.")
        }
        .listRowBackground(Theme.row)
        Section {
            Picker(selection: $sleep.sleepAfter) {
                ForEach(sleepAfterChoices, id: \.self) { Text(sleepAfterLabel($0)).tag($0) }
            } label: {
                Label("Sleep after", systemImage: "moon.zzz")
            }
        } footer: {
            Text("Untouched this long, the app shows the files your sessions write and the commands they run. A touch wakes it.")
        }
        .listRowBackground(Theme.row)
    }
}
