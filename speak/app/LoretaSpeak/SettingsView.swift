import SwiftUI

struct SettingsView: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Transcripts") {
                Button("Show Transcripts in Finder") {
                    settingsStore.revealTranscriptsFolderInFinder()
                }
                Text("Transcripts and audio clips are saved locally to ~/Documents/Loreta Speak/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local LLM Cleanup") {
                Toggle(
                    "Clean up transcripts with a local LLM",
                    isOn: $settingsStore.llmTransformationEnabled
                )

                VStack(alignment: .leading, spacing: 6) {
                    Text("Cleanup instructions")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $settingsStore.llmInstructions)
                        .font(.body)
                        .frame(minHeight: 120)
                        .disabled(!settingsStore.llmTransformationEnabled)
                        .opacity(settingsStore.llmTransformationEnabled ? 1.0 : 0.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                    Text("These instructions control how Loreta cleans each transcript.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
    }
}
