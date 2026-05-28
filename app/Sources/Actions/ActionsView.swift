import SwiftUI

struct ActionsView: View {
    @Bindable var overrides: ActionOverrides

    @State private var policy: Policy?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                if let policy {
                    categoriesList(policy)
                } else {
                    Text("No policy installed yet.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .onAppear { loadPolicy() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Actions").font(.title3.bold())
            Text("What happens when a category fires. The daemon always writes to the audit log; pick what should happen on top of that, per category.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func categoriesList(_ policy: Policy) -> some View {
        VStack(spacing: 4) {
            ForEach(policy.categories) { cat in
                row(for: cat)
            }
        }
    }

    private func row(for cat: PolicyCategory) -> some View {
        let current = overrides.action(for: cat.id)
        return HStack(spacing: 12) {
            Image(systemName: current.symbol)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(cat.id).font(.system(.body, design: .monospaced))
                Text(cat.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { overrides.action(for: cat.id) },
                set: { overrides.set($0, for: cat.id) }
            )) {
                ForEach(UserAction.allCases) { a in
                    Text(a.label).tag(a)
                }
            }
            .labelsHidden()
            .frame(width: 140)
        }
        .padding(.vertical, 4)
    }

    private func loadPolicy() {
        guard let data = try? Data(contentsOf: AppSupport.policyJSONURL) else {
            policy = nil
            return
        }
        policy = try? JSONDecoder().decode(Policy.self, from: data)
    }
}
