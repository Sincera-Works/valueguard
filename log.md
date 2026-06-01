# ValueGuard change log

State-changing actions (build changes, signing swaps, policy revisions, model
upgrades). Newest first.

## 2026-06-01 — One-click install (no CLI) + product direction

Built the non-CLI install path so a user can click a button on the web directory
and have a config policy land in ValueGuard's settings. App side reuses the
`ValueGuardMarketplace` library — **no daemon changes**. Stacked on the
prototype branch; PR [#14](https://github.com/Sincera-Works/valueguard/pull/14)
(base `feat/marketplace-prototype`).

- **`vgconfig://` URL scheme** registered in the app; `AppDelegate.application(_:open:)`
  parses `vgconfig://install?registry=<base>&ref=<author>/<slug>[@version]`.
- **`ConfigInstallCoordinator`** + a **Configs settings tab** (install/activate/
  uninstall, installed list, live-registry link). Install shows a
  **trust-confirmation sheet** with the author key fingerprint (TOFU) + verified
  state + categories — a `vgconfig://` link never silently swaps the filter.
- **Copy-on-activate bridge**: the daemon reads one flat `policy.bin`; activating
  a config copies its `policy.bin` to that path and restarts the daemon. Spec §6's
  symlink + SIGUSR1 hot-reload is the clean follow-up.
- **Web**: per-card "Install in ValueGuard" button (registry base from the page's
  own origin); copy-CLI kept as fallback.
- Build-verified: `xcodegen` + `xcodebuild` (Debug/macOS) → BUILD SUCCEEDED, zero
  errors; site rebuilds clean. **Not yet redeployed** (web button not live until
  a `wrangler pages deploy`).

**Product direction set (2026-06-01):** marketplace should let authors **tip /
charge**. Decision: **author-hosted checkout links** (Stripe/Ko-fi/Gumroad —
registry stays static, we hold no money/cards/tax), app distributed as a
**direct-download notarized DMG** (no Apple IAP cut). True pay-before-download
gating would need the deferred P1 backend + merchant-of-record/tax handling —
out of scope. Tips/links phase **not started**; one-click install was built first.

## 2026-05-31 — Marketplace prototype (static-registry cut)

Built a working marketplace prototype on top of the done P0 (bundle format,
Ed25519 sign/verify, offline `vg install/activate`). Decision: a **static
registry** (no backend) hosted on **Cloudflare Pages + R2**, CLI + minimal web
page. All in `daemon/` + new `registry-site/`. **40 tests pass.**

- **Authoring.** `vg keygen` (persist an Ed25519 author key) and `vg pack`
  (assemble + sign a `.vgconfig` from `policy.bin`/`policy.json`), backed by a
  new public `Packer` in the library (the pack/sign logic that previously lived
  only in the test `FixtureBuilder`, now shared). Real bundle packed:
  `sincera/personal-values@1.0.0`, content-address sha256 `3bd8e797…`, with
  **genuine** `model_ref` digests — `weights_sha256` is the real HF safetensors
  oid for `google/siglip2-base-patch16-256`
  (`6125cacc01fa93bdc98a0c5101cefcd69b2ed1f8ab4f38d86f4ad5984f5dc863`) and
  `coreml_package_sha256` is a reproducible tree-hash of the local
  `SigLIP2Vision.mlpackage` (sha256 of the sorted per-file sha256 listing,
  `4848b789…`). The durable `sincera` signing key lives at
  `~/Library/Application Support/ValueGuard/keys/sincera.key` (reuse it to
  republish under the same author fingerprint — TOFU continuity).
- **Registry.** `vg reindex --bundles <dir> --out <registry-dir>` generates a
  static tree: `index.json` + content-addressed `bundles/<sha>.vgconfig` +
  extracted `configs/<a>/<s>/<v>/manifest.json`+`calibration.json`. New
  `RegistryIndex`/`RegistryClient`/`SemVer`/`Reindexer` in the lib.
- **Install/search.** `vg install author/slug[@ver]` resolves via `index.json`,
  downloads over HTTPS, re-hashes the bytes against `bundle_sha256`, then runs
  the existing offline verify+install path. Direct `vg install https://…` and
  the old local/`file://` paths still work. `vg search [q] [--tag t]`. Registry
  base precedence: `--registry` > `VALUEGUARD_REGISTRY` > default
  `https://valueguard-configs.pages.dev` (one constant in `RegistryClient`).
- **Testability.** `InstallLayout` now honors `VALUEGUARD_CONFIGS_DIR` so
  install/activate/uninstall can run against a scratch tree.
- **Web.** `registry-site/` — zero-dependency static page reading `index.json`
  (cards, live search, copy-paste `vg install`, per-version + category detail,
  verified badge, privacy blurb). `build-site.sh` assembles
  `registry-site/dist/` (page + a real `vg reindex`); `DEPLOY.md` documents the
  Cloudflare Pages deploy and the R2-graduation path. `dist/` is gitignored.
- **Verified end-to-end:** pack → reindex → search → install → activate → list
  → uninstall, and the assembled site serves page+`index.json`+bundle blob over
  HTTP (200s, correct sizes).
- **DEPLOYED 2026-05-31.** Cloudflare Pages project `valueguard-configs`
  (account `mcauley.brad@gmail.com`, alongside the other Sincera Pages
  projects) — live at **https://valueguard-configs.pages.dev**, which is the
  CLI's baked-in default base, so `vg search` / `vg install
  sincera/personal-values` work with **zero flags** against the live registry.
  Verified: page/index.json/bundle blob all serve 200 with correct sizes, and a
  full `install → activate → list` over the public URL succeeds. Deploy was
  `wrangler pages deploy registry-site/dist` after the maintainer ran `wrangler
  login` (the OAuth token now carries `pages:write` + resolvable account ID).
  Redeploy = `registry-site/build-site.sh` then the same deploy command.
- **Committed + PR.** Branch `feat/marketplace-prototype`, PR
  [#13](https://github.com/Sincera-Works/valueguard/pull/13) (21 files, ~3.6k
  insertions; `AGENTS.md` and `.wrangler/` excluded, the latter now gitignored).
  `claude-review` CI running.

Build note: the repo relocation left a stale `.build/ModuleCache` referencing
`~/projects/valueguard`; if "compiled with module cache path" errors appear,
`rm -rf daemon/.build` and rebuild.

## 2026-05-28 — Repo hardening: branch protection + Claude review CI

- **Repo moved** to `Sincera-Works/valueguard` (was `sincera7/valueguard`);
  local `origin` updated. Pruned three merged branches.
- **Branch protection on `main`**: PR required, 0 required approvals (so the
  maintainer can still merge their own PRs), conversation resolution required,
  force-push and branch deletion blocked. Admin enforcement left off as an
  escape hatch.
- **Claude review CI** (PR #5): `claude-code-review.yml` (auto-review on every
  PR) and `claude.yml` (interactive `@claude`), both via
  `anthropics/claude-code-action@v1` authenticating with the
  `CLAUDE_CODE_OAUTH_TOKEN` secret (Claude GitHub App / OAuth). Once the review
  check runs green it will be added as a required status check.

## 2026-05-28 — Phase 6 action layer: window level, emergency dismiss, auto-pause

Started Phase 6 (action layer). Three changes, app + daemon both build clean.

- **Blur window level → `.screenSaver`.** Was `.statusBar` (app
  `BlurOverlayManager`) and `maximumWindow+1` (daemon `ValueGuardOverlay`).
  Now both sit at `.screenSaver` per the Phase 6 spec — above the menu bar
  and status items, still above `.normal` so click-raises don't flicker.
- **Emergency dismiss hotkey (⌃⌥⌘D).** New `app/Sources/Actions/EmergencyHotkey.swift`
  using Carbon `RegisterEventHotKey` (fires system-wide, no Accessibility
  permission — required since the offending app, not ValueGuard, is frontmost
  when a blur is up). Tears down all blurs and snoozes actions for 120 s via
  `ActionDispatcher.emergencyDismiss()`. Also surfaced as a "Dismiss blur now"
  menu item for discoverability.
- **Auto-pause in sensitive contexts.** New
  `app/Sources/Actions/SensitiveContextMonitor.swift`. Heuristic: frontmost
  app is a known conferencing/recording bundle ID (Zoom, Teams classic+new,
  Webex, Meet desktop, OBS, QuickTime), OR Keynote/PowerPoint owns a
  full-display window (slideshow). When sensitive: dismiss all blurs + suppress
  blur/notify/block (logging continues). Wired through `ActionDispatcher`,
  gated by new `AppSettings.autoPauseInSensitiveContexts` (default on, General
  tab toggle). Known gap: browser-tab calls (Meet/Teams in a tab) are not
  detected — bundle ID too broad.

**Adversarial pre-PR review (multi-agent workflow): 8 confirmed findings, all
fixed before PR.**

- *(major)* Post-resume re-show gap: a blur torn down for a call/share/snooze
  never came back if the offending content stayed continuously on screen (the
  daemon emits no fresh `.activated` while hysteresis stays active). Fixed:
  `ActionDispatcher` now tracks `pendingBlur` on every transition regardless of
  suppression, and `resumeActions()` re-shows them when a sensitive context
  ends or the snooze elapses.
- *(major)* Heuristic only checked the *frontmost* app, so a backgrounded
  conferencing app during a real screen-share (user clicked into the shared
  window) leaked the blur onto the share. Fixed: `conferencingActive()` now
  also counts a known app that owns a visible normal-layer window; a menubar-
  only idle app still doesn't count (no all-day over-suppression).
- *(minor)* Emergency snooze never auto-resumed → fixed with a one-shot snooze
  `Timer` calling `resumeActions()`.
- *(minor)* Up-to-2 s poll latency could let a blur fire before suppression →
  fixed with a live `isSensitiveNow()` re-check on the blur path.
- *(minor)* `RegisterEventHotKey`/`InstallEventHandler` return values ignored →
  now checked, logged, and the handler is torn down on failure.
- *(nit)* nonisolated `deinit` touched Carbon APIs off-main → deinit removed
  (app-lifetime object; OS reclaims the hotkey on exit).
- *(nit)* `start()` idempotency guard added.
- *(nit)* Slideshow doc comment corrected (full-screen *editing* also trips it;
  intentional, on the safe side).

(4 further findings were reviewed and rejected as unreachable in current code.)

Not yet done for Phase 6: blur-fire latency instrumentation (<100 ms
acceptance). Behavior verification still pending — needs a real call/share and
flagged content to exercise the new paths end-to-end. Note Phase 6 is
nominally gated on Phase 5 (log-only deployment) producing stable numbers;
proceeded at user request.
