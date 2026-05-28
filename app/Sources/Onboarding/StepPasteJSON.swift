import SwiftUI

struct StepPasteJSON: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste the policy")
                .font(.title.bold())
            Text("Paste the JSON the AI returned. Backtick fences are stripped automatically.")
                .foregroundStyle(.secondary)

            TextEditor(text: $state.pastedJSON)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 220)
                .border(Color.secondary.opacity(0.3))
                .onChange(of: state.pastedJSON) { _, _ in
                    state.tryParse()
                }

            if let policy = state.parsedPolicy {
                policySummary(policy)
            } else if let err = state.parseError, !state.pastedJSON.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func policySummary(_ policy: Policy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Parsed: \(policy.categories.count) categor\(policy.categories.count == 1 ? "y" : "ies")")
                    .font(.headline)
            }
            ForEach(policy.categories) { cat in
                HStack {
                    Text(cat.id).font(.system(.callout, design: .monospaced))
                    Text("· threshold \(cat.threshold, format: .number.precision(.fractionLength(2)))")
                        .foregroundStyle(.tertiary).font(.caption)
                    Text("· \(cat.positive_captions.count)+\(cat.negative_captions.count) captions")
                        .foregroundStyle(.tertiary).font(.caption)
                    Spacer()
                    Text(cat.action.rawValue.uppercased())
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(actionColor(cat.action).opacity(0.2))
                        .foregroundStyle(actionColor(cat.action))
                        .cornerRadius(4)
                }
            }
            if !policy.clarifications.isEmpty {
                Text("Clarifications the model wants answered:")
                    .font(.headline).padding(.top, 4)
                ForEach(policy.clarifications, id: \.self) { q in
                    Label(q, systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func actionColor(_ a: PolicyAction) -> Color {
        switch a {
        case .log: return .blue
        case .blur: return .orange
        case .block: return .red
        }
    }
}
