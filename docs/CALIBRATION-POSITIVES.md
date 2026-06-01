# Calibrating categories whose positives can't be safely sampled

Design note. Status: **proposal, not implemented.** Written 2026-06-01 after the
in-app Bayesian calibrator returned `0 positive / 14 negative` for
`sexualized_nudity_contemporary` (a `sincera/personal-values` category).

## The problem

The in-app calibrator (`app/Sources/Calibration/`) fits a Bayesian posterior +
conformal FPR ceiling from two image corpora:

- **positives** — images matching the category's `positive_captions`
- **negatives** — images matching `negative_captions` + the user's "okay with X"
  exclusions

Both are fetched from **Wikimedia Commons** (`WikimediaImageFetcher`). Commons is
chosen deliberately (no API key, public-domain, heavily moderated → never serves
anything illegal). For a category like `domestic_dogs` this works great: Commons
is full of dogs (positives) and non-dogs (negatives).

For an **explicit-content** category it structurally fails: Commons does not host
pornography, so the positive queries return nothing. Verified against the live
API on 2026-06-01:

```
"nude woman posed provocatively erotic photoshoot"   → 0 results
"topless woman sexually suggestive bedroom"          → 0 results
"screenshot adult content site nude portrait"        → 0 results
"living room interior" (a benign negative)           → 5 results
```

This is not a bug — it is the moderation property that makes Commons safe,
working as intended. And it is not something to "fix" by pointing the fetcher at
an unmoderated source: `docs/THREAT-MODEL.md` and `docs/MARKETPLACE.md` draw a
hard line — the project never fetches, hosts, or caches explicit imagery (CSAM
risk, porn-image-hub risk). **Any design here must keep that line intact.**

## The question the user actually asked

> "Is there any way to generate the positives with a different platform or
> headless search?"

Short answer: **fetching real explicit positive images is off the table** (the
threat-model line). But "positives" in the calibration math is not inherently
"explicit images downloaded from somewhere" — it is *any* sample of how the
category's positive side scores. There are three safe ways to get that signal
without ever fetching explicit imagery, in increasing order of fidelity.

### Why we can afford to be clever here

Two facts (verified in code on 2026-06-01) change the problem:

1. **The positive anchor already exists locally.** `policy.bin` stores each
   category's averaged positive caption embedding (`PolicyBinaryReader`'s
   `positiveVec`) — a point in the SAME vector space images get scored in. We
   already have the "what positive looks like" vector with zero images.
2. **The daemon already logs real positives.** `ValueGuardDaemon` writes every
   per-frame per-category score to `scores.log` (NDJSON, gated by the
   "write scores" setting). As the user runs the filter, genuine on-device
   positive scores accumulate — the user's *own* environment, never uploaded.

Also worth noting: what calibration must protect is the **false-positive rate** —
the filter firing on benign content. The negative side (which calibrates fine,
incl. the hard boundary cases: Commons returns classical nude *art* and medical
anatomy, 5 each) is the side that actually bounds FPR. The positive side mainly
sets recall, which for an explicit filter the author has already tuned
conservatively.

## Option A — Caption-anchored (synthetic) positives

Use the `positiveVec` from `policy.bin` as the positive distribution's center
instead of fetched images. Score the (real, fetched) negatives against it, and
place τ in the gap between the negative score distribution and the positive
anchor, subject to the conformal α (FPR ceiling) the user sets.

- **No images fetched for the positive side at all** → threat-model-clean.
- Already have everything needed (`positiveVec` + negatives + α).
- Honest about what it is: a *text-anchored* threshold, weaker than image-validated
  recall, but it correctly bounds the thing that matters (FPR on benign content).
- Limitation: a single anchor point has no spread; the Bayesian KDE wants a
  distribution. Mitigate by synthesizing a small positive cloud from the
  per-caption embeddings (each positive caption is its own point) rather than the
  single averaged vector — `policy.bin` would need to expose per-caption vectors,
  or the app re-embeds the captions via the on-device SigLIP-2 text encoder it
  already ships (`SigLIP2Text.mlpackage`). The latter needs no format change.

### A′ — re-embed the captions on-device (recommended core)
The app already has the SigLIP-2 **text** encoder. Feed the category's
`positive_captions` (12 of them for this category) through it → 12 positive
points in image-score space, no network, no images. That gives the positive KDE
a real spread, entirely on-device, entirely within the existing privacy boundary.
This is the cleanest answer to "generate the positives" — generate them from the
captions the author already wrote, in the same model, locally.

## Option B — Learn positives from the user's own scores.log

Once the filter has run, `scores.log` contains real positive-side scores from the
user's actual screen content. A "refine calibration" pass could use the
high-scoring tail of the user's own frames as positives. Strongest fidelity (it's
*their* environment), zero fetching, but requires the filter to have run for a
while first and assumes some true positives occurred. Best as a later
"recalibrate from my usage" feature, complementary to A′.

## Option C — Honest gating (the floor, ship regardless)

Whatever else we do, the calibrator should detect "positive corpus is empty"
*before* presenting a broken Bayesian fit, and explain it: "Positive samples for
this category can't be fetched from the calibration source. Using
caption-anchored calibration" (if A′ ships) or "This category ships with the
author's thresholds; in-app re-calibration isn't available" (if it doesn't). The
current UX shows a generic "No positive samples fetched" warning under an
otherwise-failed fit — confusing.

## Recommendation

1. **Ship C (honest gating) immediately** — it's a UX correctness fix independent
   of the harder work, and stops the calibrator from presenting a meaningless fit.
2. **Build A′ (on-device caption re-embedding) as the real answer** to "generate
   the positives": it produces a genuine positive distribution with no images and
   no threat-model violation, reusing the SigLIP-2 text encoder already bundled.
3. **Consider B later** as an opt-in "recalibrate from my own usage" refinement.

Explicitly rejected: pointing the fetcher at any unmoderated/explicit source.
That trades the project's core safety property for marginal recall and is not on
the table.

## Adjacent gap to fix (separate)

The marketplace bundle's `calibration.json` is currently a synthesized
placeholder — `vg pack` writes `{"method":"label_free_normal","n_samples_total":0}`
when the author doesn't supply real evidence (`Packer.makeCalibrationJSON`). So
"fall back to the author's shipped calibration" has little behind it today beyond
the thresholds baked into `policy.bin`. If author-side calibration evidence is to
be meaningful, `vg pack`/the calibrator must emit a real `calibration.json` (the
§4 schema in `docs/MARKETPLACE.md`). Tracked here so it isn't lost.

## Cross-references
- `app/Sources/Calibration/HeadlessCalibrator.swift` — the corpus builder; where
  positive/negative queries are derived and scored.
- `app/Sources/Calibration/WikimediaImageFetcher.swift` — the (moderated) source.
- `app/Sources/Calibration/PolicyBinaryReader.swift` — exposes `positiveVec`.
- `daemon/Sources/ValueGuard/AuditLog.swift` — the `scores.log` NDJSON writer.
- `docs/THREAT-MODEL.md` / `docs/MARKETPLACE.md` — the no-explicit-content line.
