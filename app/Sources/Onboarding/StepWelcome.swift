import SwiftUI

struct StepWelcome: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Welcome to ValueGuard")
                .font(.largeTitle.bold())
            Text("ValueGuard samples your screen on-device and filters what you have told it to filter. Pixels never leave this Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Setup has four steps:")
                .font(.headline)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 6) {
                Label("Write a short values statement.", systemImage: "1.circle")
                Label("Copy a prompt into any chat AI (Claude.ai, ChatGPT). Paste the JSON back here.", systemImage: "2.circle")
                Label("ValueGuard downloads a 539 MB model the first time, then compiles your policy locally.", systemImage: "3.circle")
                Label("Grant Screen Recording so the daemon can see what's on screen.", systemImage: "4.circle")
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
