import SwiftUI
import Combine

struct OnboardingView: View {
    @Bindable var state: OnboardingState
    var onFinish: () -> Void

    // The embed step builds policy.bin on disk via private internal state, which
    // SwiftUI can't observe. We poll the file while on .embed so the gated
    // Continue button flips enabled the moment the build finishes.
    @State private var policyBinExists = FileManager.default.fileExists(atPath: AppSupport.policyBinURL.path)
    private let policyCheckTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            stepHeader
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            Divider()
            navigation
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear { state.loadPersistedValues() }
        .onReceive(policyCheckTimer) { _ in
            guard state.step == .embed else { return }
            let exists = FileManager.default.fileExists(atPath: AppSupport.policyBinURL.path)
            if exists != policyBinExists { policyBinExists = exists }
        }
    }

    private var stepHeader: some View {
        HStack(spacing: 12) {
            ForEach(OnboardingState.Step.allCases.filter { $0 != .done }) { s in
                stepPill(s)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func stepPill(_ s: OnboardingState.Step) -> some View {
        let active = (s == state.step)
        let done = s.rawValue < state.step.rawValue
        return HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : (active ? "circle.inset.filled" : "circle"))
                .foregroundStyle(done ? .green : (active ? .accentColor : .secondary))
            Text(s.title)
                .font(.caption)
                .foregroundStyle(active ? .primary : .secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.step {
        case .welcome:    StepWelcome(state: state)
        case .values:     StepValues(state: state)
        case .copyPrompt: StepCopyPrompt(state: state)
        case .pasteJSON:  StepPasteJSON(state: state)
        case .embed:      StepEmbedPlaceholder(state: state)
        case .permission: StepPermissionPlaceholder(state: state, onFinish: onFinish)
        case .done:       EmptyView()
        }
    }

    private var navigation: some View {
        HStack {
            if state.step != .welcome && state.step != .done {
                Button("Back") { state.back() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            primaryButton
        }
        .padding(16)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch state.step {
        case .welcome:
            Button("Get started") { state.next() }
                .keyboardShortcut(.defaultAction)
        case .values:
            Button("Next") {
                state.persistValues()
                state.next()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(state.valuesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .copyPrompt:
            Button("I have my JSON, paste it →") { state.next() }
                .keyboardShortcut(.defaultAction)
        case .pasteJSON:
            Button("Next") { state.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(state.parsedPolicy == nil)
        case .embed:
            // Gate on a real policy.bin existing on disk — mirrors how .values
            // and .pasteJSON gate on their own outputs. A failed or skipped embed
            // must not advance into a silently-stopped end state. `policyBinExists`
            // is polled while on this step (see body) so the button flips enabled
            // as soon as the build completes.
            Button("Continue") { state.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!policyBinExists)
        case .permission:
            Button("Finish") { onFinish() }
                .keyboardShortcut(.defaultAction)
        case .done:
            EmptyView()
        }
    }
}
