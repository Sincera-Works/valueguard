# Marketplace architecture

A design contract for the ValueGuard config marketplace. The "config" noun
is a placeholder; see [Naming](#11-naming) for replacement candidates. This
document is the spec the build phases reference back to; it should be
amended by PR before code changes silently diverge.

---

## 1. Goals and non-goals

### What the marketplace IS for

- **Distributing portable filter bundles.** One author writes a values
  statement, compiles it, calibrates it against their environment, and
  publishes the result. Other users install it and run it locally without
  ever touching an LLM or a Python toolchain themselves.
- **Reusing calibration work.** A well-calibrated set of thresholds for a
  given values statement is more expensive to produce than the values
  statement itself. The marketplace's load-bearing utility is the *paired*
  (policy, thresholds, calibration evidence) bundle, not just the captions.
- **Surfacing trust signals.** Verified-author badge, version history,
  signature verification, fork lineage, install counts. Enough that a
  cautious user can decide whether a given config is worth running against
  their screen content.
- **Forking.** A user pulls down `acme/strict-personal@1.4.0`, tweaks two
  thresholds and a category description, and publishes `me/strict-personal@1.0.0`
  with a `fork_of` pointer back to the parent.

### What the marketplace IS NOT for

- **Hosting arbitrary CoreML models.** Configs reference a vision model by
  content-hash. The set of acceptable model hashes is a small allowlist
  curated by the registry; anything else is side-loaded with explicit user
  consent. The registry will not become a generic model hub.
- **A moderation platform.** The registry does not adjudicate disputes
  about whether a values statement is correct. It enforces a license-style
  acceptable-use policy (no malware, no CSAM-encoding captions, no
  trademark abuse) and otherwise stays out of the content question.
- **A CDN for media.** No reference images, no thumbnails of flagged
  content, no sample frames. Calibration evidence is statistical only
  (counts, FPR/FNR, scores), never raw pixels or thumbnails.
- **A telemetry funnel.** The registry knows nothing about what users
  actually flag. Install counts are the only behavioral signal that
  crosses the wire, and they are aggregated, anonymous, and opt-out.
- **A network filter or accountability bridge.** Those are separate
  surfaces; see `docs/ARCHITECTURE.md`.

---

## 2. The config bundle

### File format

A `.vgconfig` is a **gzipped POSIX tar** with a fixed top-level layout:

```
acme-strict-personal-1.4.0.vgconfig    (tar.gz, content-addressable)
├── manifest.json            required, UTF-8, canonical JSON
├── policy.bin               required, VGP1 binary, byte-for-byte
├── policy.json              required, human-readable source policy
├── calibration.json         required, machine-readable evidence (new schema; see §4)
├── README.md                optional, author prose
├── CHANGELOG.md             optional, author prose
├── LICENSE                  optional but strongly recommended
├── icon.png                 optional, 256×256 PNG, ≤ 64 KiB
└── signatures/
    ├── author.sig           required, detached signature over MANIFEST.SHA256
    ├── author.pub           required, Ed25519 public key (raw 32 bytes, base64)
    ├── registry.sig         optional, registry counter-signature
    └── MANIFEST.SHA256       required, ordered SHA-256 of every file above
```

A tarball was chosen over a directory bundle because (a) the daemon is
single-user CLI-installable on machines without macOS Finder bundle
semantics, (b) it travels over plain HTTP without server-side awareness,
and (c) it can be content-addressed by SHA-256 of the entire file.

Bundles are **immutable once published**. Republishing under the same
version is an error; threshold tweaks bump the patch version.

### `manifest.json` schema

Canonical JSON (RFC 8785-style — sorted keys, no whitespace, UTF-8). The
schema is versioned independently of the policy.bin format.

```json
{
  "schema_version": 1,
  "config_id": "strict-personal",
  "name": "Strict Personal Accountability",
  "description": "Conservative thresholds tuned for solo desktop use...",
  "author": {
    "handle": "acme",
    "display_name": "Acme Co",
    "verified": true,
    "public_key": "base64(32 bytes Ed25519)"
  },
  "license": "MIT",
  "version": "1.4.0",
  "created_at": "2026-05-28T14:02:11Z",
  "model_ref": {
    "family": "siglip2-base-patch16-256",
    "huggingface_id": "google/siglip2-base-patch16-256",
    "weights_sha256": "9b3f...",
    "coreml_package_sha256": "4e7a...",
    "input_resolution": 256,
    "embedding_dim": 768
  },
  "policy_hash": "sha256:7c2a...",
  "policy_json_hash": "sha256:1f88...",
  "calibration_hash": "sha256:dba1...",
  "thresholds": [
    { "id": "explicit_sexual", "threshold": 0.184, "action": "blur" },
    { "id": "graphic_violence", "threshold": 0.213, "action": "log" }
  ],
  "calibration_method": "label_free_normal",
  "calibration_summary": {
    "n_samples_total": 4812,
    "n_categories": 7,
    "prior_unsafe": 0.001,
    "cost_ratio_fp_fn": 1.0,
    "conformal_alpha": 0.05,
    "per_category": [
      {
        "id": "explicit_sexual",
        "n_samples": 712,
        "mu": 0.062,
        "sigma": 0.041,
        "threshold": 0.184,
        "expected_fpr": 0.0012,
        "expected_fnr_at_match_score_0_28": 0.04,
        "source": "wikimedia_commons"
      }
    ]
  },
  "categories": [
    {
      "id": "explicit_sexual",
      "action": "blur",
      "short_description": "Explicit sexual imagery; not nudity in art context."
    }
  ],
  "compatibility": {
    "min_daemon_version": "0.4.0",
    "max_daemon_version": null,
    "min_policy_bin_version": 1
  },
  "fork_of": {
    "author": "anvil",
    "config_id": "personal-baseline",
    "version": "2.0.1"
  },
  "tags": ["personal", "strict", "browsers"]
}
```

Field-by-field rules (the validator is `vg verify`):

| Field | Type | Req | Rule |
|---|---|---|---|
| schema_version | int | yes | exactly `1` for now |
| config_id | string | yes | `^[a-z][a-z0-9-]{1,38}[a-z0-9]$` |
| name | string | yes | 1–80 chars, no control chars |
| description | string | yes | 1–2000 chars, plain text |
| author.handle | string | yes | `^[a-z0-9][a-z0-9-]{1,38}$` |
| author.public_key | b64 | yes | 32 raw bytes Ed25519 |
| author.verified | bool | yes | always `false` unless registry counter-signs |
| license | string | yes | SPDX identifier; `LicenseRef-...` allowed |
| version | string | yes | SemVer 2.0 with prerelease but no build metadata |
| created_at | string | yes | RFC 3339 UTC, no offsets |
| model_ref.weights_sha256 | hex | yes | matches HF safetensors digest |
| model_ref.coreml_package_sha256 | hex | yes | matches local conversion output |
| model_ref.embedding_dim | int | yes | must equal `policy.bin` embed_dim |
| policy_hash | string | yes | `sha256:<hex>` of the bundled `policy.bin` |
| policy_json_hash | string | yes | `sha256:<hex>` of `policy.json` |
| calibration_hash | string | yes | `sha256:<hex>` of `calibration.json` |
| thresholds[].threshold | float | yes | in `[0.0, 1.0]`, matches policy.bin byte-for-byte |
| thresholds[].action | enum | yes | `log` \| `blur` \| `block` |
| calibration_method | enum | yes | `label_free_normal` \| `gaussian_mixture` \| `conformal` \| `none` |
| compatibility.min_daemon_version | string | yes | SemVer of `valueguardd` |
| fork_of | object | no | absent for originals |
| tags | string[] | no | ≤ 8 tags, each `^[a-z0-9-]{1,24}$` |

The manifest does **not** carry caption text. Captions remain inside
`policy.bin` (already compiled to vectors) and `policy.json` (the
human-readable source for inspection and forking). Duplicating them in the
manifest would create three sources of truth.

### Bundling `policy.json` alongside `policy.bin`?

Yes. The `policy.json` is mandatory in the bundle. Three reasons:

1. **Forking.** Without the source captions, a fork has to reverse-engineer
   the vectors back to text, which is lossy. `policy.json` lets the
   `policy-compiler/` CLI re-run `embed_captions.py` against any other
   model version without re-asking the LLM.
2. **Inspection.** A consumer should be able to read what a config is
   actually filtering before installing. `policy.bin` is opaque float
   arrays; `policy.json` is captions, descriptions, and rationale.
3. **Tamper evidence.** The `policy_hash` and `policy_json_hash` are both
   manifest fields. If somebody edits captions without re-running
   `embed_captions.py`, the daemon won't notice — but `vg verify` will.

Cost: an extra ~20–40 KB per bundle. Acceptable.

### Signature format

- **Algorithm:** Ed25519. Small keys, small signatures, well-supported in
  Swift (CryptoKit), Node (libsodium), and Python (PyNaCl).
- **What is signed:** `MANIFEST.SHA256`, which is a sorted, newline-
  delimited file of `<sha256-hex>  <relative-path>` lines covering every
  file in the bundle except `signatures/`. This is signed in raw bytes —
  no JSON canonicalization gymnastics.
- **Who signs:**
  - `signatures/author.sig` is produced by the author's Ed25519 key. The
    public key is in the manifest *and* in `signatures/author.pub` (for
    side-channel verification when the manifest itself is questioned).
  - `signatures/registry.sig` is the registry's optional counter-
    signature. Verified authors get this. The registry public key is
    pinned into the CLI at release time and rotated via signed updates.
- **Verification order:** `vg install` always verifies `author.sig`
  against the manifest's claimed `public_key`. Verified-author badge in
  the CLI/UI requires the `registry.sig` to also verify against the
  registry pin. Author key trust on first use (TOFU) is recorded under
  `~/Library/Application Support/ValueGuard/known_keys.json`.

### SemVer rules

The bundle is a tightly-coupled (captions, vectors, thresholds, model)
tuple, so the SemVer story is stricter than for software libraries:

| Change | Bump |
|---|---|
| Adding a new category | minor |
| Removing a category | major |
| Renaming a category id | major |
| Editing captions inside an existing category | minor |
| Tweaking a threshold | patch |
| Tweaking an `action` (log→blur→block) | minor |
| Changing the model_ref | major |
| Increasing `min_daemon_version` | minor |
| Adding tags, description, README, icon | patch |
| Replacing the author key | major |

Prereleases (`1.5.0-rc.1`) are permitted and never auto-installed by
`vg update` unless the user explicitly pins one.

---

## 3. Registry / API

### Protocol choice: REST + JSON, not GraphQL.

The marketplace is read-heavy, cacheable, and structurally tree-shaped
(authors → configs → versions → bundles). The bundle download is a
binary blob behind a content-addressed URL; a GraphQL gateway in front of
it adds latency without adding value. REST + ETag + `Cache-Control:
immutable` for version-pinned URLs is much friendlier to CDNs.

### Surface

| Method | Path | Purpose |
|---|---|---|
| GET  | `/v1/configs` | Search/list. Query params: `q`, `tag`, `author`, `model`, `sort=downloads\|recency\|stars`, `limit`, `cursor` |
| GET  | `/v1/configs/:author/:slug` | Config detail (latest version's manifest plus aggregated metadata) |
| GET  | `/v1/configs/:author/:slug/versions` | Version index, newest first |
| GET  | `/v1/configs/:author/:slug/v/:version` | Manifest for a specific version |
| GET  | `/v1/configs/:author/:slug/v/:version/bundle` | 302 → CDN URL for `.vgconfig` |
| GET  | `/v1/configs/:author/:slug/v/:version/calibration` | Just the calibration.json |
| POST | `/v1/configs/:author/:slug/versions` | Publish (auth: bearer token + body-level signature) |
| POST | `/v1/configs/:author/:slug/fork` | Server-side fork record (creates a `me/<slug>` stub) |
| POST | `/v1/configs/:author/:slug/report` | Abuse report (auth: any logged-in user) |
| GET  | `/v1/authors/:handle` | Author profile + verification status |
| POST | `/v1/auth/register` | Create author handle + initial key |
| POST | `/v1/auth/sessions` | Exchange signed challenge for bearer token |
| GET  | `/v1/auth/whoami` | Current identity |
| GET  | `/v1/models` | Allowlisted vision model refs |
| GET  | `/v1/health` | Liveness, schema_version, server time, registry pubkey fingerprint |

Pagination is cursor-based (`?cursor=opaque`), not offset/limit, so search
ordering can change without breaking deep paging.

### Publish flow

`POST /v1/configs/:author/:slug/versions` accepts `multipart/form-data`:

- `bundle` — the raw `.vgconfig` bytes
- `signed_metadata` — JSON `{ "bundle_sha256": "...", "ts": "..." }`
  signed with the author key (same Ed25519 key as in the manifest), to
  bind the upload to the author independently of the session token

Server validates:

1. `bundle_sha256` matches the upload.
2. `signed_metadata` signature verifies against the author key on file.
3. The bundle parses, all hashes match, all signatures inside the bundle
   verify, manifest schema validates.
4. `model_ref.weights_sha256` is on the allowlist (or the author has
   side-load privileges).
5. SemVer is strictly greater than every existing version under
   `:author/:slug`.
6. License is in the SPDX list or explicitly `LicenseRef-`-prefixed.
7. AUP scan on `policy.json` captions (deny-list of categories the
   registry refuses to host — e.g. CSAM-related captions are rejected
   even if the intent is to *filter against* them, because we can't
   distinguish from the captions alone).

On success, the bundle is stored content-addressed and the manifest is
indexed.

### Storage layout

S3-compatible object store with two prefixes:

```
bundles/<sha256>/bundle.vgconfig    (content-addressed, immutable)
manifests/<author>/<slug>/<version>/manifest.json
manifests/<author>/<slug>/<version>/calibration.json
authors/<handle>/profile.json
authors/<handle>/keys.json
```

The registry database holds the search index and pointers; the blobs are
never mutated. Garbage collection removes orphaned bundles only after the
manifest has been unpublished for 30 days.

### Caching, rate limits, CDN

- All `GET /v1/configs/:author/:slug/v/:version*` responses are
  `Cache-Control: public, max-age=31536000, immutable`. They are pinned.
- The mutable endpoints (`/configs`, `/authors/:handle`) are
  `s-maxage=60`, `stale-while-revalidate=600`.
- Rate limits: 60 req/min unauthenticated by IP, 600 req/min for
  authenticated authors, 6/min for `POST /versions` per author.
- The download CDN is fronted by a single 302 from the API, so the API
  origin never serves multi-megabyte blobs. CDN URLs are signed and
  short-lived (15 min) when the bundle is private; public bundles get
  unsigned long-lived URLs for trivial wget mirroring.

### Audit log

The registry maintains an append-only log of publish, unpublish, key-
rotation, takedown, and verified-author-grant events. Each record is
hash-chained (`prev_sha256` field) so the log is tamper-evident. Exposed
via `GET /v1/audit?since=...` for transparency tooling. The audit log is
**not** the abuse-report queue; reports are private.

### Search ranking signals

In order of weight: textual match on name/description/category id,
verified-author badge, install count (decayed exponentially over 90 days),
explicit star count, recency of last publish, fork count. Captions are
**not** indexed for full-text search — they are an implementation detail
of the model, and surfacing them in search would create a perverse
incentive to caption-stuff.

---

### Static registry — implemented prototype (`vg reindex` / `vg search` / `vg install author/slug`)

The REST surface above is the eventual P1+ design. The **shipping prototype** is
simpler and static-first: a registry is a directory tree generated by `vg reindex`
and served by any static host (object storage + CDN) or, for local/offline use, a
`file://` base. There is no service, no auth, no database — `index.json` is the
catalog and bundle blobs are content-addressed. The client trusts the index only
to *locate* bytes; every install converges on the same offline verify pipeline as
a local install, and a downloaded blob's bytes are content-checked against the
index's `bundle_sha256` before they ever reach verify.

**Registry tree (what gets hosted):**

```
index.json
bundles/<sha256>.vgconfig                                  # content-addressed, immutable
configs/<author>/<slug>/<version>/manifest.json            # copied from each bundle
configs/<author>/<slug>/<version>/calibration.json
```

**`index.json` schema** (`schema_version: 1`): a `registry` block plus a
`configs[]` list. Each config carries `author`, `slug`, `name`, `description`,
`latest_version`, `license`, `tags[]`, `verified` (always `false` in the
prototype — no pinned registry key yet), `author_fingerprint`, and a newest-first
`versions[]`. Each version carries `version`, `created_at` (from the bundle's
manifest), `bundle_sha256`, `bundle_path`, `manifest_path`, `size_bytes`, and a
`categories[] { id, action }` summary. All `*_path` fields are **relative to the
registry base URL**; `latest_version` is the highest non-prerelease SemVer.

**Generate the registry** from a directory of bundles (idempotent; a bundle that
fails verification is skipped with a warning, never aborts the run):

```
vg reindex --bundles <dir> --out <registry-dir>
```

**Search** the registry (substring match on name/description/slug/author, with an
optional `--tag`); output mirrors the §4 aligned-row style:

```
$ VALUEGUARD_REGISTRY=file:///abs/registry vg search
using registry file:///abs/registry
sincera/personal-values  1.0.0                  personal, strict
```

**Install** by reference, direct URL, or local path — three forms, one verify
pipeline:

```
vg install sincera/personal-values            # resolve via index.json, download, sha-check, verify, install
vg install sincera/personal-values@1.0.0      # pin an exact version
vg install https://host/path/foo.vgconfig     # direct bundle URL (verify is the gate)
vg install ./foo.vgconfig                      # local path / file:// (unchanged)
```

The registry base URL precedence is `--registry <url>` > `VALUEGUARD_REGISTRY`
env var > the prototype default constant `https://valueguard-configs.pages.dev`
(defined once, in `RegistryClient.defaultRegistryBase`, to be repointed at deploy
time). A bare path or `file://` base runs the entire resolve → download →
sha-check loop with no network, which is what the test suite uses.

---

## 4. CLI surface

The CLI ships as a single binary, `vg`, distributed via Homebrew and as a
signed pkg. It links the same Swift code that the daemon uses to validate
`policy.bin` so verification semantics never drift.

### Subcommands

```text
vg search <query> [--tag T] [--author A] [--model M] [--sort downloads|recency]
vg show <author>/<slug>[@version]
vg install <author>/<slug>[@version] [--pin <semver-range>] [--side-load-model]
vg list [--json]
vg activate <author>/<slug>
vg current
vg update [<author>/<slug>] [--dry-run] [--prerelease]
vg uninstall <author>/<slug>
vg fork <author>/<slug>[@version] --as <slug>
vg verify <path-to-vgconfig>
vg publish [--dir .] [--dry-run]
vg login [--device]
vg logout
vg whoami
vg keys list|generate|rotate|trust <handle> <fingerprint>
```

### Examples

```sh
# Search and install
$ vg search "personal accountability"
acme/strict-personal           1.4.0    verified  ★ 312
anvil/personal-baseline        2.0.1    verified  ★ 188
fern/desk-mode                 0.9.0              ★ 22

$ vg install acme/strict-personal
verifying signature                       ok
verifying policy.bin hash                 ok
checking model_ref.weights_sha256         on allowlist
installing to ~/Library/Application Support/ValueGuard/configs/acme/strict-personal/1.4.0
done. activate with: vg activate acme/strict-personal

# Show what you're about to run
$ vg show acme/strict-personal
acme/strict-personal @ 1.4.0  (verified author)
license MIT, MIT
model    siglip2-base-patch16-256 @ 9b3f...
calibration  label_free_normal, n=4812, prior=0.001
categories
  explicit_sexual    threshold=0.184  action=blur
  graphic_violence   threshold=0.213  action=log
  ...

# Pin and update
$ vg install acme/strict-personal@^1.4
$ vg update                # respects the ^1.4 pin
$ vg update --prerelease   # opt into 2.0.0-rc.1

# Fork
$ vg fork acme/strict-personal --as my-strict
created ~/Library/Application Support/ValueGuard/configs.workdir/me/my-strict/
edit policy.json, then: vg publish

# Publish
$ vg publish --dir .
linting manifest.json                     ok
re-embedding captions (siglip2-base-patch16-256)
recomputing hashes
signing with key fp:abc1...
uploading                                ok
published me/my-strict @ 1.0.0
```

`vg verify <path>` is the canonical offline check; it can be run on any
`.vgconfig` without the registry being reachable.

---

## 5. Local install layout

Installed bundles live under
`~/Library/Application Support/ValueGuard/configs/`:

```
configs/
├── active                              symlink → acme/strict-personal/1.4.0
├── lockfile.json                       what is pinned where
├── known_keys.json                     TOFU author key cache
├── acme/
│   └── strict-personal/
│       ├── 1.3.2/                      kept for rollback
│       │   ├── manifest.json
│       │   ├── policy.bin
│       │   ├── policy.json
│       │   ├── calibration.json
│       │   └── signatures/
│       └── 1.4.0/
│           └── ...
└── configs.workdir/
    └── me/
        └── my-strict/                  active forks, unpacked, editable
```

Multiple versions can coexist; old versions get garbage-collected after
30 days unless `vg keep <author>/<slug>@<version>` was called.

The "active" config is selected by a symlink at `configs/active` that
points at a versioned directory. The daemon discovers it by reading the
target of that symlink and loading `policy.bin` from inside. Atomically
swapping the symlink (`rename(2)`) is the entire activate operation.

The daemon's existing `Classifier.swift` model-search candidate list (see
`daemon/Sources/ValueGuard/Classifier.swift:20-25`) gets a new first
entry: `~/Library/Application Support/ValueGuard/models/<sha256>/SigLIP2Vision.mlpackage`.
Models are stored shared across configs, content-addressed by the
`model_ref.coreml_package_sha256` from the manifest. Multiple configs
referencing the same model share one on-disk copy.

### `lockfile.json` semantics

```json
{
  "schema_version": 1,
  "active": "acme/strict-personal",
  "configs": [
    {
      "author": "acme",
      "slug": "strict-personal",
      "pin": "^1.4",
      "installed_version": "1.4.0",
      "installed_at": "2026-05-28T14:02:11Z",
      "bundle_sha256": "7c2a...",
      "author_key_fingerprint": "abc1..."
    }
  ]
}
```

`vg update` reads pins from the lockfile, asks the registry which
versions exist, picks the highest matching SemVer, downloads, verifies,
and updates `installed_version`. The lockfile is the source of truth for
"what is installed and why"; the on-disk directory tree is the cache.

---

## 6. App integration

A new `Configs` tab in `app/` Settings replaces the existing manual
`policy.bin` selector. The tab has three subviews:

1. **Installed.** Lists each entry in `lockfile.json` with its current
   version, the daemon's last-seen activation, a `Activate` button, a
   `Re-calibrate` button (launches the existing calibration flow against
   this config's thresholds), and an `Uninstall` button.
2. **Browse.** Embedded `WKWebView` rendering the public marketplace
   directory. The web side calls back to the app via a `vgconfig://`
   URL scheme for install actions, so the same install path is exercised
   from CLI and UI.
3. **My configs.** Authoring surface. Lists in-progress forks under
   `configs.workdir/`, exposes the existing `policy-compiler` and
   `embed_captions` pipelines via UI, and surfaces `vg publish` as a
   button.

### Calibration integration

Configs ship with pre-calibrated thresholds. The user's local environment
is unlikely to match the author's exactly, so the app encourages
re-calibration:

> **Note on `calibration.json`.** No tool in the repo writes this file
> today. `model-conversion/calibrate.py` emits a markdown report plus an
> updated `policy.json`; the new Bayesian + conformal calibrator in
> `app/Sources/Calibration/` works in-app and patches `policy.bin`
> directly. Adopting `.vgconfig` bundling means specifying and
> implementing the `calibration.json` schema (fields enumerated in §2's
> manifest example are the starting proposal) and writing it from
> whichever calibrator owns the publish path.

- The `Re-calibrate` button runs the existing label-free flow from
  `model-conversion/calibrate.py` (rewired to a Swift port for the app)
  against the user's own captured scores log.
- Re-calibration updates the **local** `policy.bin` threshold bytes
  in-place and writes a sibling `calibration.local.json` recording the
  evidence.
- A `Calibration: customized` badge appears in the installed list once a
  config has been locally re-calibrated.
- `vg fork --inherit-calibration` lets the user publish their re-
  calibration as a fork, with `calibration.json` reflecting their own
  evidence and a `fork_of` pointer to the original.

### Hot reload vs restart

The daemon loads `policy.bin` via `Data(contentsOf:options:[.mappedIfSafe])`
(`Policy.swift:48`), which mmaps when the file system + size make it
worthwhile and otherwise falls back to a normal read. Either way the
loaded `Policy` is a `let` on the actor (`ValueGuardDaemon.swift:8`),
initialized once at `init` (line 44–45). Hot reload therefore requires
real work the daemon doesn't do today: lift the policy from `let` to a
swappable holder, install a `SIGUSR1` handler (none exists in the
codebase), and on signal re-read the active symlink target and replace
the held instance. Per-window hysteresis state stays intact across
swaps; only the scoring vectors are replaced. Atomic symlink swap on
the active config plus the SIGUSR1 then avoids the "filtering stopped
for 12 seconds while the daemon restarted" experience.

---

## 7. Trust and safety

### Verified vs community configs

- **Community (default).** Anyone with a registered handle can publish.
  Their author key signs the bundle. The CLI shows the key fingerprint
  on first install and warns on key change.
- **Verified.** The registry counter-signs the bundle. Verification is
  granted out-of-band: identity check on the author + a manual review of
  the values statement and calibration evidence. The verified badge is a
  registry-controlled flag — never settable from the bundle alone.

The CLI displays `verified` only when *both* signatures verify and the
registry pubkey matches the CLI's pinned copy.

### Worst case for a malicious config

Configs are pure data: an LLM-readable JSON, a binary table of float
vectors, and metadata. They cannot execute code on install or at
runtime. The realistic failure modes are:

| Failure | Damage | Mitigation |
|---|---|---|
| Adversarial captions cause systematic false positives | Annoying; blocks legitimate content | Re-calibration; user uninstall |
| Adversarial captions cause systematic false negatives | Filter is silently useless | Diff against verified configs; community review |
| `action: block` is set on borderline categories | The daemon kills apps the user wanted running | The daemon's `--log-only` mode is the calibration default; install does not auto-promote to block |
| Bundle ships a stale `min_daemon_version` so an older daemon misinterprets the binary | Daemon refuses to load | Daemon validates `compatibility.min_daemon_version` before mmap'ing `policy.bin` |
| Signature stripped, bundle modified in transit | Tampered policy installed | TLS + Ed25519 verification at install time; the CLI refuses unsigned bundles by default |

### Malicious model

A config references a vision model by `model_ref.weights_sha256`. The
registry maintains a small allowlist of approved hashes (initially just
`google/siglip2-base-patch16-256` at its canonical safetensors digest).
Configs referencing anything else are not installable unless the user
passes `--side-load-model`, which prompts with the full model URL, the
expected hash, and a "I understand this model will process my screen
pixels" confirmation. Side-loaded models are stored under
`~/Library/Application Support/ValueGuard/models/<sha256>/` and never
promoted to the allowlist locally.

### Reporting / takedown

- `POST /v1/configs/:author/:slug/report` records an abuse report
  against a specific version.
- A small registry-side moderation queue triages reports. Decisions:
  *no action*, *unpublish version*, *unpublish all versions*,
  *revoke author handle*.
- All takedown decisions are written to the registry audit log with the
  reason. Authors can appeal in-band.
- Unpublish does not break already-installed bundles — the daemon never
  phones the registry at runtime. It just removes the version from
  search and from `vg update`'s candidate list.

### License

Default: **MIT for the manifest and calibration evidence; CC0 for the
policy.json captions**. We recommend authors mark policy text as CC0 so
forks have no copyright friction. GPL'd model weights would be a problem
because the bundle distributes references to weights, but the registry
never hosts weights itself, so the question is bounded: the allowlist
is what guarantees GPL contamination cannot enter the install path.

---

## 8. Privacy

- The CLI and app talk to the registry over HTTPS with the registry
  pubkey pinned at the TLS layer (a separate pin from the Ed25519
  signing pin).
- No user content — no frames, no thumbnails, no embeddings, no audit
  log entries, no calibration evidence collected from the user's own
  screen — is ever sent to the registry. The `calibration.json`
  *inside a bundle* is the author's evidence, not the consumer's.
- Telemetry: the CLI does not phone home. `vg install` does increment
  the install counter on the registry — that is the *only* behavioral
  signal — and only because the download already implies it. The app
  has no analytics. Users can pass `--no-stats` to install via a
  side-channel mirror that doesn't record the download.
- The registry knows the author's handle, key, IP at publish time, and
  what they published. Authors who want pseudonymity should publish
  through a stable VPN/Tor exit; the registry won't fight them on it.

---

## 9. Build and rollout plan

| Phase | What ships | Size |
|---|---|---|
| **P0 — Bundle format and CLI install** | `.vgconfig` tar layout, manifest schema validator, Ed25519 sign/verify, `vg verify`, `vg install <file://path>`, `vg list`, `vg activate`, `vg uninstall`, atomic symlink swap, daemon SIGUSR1 reload | **M** |
| **P1 — Self-hosted registry, single admin author** | REST API skeleton, S3 storage, publish + download against a single hardcoded `acme` author key, no auth on read endpoints, `vg install <author>/<slug>` over HTTPS, lockfile-driven `vg update` | **L** |
| **P2 — Public author registration** | `/auth/register`, Ed25519 device flow, bearer tokens, per-author publish quotas, abuse reports queue (read by humans), audit log endpoint | **M** |
| **P3 — Web directory** | Static-site listing of configs and authors, search box, install button that hands off to the CLI via `vgconfig://`, in-app browse tab pointing at the same site | **M** |
| **P4 — Verified-author program** | Registry counter-signature flow, identity verification pipeline, allowlist of approved model hashes, side-load consent UI, takedown tooling | **L** |
| **P5 — Calibration forks** | `vg fork --inherit-calibration`, calibration evidence schema v2 with consumer-side capture metadata stripped, app-side re-calibration UI | **M** |

T-shirt sizing convention: **S** = days, **M** = weeks, **L** = a month
or two, **XL** = quarter+. Each phase is shippable on its own; P0 alone
already gives the team a way to swap `policy.bin` files around safely.

---

## 10. Open questions

1. **Monetization.** Are configs ever paid? If so, does the registry
   hold a payments relationship with authors, or is it strictly a
   directory pointing at the author's own checkout?
2. **Federated registries.** Should the CLI support multiple registry
   origins (`vg install acme/strict-personal@^1.4 --from registry.example`),
   or do we assume one canonical registry forever?
3. **Automatic recalibration.** Should the daemon automatically re-
   calibrate when it sees the local FPR drift more than X over Y days,
   or is calibration always an explicit user action?
4. **Caption privacy.** Some authors might want to publish a config
   without exposing the exact captions (proprietary policy IP).
   `policy.json` is required today; should we allow an opaque-bundle
   mode that ships only `policy.bin` and forfeits the fork affordance?
5. **Org / team configs.** Corporate Mode B in `docs/THREAT-MODEL.md`
   wants configs pushed via MDM. Do we add a `team` namespace on the
   registry with private bundles, or is that out of scope?
6. **Caption ensembling at install time.** Today captions are embedded
   by the author. We could let consumers add their own positive/
   negative captions on top of an installed config; that is a real
   feature but creates a "is this still acme/strict-personal" identity
   problem.
7. **Model upgrades.** When SigLIP-2 is replaced by SigLIP-3, every
   existing `policy.bin` is invalid because the embedding space
   changed. Do we re-embed automatically using the bundled `policy.json`,
   require authors to republish, or both?
8. **Bundle size cap.** Today's bundles are ~50 KB. If we ever ship
   per-category reference embeddings (for nearest-neighbor explanations)
   they could grow to MB. Cap now or later?
9. **Author key recovery.** Ed25519 keys lost = handle lost. Do we
   support social-recovery, registry-mediated reset, or strict
   "your key is your identity, that's the whole point"?
10. **Threshold-only patch upload.** The most common change is a single
    threshold tweak. Should we support a delta-publish that ships just
    the new thresholds without re-uploading the policy.bin, or is the
    immutability/content-address story worth the redundant uploads?

---

## 11. Naming

The "config" noun is provisional. So is the marketplace name. Candidates:

| Candidate | Reasoning | Concerns |
|---|---|---|
| **Refuge** | Evokes the personal-accountability use case (Mode A in the threat model). Connotes safety without "filter / block" baggage. Plays well with "config" → "shelter" as the bundle rename. | Slightly heavy. Might feel religious to some users. |
| **Sieve** | Mechanical, accurate, neutral. A sieve is the thing pixels pass through. Pairs naturally with "screen" already in our vocabulary. | Smaller word; less obvious as a brand. |
| **Lattice** | The bundles overlay on each other, fork from each other, stack into compatibility matrices. "Lattice" captures the directed graph of configs and forks. | Mathematical / cold; doesn't telegraph user value. |

For the bundle noun itself, the earlier candidates (Shield, Aegis, Ward,
Lens) all bias toward "blocking." Given the daemon's default `action: log`
posture and the calibration-first stance, a more neutral term — **Filter**
(plain) or **Pane** (a sheet of glass you look through) — is probably a
better fit than the protection-themed options. This is not the place to
pick; just noting the bias.

---

## Cross-references

- `docs/ARCHITECTURE.md` — overall split between cloud-side compile and
  on-device daemon. The marketplace strictly lives on the cloud side of
  that boundary; nothing it does crosses the pixel firewall.
- `docs/THREAT-MODEL.md` — Modes A/B/C inform the verified-author
  program and the takedown/appeal flow.
- `docs/INSTALL.md` — current manual `policy.bin` install path that the
  marketplace replaces. `vg install` should leave the existing
  `VALUEGUARD_POLICY` env var working as an override.
- `daemon/Sources/ValueGuard/Policy.swift` — the policy.bin reader. The
  manifest's `min_policy_bin_version` field gates against future format
  bumps so the daemon can refuse incompatible bundles loudly.
- `daemon/Sources/ValueGuard/Classifier.swift` — model-search candidate
  list. The marketplace adds a content-addressed model directory at the
  front of that list.
- `model-conversion/embed_captions.py` — VGP1 format spec. The
  marketplace MUST NOT change this format; any change is a `policy.bin`
  version bump and a major-version manifest bump.
- `policy-compiler/src/types.ts` — `Policy`, `PolicyCategory`,
  `PolicyAction` are the wire types that `policy.json` inside a bundle
  has to validate against.
