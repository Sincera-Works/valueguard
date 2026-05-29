import SwiftUI

struct StepEmbedPlaceholder: View {
    @Bindable var state: OnboardingState
    @State private var status: Status = .idle
    @State private var pipelineProgress: PolicyPipeline.Progress?
    @State private var downloadProgress: ModelDownloader.Progress?
    @State private var errorMessage: String?
    @State private var lastFailedAction: FailedAction?
    @State private var downloader = ModelDownloader()

    enum Status { case idle, modelMissing, downloading, embedding, done }

    /// Which action a Retry button should re-run after a failure.
    enum FailedAction { case download, build }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build the policy")
                .font(.title.bold())
            Text("ValueGuard tokenizes each caption locally and runs them through the SigLIP-2 text encoder. The result is a compact policy.bin the daemon mmaps at startup.")
                .foregroundStyle(.secondary)
            Divider()
            content
            Spacer()
        }
        .onAppear { refreshStatus() }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .idle:
            Button("Build policy") { Task { await runPipeline() } }
                .controlSize(.large)
                .disabled(state.parsedPolicy == nil)
        case .modelMissing:
            VStack(alignment: .leading, spacing: 8) {
                Label("Text encoder needs to be installed (~506 MB, one time)", systemImage: "icloud.and.arrow.down")
                Text("Download verifies by SHA-256 before install. If you already have a SigLIP2Text.mlpackage on disk (e.g. from the Python conversion pipeline), you can point us at it instead.")
                    .foregroundStyle(.secondary).font(.callout)
                HStack(spacing: 12) {
                    Button("Download model") { Task { await runDownload() } }
                        .controlSize(.large)
                    Button("Import from disk…") { importFromDisk() }
                        .controlSize(.large)
                    Button("Check again") { refreshStatus() }
                }
            }
        case .downloading:
            VStack(alignment: .leading, spacing: 6) {
                if let p = downloadProgress {
                    ProgressView(value: p.fraction) {
                        Text("Downloading SigLIP-2 text encoder")
                    } currentValueLabel: {
                        Text(progressLabel(p)).font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    ProgressView("Connecting…")
                }
            }
        case .embedding:
            if let p = pipelineProgress {
                ProgressView(value: Double(p.current), total: Double(p.total)) {
                    Text(p.stage).font(.callout)
                } currentValueLabel: {
                    Text("\(p.current) / \(p.total)").font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                ProgressView("Starting embedder…")
            }
        case .done:
            Label("Policy compiled to \(AppSupport.policyBinURL.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(AppSupport.policyBinURL.path)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }

        if let errorMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(errorMessage).font(.callout).foregroundStyle(.secondary)
                }
                if let lastFailedAction {
                    Button("Try again") {
                        switch lastFailedAction {
                        case .download: Task { await runDownload() }
                        case .build: Task { await runPipeline() }
                        }
                    }
                    .controlSize(.large)
                }
            }
        }
    }

    private func refreshStatus() {
        let exists = FileManager.default.fileExists(atPath: AppSupport.textEncoderURL.path)
        if status == .done { return }
        status = exists ? .idle : .modelMissing
    }

    private func progressLabel(_ p: ModelDownloader.Progress) -> String {
        let recvMB = Double(p.bytesReceived) / 1_048_576
        if p.bytesExpected > 0 {
            let totalMB = Double(p.bytesExpected) / 1_048_576
            return String(format: "%.1f / %.1f MB", recvMB, totalMB)
        }
        return String(format: "%.1f MB", recvMB)
    }

    private func importFromDisk() {
        errorMessage = nil
        lastFailedAction = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select SigLIP2Text.mlpackage"
        panel.prompt = "Install"
        // .mlpackage is a directory bundle on disk; allow either form.
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dst = AppSupport.textEncoderURL
        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            refreshStatus()
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func runDownload() async {
        errorMessage = nil
        lastFailedAction = nil
        status = .downloading
        downloadProgress = nil
        do {
            try await downloader.downloadTextEncoder { downloadProgress = $0 }
            refreshStatus()
        } catch {
            errorMessage = error.localizedDescription
            lastFailedAction = .download
            refreshStatus()
        }
    }

    private func runPipeline() async {
        guard let policy = state.parsedPolicy else { return }
        errorMessage = nil
        lastFailedAction = nil
        status = .embedding
        pipelineProgress = nil
        do {
            _ = try await PolicyPipeline.compile(policy: policy) { p in
                pipelineProgress = p
            }
            status = .done
        } catch {
            errorMessage = error.localizedDescription
            lastFailedAction = .build
            status = .idle
        }
    }
}
