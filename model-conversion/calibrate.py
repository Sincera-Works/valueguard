"""Fit per-category SigLIP-2 score distributions and emit principled thresholds.

Two modes, picked automatically:

  Label-free (default): assume the scores log is dominated by safe content
  (true positives are rare). Fit a Normal to the observed pos-score
  distribution per category. Suggested threshold = mu + Phi^-1(1 - alpha)*sigma
  for the chosen target false-positive rate alpha.

  Labels-bearing (if --positives is supplied): build a Gaussian mixture with
  prior P(unsafe) = --base-rate, and find x* such that P(unsafe | x*) equals
  --target-precision. Properly Bayesian — answers "given this score, how
  confident should I be?"

Inputs:
  --scores-log   NDJSON file written by `valueguard --scores-log`. Required.
  --policy       Input policy.json (compiled by policy-compiler). Required.
  --positives    Optional JSONL of true-positive pos scores per category.
                 Format: {"category": "...", "pos": 0.27}
  --policy-out   Where to write the policy.json with updated thresholds.
  --report-out   Where to write the calibration-report.md (histograms etc).

Knobs:
  --target-fp-rate     Label-free threshold = mu + z*sigma where Phi(z) = 1-alpha.
                       Default 0.001.
  --target-precision   Posterior precision target for the mixture mode.
                       Default 0.95.
  --base-rate          Prior P(unsafe) for the mixture mode. Default 0.001.

Outputs:
  - <policy-out>.json with new thresholds (same shape, all other fields
    unchanged). Caption embeddings in the .bin must be re-built afterward
    with embed_captions.py if any other field changed; for threshold-only
    updates the existing .bin can be edited in place by re-running
    embed_captions.py against the new .json.

  - <report-out>.md: per-category histograms, statistics (n, mu, sigma, min,
    max, p10/50/90/99), suggested threshold + the method used, and the
    threshold's percentile in the observed distribution.
"""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Optional

try:
    from scipy.stats import norm  # type: ignore[import-untyped]
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False


