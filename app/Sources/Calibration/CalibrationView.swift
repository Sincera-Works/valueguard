import SwiftUI

struct CalibrationView: View {
    var onRestartDaemon: () -> Void

    @State private var policy: Policy?
    @State private var selectedCategoryID: String?
    @State private var status: Status = .idle
    @State private var progress: HeadlessCalibrator.Progress?
    @State private var result: HeadlessCalibrator.Result?
    @State private var error: String?
    @State private var calibrator = HeadlessCalibrator()

    // Bayesian knobs. Defaults are tuned for content-filter use (low prior,
    // FP costlier than FN, tight conformal FPR ceiling). Presets below
    // rebind all three for common deployment contexts.
    @State private var prior: Double = 0.05
    @State private var costRatio: Double = 0.3
    @State private var conformalAlpha: Double = 0.02
    @State private var preset: Preset = .general

    enum Preset: String, CaseIterable, Identifiable {
        case recovery, workplace, general, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recovery: return "Recovery"
            case .workplace: return "Workplace"
            case .general: return "General content"
            case .custom: return "Custom"
            }
        }
        var description: String {
            switch self {
            case .recovery:  return "Explicit-content filter for recovery contexts. High recall: better to fire on something borderline than miss a true positive. False negatives are far worse than false positives."
            case .workplace: return "Not-safe-for-work filter for shared screens. Very high precision: a false fire on a colleague's photo erodes trust badly. Some misses are tolerated."
            case .general:   return "Balanced consumer-content filter. False positives moderately worse than false negatives. Sensible starting point for most categories."
            case .custom:    return "Manually-set sliders. Untouched by preset changes."
            }
        }
        // (prior, costRatio, conformalAlpha)
        var values: (Double, Double, Double)? {
            switch self {
            case .recovery:  return (0.01, 3.0,  0.10)
            case .workplace: return (0.05, 0.15, 0.01)
            case .general:   return (0.05, 0.3,  0.02)
            case .custom:    return nil
            }
        }
    }

    enum Status { case idle, running, done }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                Divider()
                content
                Spacer()
            }
            .padding()
        }
        .onAppear { loadPolicy() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bayesian calibration")
                .font(.title3.bold())
            Text("Fetches positive and negative sample images from Wikimedia Commons, scores each via the on-device vision encoder, and fits a Bayesian posterior with a conformal false-positive guarantee. Images are processed in memory and never displayed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let policy {
            HStack {
                Picker("Category", selection: $selectedCategoryID) {
                    Text("Choose a category").tag(String?.none)
                    ForEach(policy.categories) { cat in
                        Text(cat.id).tag(String?.some(cat.id))
                    }
                }
                .pickerStyle(.menu)
                Spacer()
                if status == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Calibrate") { Task { await runCalibration() } }
                        .disabled(selectedCategoryID == nil)
                }
            }

            knobsBox

            progressOrResult
        } else {
            Text("No policy installed yet. Finish onboarding first.")
                .foregroundStyle(.secondary)
        }
        if let error {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var knobsBox: some View {
        GroupBox("Priors & cost") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Preset", selection: $preset) {
                        ForEach(Preset.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: preset) { _, newValue in
                        if let v = newValue.values {
                            prior = v.0
                            costRatio = v.1
                            conformalAlpha = v.2
                        }
                    }
                }
                Text(preset.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Prior P(positive):")
                    Slider(value: $prior, in: 0.001...0.99)
                        .onChange(of: prior) { _, _ in preset = .custom }
                    Text(String(format: "%.3f", prior)).font(.body.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .help("How often you expect a sampled frame to actually match this category. Lower = stricter. For most content-filter categories this is 0.001 to 0.05.")
                HStack {
                    Text("Cost ratio (FN / FP):")
                    Slider(value: $costRatio, in: 0.05...10.0)
                        .onChange(of: costRatio) { _, _ in preset = .custom }
                    Text(String(format: "%.2f×", costRatio)).font(.body.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .help("How much worse is missing a true positive than firing on a false positive. >1 favors recall (recovery-style); <1 favors precision (workplace-style).")
                HStack {
                    Text("Conformal α (FPR ceiling):")
                    Slider(value: $conformalAlpha, in: 0.005...0.20)
                        .onChange(of: conformalAlpha) { _, _ in preset = .custom }
                    Text(String(format: "%.3f", conformalAlpha)).font(.body.monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                .help("Distribution-free guarantee: at most this fraction of negative samples will score above the recommended threshold.")
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var progressOrResult: some View {
        if let progress, status == .running {
            VStack(alignment: .leading, spacing: 4) {
                Text(progress.stage).font(.callout)
                ProgressView(value: Double(progress.current), total: Double(progress.total))
                Text("\(progress.current) / \(progress.total)")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        if let result, status == .done {
            resultPanel(result)
        }
    }

    @ViewBuilder
    private func resultPanel(_ r: HeadlessCalibrator.Result) -> some View {
        let oldThreshold = currentThreshold() ?? 0
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(positiveCountSummary(r))
                    .font(.headline)
            }

            if r.positiveSource == .captionAnchored {
                captionAnchoredBanner
            }

            separabilityBanner(r.separability)

            GroupBox("Score distributions (positive = orange, negative = blue)") {
                bilateralHistogram(positives: r.positiveScores, negatives: r.negativeScores,
                                   threshold: r.suggestedThreshold)
                    .padding(8)
            }

            GroupBox("Posterior P(positive | score)") {
                posteriorCurveView(r.posteriorCurve, threshold: r.suggestedThreshold,
                                   target: 1.0 / (1.0 + r.costRatio))
                    .padding(8)
            }

            metricsGrid(r)

            HStack {
                Text("Current threshold:")
                Text(String(format: "%.4f", oldThreshold)).font(.body.monospacedDigit())
                Text("→")
                Text(String(format: "%.4f", r.suggestedThreshold))
                    .font(.body.monospacedDigit().bold())
                Spacer()
                Button("Apply") { applyThreshold(r.suggestedThreshold) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    /// Summary line above the result panel. Reflects HOW the positives were
    /// obtained: for the caption-anchored fallback we say "N caption anchors"
    /// rather than "N positive samples", so a successful fit on a category with
    /// no fetchable positive images doesn't read as a confusing "0 positives".
    private func positiveCountSummary(_ r: HeadlessCalibrator.Result) -> String {
        let neg = "\(r.negativeScores.count) negative samples"
        switch r.positiveSource {
        case .images:
            return "\(r.positiveScores.count) positive samples, \(neg)"
        case .captionAnchored:
            return "\(r.positiveScores.count) caption anchors, \(neg)"
        case .none:
            return "0 positive samples, \(neg)"
        }
    }

    /// Informational (not error) banner shown when the positive side was
    /// calibrated from re-embedded captions because no positive sample images
    /// exist for the category in the moderated calibration source. Styled blue
    /// to stand apart from the red error banners.
    private var captionAnchoredBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibrated against captions (no positive images available)")
                    .font(.callout.bold())
                Text("No positive sample images exist for this category in the calibration source. Calibrated against the category's positive captions instead — re-embedded on-device through the text encoder, no images fetched. The threshold bounds false positives on benign content; recall is anchored to the author's captions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func separabilityBanner(_ s: HeadlessCalibrator.Separability) -> some View {
        switch s {
        case .clean(let gap):
            Label("Clean separation — gap \(String(format: "%.4f", gap)) between p95(neg) and p05(pos).", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .padding(.vertical, 4)
        case .overlapping(let margin):
            VStack(alignment: .leading) {
                Label("Distributions overlap by \(String(format: "%.4f", margin)). Your captions can't fully discriminate this category.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("The Bayesian recommendation is precision-priority (it stays above the negative tail), which will miss some positives. Consider sharpening positive captions or adding more pointed negative captions for the cases that overlap.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .noPositives:
            Label("No positive samples fetched.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .noNegatives:
            Label("No negative samples fetched. Conformal guarantee can't be computed.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private func bilateralHistogram(positives: [Float], negatives: [Float], threshold: Float) -> some View {
        let bins = 24
        let all = positives + negatives
        let lo = all.min() ?? 0
        let hi = all.max() ?? 1
        let span = max(Double(hi - lo), 1e-6)
        func counts(_ src: [Float]) -> [Int] {
            var c = Array(repeating: 0, count: bins)
            for s in src {
                let idx = min(bins - 1, max(0, Int(Double(s - lo) / span * Double(bins))))
                c[idx] += 1
            }
            return c
        }
        let pos = counts(positives)
        let neg = counts(negatives)
        let maxCount = max(pos.max() ?? 1, neg.max() ?? 1, 1)
        let threshBin = min(bins - 1, max(0, Int(Double(threshold - lo) / span * Double(bins))))
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<bins, id: \.self) { i in
                    ZStack(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.blue.opacity(0.55))
                            .frame(width: 14, height: CGFloat(neg[i]) / CGFloat(maxCount) * 80 + 1)
                        Rectangle()
                            .fill(Color.orange.opacity(0.75))
                            .frame(width: 14, height: CGFloat(pos[i]) / CGFloat(maxCount) * 80 + 1)
                            .offset(y: -CGFloat(neg[i]) / CGFloat(maxCount) * 40)
                    }
                    .overlay(alignment: .bottom) {
                        if i == threshBin {
                            Rectangle().fill(Color.red).frame(width: 2, height: 100)
                        }
                    }
                }
            }
            HStack {
                Text(String(format: "%.3f", lo)).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("τ = \(String(format: "%.4f", threshold))")
                    .font(.caption2).foregroundStyle(.red)
                Spacer()
                Text(String(format: "%.3f", hi)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func posteriorCurveView(_ curve: [(score: Float, posterior: Double)], threshold: Float, target: Double) -> some View {
        guard !curve.isEmpty else { return AnyView(EmptyView()) }
        let lo = curve.first!.score
        let hi = curve.last!.score
        let span = max(Double(hi - lo), 1e-6)
        let width: CGFloat = 480
        let height: CGFloat = 80
        let path = Path { p in
            for (i, point) in curve.enumerated() {
                let x = CGFloat(Double(point.score - lo) / span) * width
                let y = height - CGFloat(point.posterior) * height
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
        let threshX = CGFloat(Double(threshold - lo) / span) * width
        let targetY = height - CGFloat(target) * height
        return AnyView(
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.secondary.opacity(0.08))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: targetY))
                    p.addLine(to: CGPoint(x: width, y: targetY))
                }.stroke(Color.gray.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                path.stroke(Color.accentColor, lineWidth: 2)
                Rectangle().fill(Color.red).frame(width: 2, height: height).offset(x: threshX)
                Text("posterior target \(String(format: "%.2f", target))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .offset(x: 4, y: targetY - 14)
            }
            .frame(width: width, height: height)
        )
    }

    private func metricsGrid(_ r: HeadlessCalibrator.Result) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Bayesian-optimal τ:").foregroundStyle(.secondary)
                Text(String(format: "%.4f", r.bayesianThreshold)).font(.body.monospacedDigit())
                Text("posterior = 1 / (1 + r)").font(.caption).foregroundStyle(.tertiary)
            }
            GridRow {
                Text("Conformal τ (α=\(String(format: "%.3f", r.conformalAlpha))):").foregroundStyle(.secondary)
                Text(r.conformalThreshold.map { String(format: "%.4f", $0) } ?? "—")
                    .font(.body.monospacedDigit())
                Text("guarantees FPR ≤ α empirically").font(.caption).foregroundStyle(.tertiary)
            }
            GridRow {
                Text("Recommended τ:").foregroundStyle(.secondary)
                Text(String(format: "%.4f", r.suggestedThreshold)).font(.body.monospacedDigit().bold())
                Text("max(bayes, conformal)").font(.caption).foregroundStyle(.tertiary)
            }
            Divider().gridCellColumns(3)
            GridRow {
                Text("Empirical FPR @ recommended:").foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", r.empiricalFPR * 100)).font(.body.monospacedDigit())
                Text("of negatives that would fire").font(.caption).foregroundStyle(.tertiary)
            }
            GridRow {
                Text("Empirical FNR @ recommended:").foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", r.empiricalFNR * 100)).font(.body.monospacedDigit())
                Text("of positives that would miss").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func loadPolicy() {
        guard let data = try? Data(contentsOf: AppSupport.policyJSONURL) else {
            policy = nil
            return
        }
        policy = try? JSONDecoder().decode(Policy.self, from: data)
        if selectedCategoryID == nil, let first = policy?.categories.first {
            selectedCategoryID = first.id
        }
    }

    private func currentThreshold() -> Float? {
        guard let id = selectedCategoryID else { return nil }
        return policy?.categories.first { $0.id == id }.map { Float($0.threshold) }
    }

    private func loadValuesText() -> String {
        (try? String(contentsOf: AppSupport.valuesURL, encoding: .utf8)) ?? ""
    }

    private func runCalibration() async {
        guard let id = selectedCategoryID,
              let cat = policy?.categories.first(where: { $0.id == id }) else { return }
        status = .running
        error = nil
        result = nil
        progress = nil
        do {
            let r = try await calibrator.calibrate(
                category: cat,
                valuesText: loadValuesText(),
                prior: prior,
                costRatio: costRatio,
                conformalAlpha: conformalAlpha
            ) { p in
                progress = p
            }
            result = r
            status = .done
        } catch {
            self.error = error.localizedDescription
            status = .idle
        }
    }

    private func applyThreshold(_ threshold: Float) {
        guard let id = selectedCategoryID else { return }
        do {
            try PolicyBinaryPatcher.writeThreshold(threshold, forCategoryID: id, in: AppSupport.policyBinURL)
            if var policy {
                if let idx = policy.categories.firstIndex(where: { $0.id == id }) {
                    let c = policy.categories[idx]
                    let updated = PolicyCategory(
                        id: c.id, description: c.description,
                        positive_captions: c.positive_captions, negative_captions: c.negative_captions,
                        threshold: Double(threshold), threshold_note: c.threshold_note + " (Bayesian + conformal calibration)",
                        action: c.action
                    )
                    var cats = policy.categories
                    cats[idx] = updated
                    let newPolicy = Policy(categories: cats, clarifications: policy.clarifications, calibration_note: policy.calibration_note)
                    if let data = try? JSONEncoder().encode(newPolicy) {
                        try? data.write(to: AppSupport.policyJSONURL)
                    }
                    self.policy = newPolicy
                }
            }
            onRestartDaemon()
        } catch {
            self.error = "Apply failed: \(error.localizedDescription)"
        }
    }
}
