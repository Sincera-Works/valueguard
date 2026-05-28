import SwiftUI

struct StepCopyPrompt: View {
    @Bindable var state: OnboardingState
    @State private var copied = false

    private var prompt: String {
        PolicyPromptText.fullPrompt(values: state.valuesText, mode: state.mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy this prompt into any chat AI")
                .font(.title.bold())
            Text("Paste it into Claude.ai, ChatGPT, or any tool that can produce JSON. The model will return a policy you'll paste back on the next step.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Link("Open Claude.ai", destination: URL(string: "https://claude.ai/new")!)
                Link("Open ChatGPT", destination: URL(string: "https://chatgpt.com")!)
                Spacer()
                Button {
                    copyToPasteboard()
                } label: {
                    Label(copied ? "Copied" : "Copy to clipboard", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }

            ScrollView {
                Text(prompt)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .border(Color.secondary.opacity(0.3))
        }
    }

    private func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(prompt, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
