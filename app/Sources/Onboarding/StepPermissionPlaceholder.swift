import SwiftUI
import CoreGraphics

struct StepPermissionPlaceholder: View {
    @Bindable var state: OnboardingState
    var onFinish: () -> Void
    @State private var granted = CGPreflightScreenCaptureAccess()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Grant Screen Recording")
                .font(.title.bold())
            Text("ValueGuard needs Screen Recording permission to see what's on your screen. Everything happens on-device — no frames leave the Mac.")
                .foregroundStyle(.secondary)
            if granted {
                Label("Screen Recording is granted.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Request permission") {
                    _ = CGRequestScreenCaptureAccess()
                    granted = CGPreflightScreenCaptureAccess()
                }
                .controlSize(.large)
                Text("If macOS doesn't prompt, open System Settings → Privacy & Security → Screen Recording and enable ValueGuard there.")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
            }
            Spacer()
        }
    }
}
