import SwiftUI

struct StepValues: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your values")
                .font(.title.bold())
            Text("Describe in plain English what you want filtered. The model that compiles this into a policy will ask back if it spots ambiguity.")
                .foregroundStyle(.secondary)
            Picker("Deployment mode", selection: $state.mode) {
                Text("Personal").tag(DeploymentMode.personal)
                Text("Corporate").tag(DeploymentMode.corporate)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            TextEditor(text: $state.valuesText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 280)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("Load from file…") { loadFromFile() }
                Spacer()
                Text("\(state.valuesText.count) characters")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
        }
    }

    private func loadFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let text = try? String(contentsOf: url, encoding: .utf8) {
            state.valuesText = text
        }
    }
}