def inv_normal_cdf(p: float) -> float:
    """Phi^-1(p). Uses scipy if available, falls back to Acklam's approximation."""
    if HAS_SCIPY:
        return float(norm.ppf(p))
    # Acklam's algorithm, accurate to ~1e-9 over (0, 1)
    a = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
         1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
    b = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
         6.680131188771972e+01, -1.328068155288572e+01]
    c = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
         -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
    d = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
         3.754408661907416e+00]
    plow = 0.02425
    phigh = 1 - plow
    if p < plow:
        q = math.sqrt(-2 * math.log(p))
        return (((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / \
               ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)
    if p <= phigh:
        q = p - 0.5
        r = q * q
        return (((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q / \
               (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1)
    q = math.sqrt(-2 * math.log(1 - p))
    return -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) / \
            ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1)


def normal_pdf(x: float, mu: float, sigma: float) -> float:
    if sigma <= 0:
        return 0.0
    return math.exp(-0.5 * ((x - mu) / sigma) ** 2) / (sigma * math.sqrt(2 * math.pi))


def find_posterior_threshold(
    mu_safe: float, sigma_safe: float,
    mu_unsafe: float, sigma_unsafe: float,
    prior_unsafe: float, target_precision: float,
) -> float:
    """Find x* such that P(unsafe | x*) = target_precision via bisection."""
    def posterior(x: float) -> float:
        p_unsafe = prior_unsafe * normal_pdf(x, mu_unsafe, sigma_unsafe)
        p_safe = (1 - prior_unsafe) * normal_pdf(x, mu_safe, sigma_safe)
        if p_unsafe + p_safe == 0:
            return 0.0
        return p_unsafe / (p_unsafe + p_safe)

    lo = min(mu_safe, mu_unsafe)
    hi = max(mu_unsafe + 5 * sigma_unsafe, mu_safe + 6 * sigma_safe)
    for _ in range(60):
        mid = (lo + hi) / 2
        if posterior(mid) < target_precision:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def quantile(values: list[float], q: float) -> float:
    """Linear-interpolation quantile. q in [0, 1]."""
    if not values:
        return float("nan")
    s = sorted(values)
    pos = q * (len(s) - 1)
    lo = int(pos)
    hi = min(lo + 1, len(s) - 1)
    frac = pos - lo
    return s[lo] * (1 - frac) + s[hi] * frac


def ascii_histogram(values: list[float], bins: int = 24, width: int = 50,
                    marker: Optional[float] = None) -> str:
    if not values:
        return "(no data)"
    lo, hi = min(values), max(values)
    if hi - lo < 1e-9:
        return f"  {lo:.4f}: {len(values)} (degenerate, all equal)"
    bin_width = (hi - lo) / bins
    counts = [0] * bins
    for v in values:
        i = min(int((v - lo) / bin_width), bins - 1)
        counts[i] += 1
    max_count = max(counts)
    lines = []
    for i in range(bins):
        bin_lo = lo + i * bin_width
        bin_hi = bin_lo + bin_width
        bar_len = int(round(width * counts[i] / max_count)) if max_count else 0
        bar = "#" * bar_len
        # Mark the threshold position with a vertical bar in the row that contains it.
        mark = ""
        if marker is not None and bin_lo <= marker < bin_hi:
            mark = f"  <-- threshold {marker:.4f}"
        lines.append(f"  {bin_lo:8.4f}  {counts[i]:5d}  {bar}{mark}")
    return "\n".join(lines)


def load_scores(path: Path) -> dict[str, list[float]]:
    out: dict[str, list[float]] = defaultdict(list)
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            if e.get("type") != "sample":
                continue
            out[e["category"]].append(float(e["pos"]))
    return out


def load_positives(path: Optional[Path]) -> dict[str, list[float]]:
    out: dict[str, list[float]] = defaultdict(list)
    if path is None:
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except json.JSONDecodeError:
                continue
            out[e["category"]].append(float(e["pos"]))
    return out


def percentile_of(value: float, dist: list[float]) -> float:
    """What fraction of dist is below value? 0..1."""
    if not dist:
        return float("nan")
    below = sum(1 for x in dist if x < value)
    return below / len(dist)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scores-log", type=Path, required=True)
    ap.add_argument("--policy", type=Path, required=True)
    ap.add_argument("--policy-out", type=Path, required=True)
    ap.add_argument("--positives", type=Path, default=None)
    ap.add_argument("--report-out", type=Path, default=None)
    ap.add_argument("--target-fp-rate", type=float, default=0.001)
    ap.add_argument("--target-precision", type=float, default=0.95)
    ap.add_argument("--base-rate", type=float, default=0.001,
                    help="Prior P(unsafe) for the mixture-model mode")
    args = ap.parse_args()

    if not args.scores_log.exists():
        print(f"error: scores log not found: {args.scores_log}", file=sys.stderr)
        return 1
    if not args.policy.exists():
        print(f"error: policy not found: {args.policy}", file=sys.stderr)
        return 1

    scores = load_scores(args.scores_log)
    positives = load_positives(args.positives)
    policy = json.loads(args.policy.read_text())

    if not HAS_SCIPY:
        print("info: scipy not installed; using built-in Phi^-1 (still accurate)")

    report: list[str] = []
    report.append("# ValueGuard calibration report\n")
    report.append(f"- Source: `{args.scores_log}`")
    report.append(f"- Policy in: `{args.policy}`")
    report.append(f"- Policy out: `{args.policy_out}`")
    if args.positives:
        report.append(f"- Positives: `{args.positives}`")
        report.append(f"- Method: Gaussian mixture, target_precision={args.target_precision}, base_rate={args.base_rate}")
    else:
        report.append(f"- Method: label-free Normal fit, target_fp_rate={args.target_fp_rate}")
    report.append("")

    print(f"{'category':<35} {'n':>5} {'μ':>8} {'σ':>8} {'old':>8} {'new':>8} {'method':<22} {'pos in dist':>12}")
    print("-" * 124)

    for cat in policy["categories"]:
        cid = cat["id"]
        xs = scores.get(cid, [])
        pos_xs = positives.get(cid, [])

        old_threshold = float(cat["threshold"])

        if not xs:
            print(f"  {cid}: no samples in scores log; threshold unchanged")
            continue

        n = len(xs)
        mu_safe = statistics.mean(xs)
        sigma_safe = statistics.stdev(xs) if n > 1 else 0.0

        if len(pos_xs) >= 3 and sigma_safe > 0:
            mu_unsafe = statistics.mean(pos_xs)
            sigma_unsafe = statistics.stdev(pos_xs) if len(pos_xs) > 1 else max(sigma_safe, 0.02)
            new_threshold = find_posterior_threshold(
                mu_safe, sigma_safe, mu_unsafe, sigma_unsafe,
                args.base_rate, args.target_precision,
            )
            method = f"mixture (n_pos={len(pos_xs)})"
        else:
            # Label-free anomaly detection
            z = inv_normal_cdf(1 - args.target_fp_rate)
            new_threshold = mu_safe + z * sigma_safe
            method = f"anomaly (z={z:.2f})"

        cat["threshold"] = round(float(new_threshold), 4)

        pct = percentile_of(new_threshold, xs) * 100
        print(f"  {cid:<33} {n:>5} {mu_safe:>8.4f} {sigma_safe:>8.4f} {old_threshold:>8.4f} {new_threshold:>8.4f}  {method:<22} {pct:>10.2f}%")

        report.append(f"\n## {cid}\n")
        report.append(f"- **Method**: {method}")
        report.append(f"- **n samples**: {n}")
        report.append(f"- **μ_safe**: {mu_safe:.4f}")
        report.append(f"- **σ_safe**: {sigma_safe:.4f}")
        if pos_xs:
            report.append(f"- **n positives**: {len(pos_xs)}")
            report.append(f"- **μ_unsafe**: {statistics.mean(pos_xs):.4f}")
            report.append(f"- **σ_unsafe**: {statistics.stdev(pos_xs) if len(pos_xs) > 1 else 0:.4f}")
        report.append(f"- **Quantiles**: p10={quantile(xs, 0.10):.4f}, p50={quantile(xs, 0.50):.4f}, "
                      f"p90={quantile(xs, 0.90):.4f}, p99={quantile(xs, 0.99):.4f}")
        report.append(f"- **Old threshold**: {old_threshold:.4f}")
        report.append(f"- **New threshold**: {new_threshold:.4f}  (sits at {pct:.2f} percentile of observed)")
        report.append("")
        report.append("```")
        report.append(ascii_histogram(xs, marker=new_threshold))
        report.append("```")

    # Write outputs
    with open(args.policy_out, "w") as f:
        json.dump(policy, f, indent=2)
    print(f"\nWrote {args.policy_out}")

    if args.report_out:
        args.report_out.write_text("\n".join(report) + "\n")
        print(f"Wrote {args.report_out}")

    print("\nNext step: re-embed the policy and rerun the daemon")
    print(f"  python embed_captions.py {args.policy_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
