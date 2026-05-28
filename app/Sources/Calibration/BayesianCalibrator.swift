import Foundation

/// Bayesian decision-theoretic threshold selection with Kernel Density
/// Estimation, cost-sensitive utility, and a conformal-prediction guarantee
/// for the false-positive rate.
///
/// References:
///   - Bayes 1763, Wald 1950 — decision theory under uncertainty
///   - Silverman 1986 — bandwidth selection rule of thumb
///   - Vovk et al. 2005 — conformal prediction; distribution-free FPR guarantee
///
/// Why KDE rather than Gaussian fit:
///   The calibrate.py mixture mode fits N(μ, σ) per class via maximum
///   likelihood. When the positive samples cluster tightly (e.g., 46 frames
///   of the same page, σ ≈ 0), the Gaussian collapses to a delta and the
///   bisection misses the peak entirely. KDE with Silverman's bandwidth is
///   robust to this regime: each sample contributes a smooth kernel,
///   bandwidth scales with σ but is floored by the sample count.
///
/// Why Bayesian posterior rather than ROC-optimal:
///   The Bayesian posterior P(positive | score) lets the user reason about
///   "for what confidence should I flag?" and expresses the cost trade-off
///   transparently. ROC-optimal threshold collapses to a single point that
///   the user can't tune to their actual deployment risk.
///
/// Why also conformal:
///   When sample counts are small the posterior estimate is noisy. The
///   conformal threshold τ_α = (1−α)-quantile of negative scores
///   guarantees P(score > τ_α | negative) ≤ α empirically, regardless of
///   how well KDE fit the distributions. We use it as a lower bound on the
///   recommended threshold so we never recommend something the empirical
///   negative distribution can already trivially trigger.
struct BayesianCalibrator {
    let positiveScores: [Float]
    let negativeScores: [Float]
    let prior: Double          // P(positive); default 0.5 (uninformative)
    let costRatio: Double      // cost(FN) / cost(FP); default 1.0 (balanced)
    let conformalAlpha: Double // upper-bound target FPR; default 0.05

    init(
        positiveScores: [Float],
        negativeScores: [Float],
        prior: Double = 0.5,
        costRatio: Double = 1.0,
        conformalAlpha: Double = 0.05
    ) {
        self.positiveScores = positiveScores
        self.negativeScores = negativeScores
        self.prior = prior
        self.costRatio = costRatio
        self.conformalAlpha = conformalAlpha
    }

    /// Silverman's rule-of-thumb bandwidth.
    /// h = 1.06 * σ * n^(-1/5). Floored for tiny σ so small clusters of
    /// near-identical samples don't collapse to a delta.
    private static func bandwidth(of samples: [Float]) -> Double {
        let n = Double(samples.count)
        guard n > 1 else { return 0.02 }
        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.reduce(0.0) { acc, x in acc + Double(x - mean) * Double(x - mean) } / n
        let sigma = sqrt(variance)
        let h = 1.06 * sigma * pow(n, -0.2)
        return max(h, 0.005) // floor: prevents collapse to delta with concentrated samples
    }

    /// Gaussian kernel.
    private static func kernel(_ u: Double) -> Double {
        exp(-0.5 * u * u) / sqrt(2.0 * .pi)
    }

    /// f(s) = (1/(n·h)) · Σ K((s - sᵢ)/h)
    private static func density(at score: Float, samples: [Float], bandwidth h: Double) -> Double {
        guard !samples.isEmpty, h > 0 else { return 0 }
        let s = Double(score)
        var sum = 0.0
        for x in samples { sum += kernel((s - Double(x)) / h) }
        return sum / (Double(samples.count) * h)
    }

    /// Posterior P(positive | score = s) under the Bayesian decomposition.
    func posterior(at score: Float) -> Double {
        let hp = Self.bandwidth(of: positiveScores)
        let hn = Self.bandwidth(of: negativeScores)
        let fp = Self.density(at: score, samples: positiveScores, bandwidth: hp)
        let fn = Self.density(at: score, samples: negativeScores, bandwidth: hn)
        let num = prior * fp
        let den = num + (1 - prior) * fn
        return den == 0 ? 0 : num / den
    }

    /// Conformal threshold: the (1-α)-quantile of the negative scores.
    /// Guarantees empirical FPR ≤ α on the negative sample.
    func conformalThreshold() -> Float? {
        guard !negativeScores.isEmpty else { return nil }
        let sorted = negativeScores.sorted()
        let q = 1.0 - conformalAlpha
        let idx = min(sorted.count - 1, Int(ceil(q * Double(sorted.count))) - 1)
        return sorted[max(0, idx)]
    }

    /// Bayesian-optimal threshold: τ such that P(positive | τ) = 1/(1+r).
    /// Found by bisection over the union of observed score ranges.
    func bayesianThreshold() -> Float {
        let allScores = positiveScores + negativeScores
        guard let lo = allScores.min(), let hi = allScores.max() else { return 0 }
        let target = 1.0 / (1.0 + costRatio)
        var a = Double(lo) - 0.01
        var b = Double(hi) + 0.01
        // Posterior is monotonically non-decreasing in score under our
        // assumptions (positives dominate at high score, negatives at low).
        // Bisect.
        for _ in 0..<80 {
            let mid = (a + b) / 2
            if posterior(at: Float(mid)) < target {
                a = mid
            } else {
                b = mid
            }
        }
        return Float((a + b) / 2)
    }

    /// Recommended threshold: the Bayesian optimum, floored by the
    /// conformal guarantee. We add a small epsilon to the conformal
    /// floor so we strictly exceed the negative tail rather than ties.
    func recommendedThreshold() -> Float {
        let bayes = bayesianThreshold()
        guard let conf = conformalThreshold() else { return bayes }
        return max(bayes, conf + 0.001)
    }

    /// Empirical false-positive rate at the given threshold.
    func empiricalFPR(at threshold: Float) -> Double {
        guard !negativeScores.isEmpty else { return 0 }
        return Double(negativeScores.filter { $0 > threshold }.count) / Double(negativeScores.count)
    }

    /// Empirical false-negative rate at the given threshold.
    func empiricalFNR(at threshold: Float) -> Double {
        guard !positiveScores.isEmpty else { return 0 }
        return Double(positiveScores.filter { $0 <= threshold }.count) / Double(positiveScores.count)
    }

    /// Sample the posterior curve over the observed score range.
    func sampledPosterior(steps: Int = 100) -> [(score: Float, posterior: Double)] {
        let allScores = positiveScores + negativeScores
        guard let lo = allScores.min(), let hi = allScores.max(), steps > 1 else { return [] }
        var out: [(Float, Double)] = []
        out.reserveCapacity(steps)
        for i in 0..<steps {
            let t = Double(i) / Double(steps - 1)
            let s = Double(lo) + t * Double(hi - lo)
            out.append((Float(s), posterior(at: Float(s))))
        }
        return out
    }
}
