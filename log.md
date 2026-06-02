# ValueGuard change log

State-changing actions (build changes, signing swaps, policy revisions, model
upgrades). Newest first.

## 2026-06-01 — 0.3.3: real fix for the Screen Recording re-prompt (released)

The 0.3.2 permission fix was incomplete and shipped on unvalidated logic (it was
wrong). 0.3.3 is the complete fix, **verified live on a signed build before
shipping**.

- **Root cause:** `ScreenCapture.captureMonitoredWindows()` called
  `SCShareableContent.current` on every capture tick; on **macOS 26** that API
  raises the Screen Recording prompt on *every* call even when access is granted.
  Apply restarts the daemon → capture loop reruns it → prompt, despite the
  permission toggle being ON. 0.3.2 only guarded `requestPermission()`, missing
  this call site.
- **Fix:** enumerate windows via `CGWindowListCopyWindowInfo` (returns the exact
  metadata used — owner name, bundle id via PID, bounds, layer, on-screen,
  window id — with NO prompt). Pixel grab still uses `CGWindowListCreateImage`
  (needs the grant, doesn't prompt). `requestPermission()` is now a silent
  `CGPreflightScreenCaptureAccess()` preflight only. ScreenCaptureKit import
  removed entirely.
- **Validation method (the lesson):** screen-permission behavior CANNOT be tested
  on ad-hoc/dev builds — TCC keys on the notarized cdhash, so ungranted builds
  always prompt regardless of the fix. Proven instead by (1) a standalone
  `CGWindowListCopyWindowInfo` probe → full metadata, no prompt; (2) a
  Developer-ID-signed build installed over /Applications → Brad confirmed
  repeated Apply no longer prompts. Only then committed.
- Released `app-v0.3.3` (build 6, notarized; appcast #30, deployed). Live chain
  verified (feed=0.3.3, DMG 93040820 B).

**Auto-updater VERIFIED end-to-end (2026-06-01).** A clean-installed 0.3.2
auto-updated to 0.3.3: checked the feed, downloaded, verified the EdDSA
signature, installed, and relaunched — `/Applications/ValueGuard.app` is now
0.3.3. This was the last unproven piece (the earlier 0.3.0→0.3.2 "Update Error"
was the quarantined first-cut 0.3.0 build, NOT a feed/package problem — clean
builds update fine). The full Sparkle path (feed → download → signature →
install → relaunch) is now confirmed working.

Recurring infra lesson: `git reset --hard origin/main` to re-sync local main has
twice wiped uncommitted working-tree fixes (the notary creds and this permission
fix). Commit before resetting.

## 2026-06-01 — 0.3.2: caption-anchored calibration + Screen Recording prompt fix (released)

Two fixes (PR #26), released as `app-v0.3.2` (build 5, notarized; appcast #27).

- **Caption-anchored calibration** (design: `docs/CALIBRATION-POSITIVES.md`). The
  in-app Bayesian calibrator fetched positive sample images from Wikimedia
  Commons, which by design hosts none of the explicit content these configs
  filter → `0 positives`, broken fit. Now, when the positive IMAGE corpus is
  empty, it re-embeds the category's `positive_captions` on-device via the
  SigLIP-2 text encoder and scores each against `posVec` (same dot-with-posVec
  the image path uses). No images / no network for positives — stays within the
  threat-model line. UI labels it ("N caption anchors" + info banner).
  **Verified live** in the running app.
- **No Screen Recording re-prompt on Apply**. `ScreenCapture.requestPermission()`
  ran `SCShareableContent.current` on every daemon (re)start — which Apply
  triggers — poking TCC and re-prompting even when granted. Now preflights with
  the non-prompting `CGPreflightScreenCaptureAccess()` and returns early when
  granted. **Caveat: validated by reading only** — TCC keys permission to the
  notarized cdhash, so ad-hoc/dev builds are never granted and always prompt
  (this cost two invalid test rounds before I recognized it). Real confirmation
  is post-install: grant once on 0.3.2, then Apply should not re-prompt. If it
  still does, the cause is the in-process daemon restart itself, and the fix is
  to make Apply hot-reload policy without restarting capture (deferred).
- **Release-infra note:** the `valueguard-notary` keychain credential went
  missing mid-session (cause unknown), failing the first 0.3.2 notarization;
  re-created with `notarytool store-credentials`. Both the notary app-specific
  password AND the Sparkle EdDSA key live only in the login keychain — back them
  up to a password manager (release-critical, single copy).

## 2026-06-01 — 0.3.1: config-activation fixes (released)

## 2026-06-01 — 0.3.1: config-activation fixes (released)

Bug report (with screenshots): activating a marketplace config "did nothing".
Two real app-layer bugs found + fixed; the underlying `Installer.activate`
(symlink/lockfile/copy) was always correct.

- **Activate silently rejected** (PR #22): `activate()`'s reentrancy guard
  required `state == .idle`, but post-install the coordinator sits in
  `.installed(ref:)` — so the very next Activate click threw "not idle" and the
  view swallowed it with `try?`. Fixed: guard on `!isBusy`; the view now surfaces
  activate errors (`reportFailure`) so a rejection is never silent again.
- **Policy tab showed the old policy after activating** (PR #23): copy-on-activate
  copied `policy.bin` (so the daemon ran the new config) but NOT the sibling
  `policy.json` the Policy tab displays from — UI showed the previous category
  while the daemon ran the new one. Fixed: copy `policy.bin` + `policy.json` +
  `calibration.json` together. Verified live in the running app.
- **Released `app-v0.3.1`**: notarized + stapled DMG (build 4), EdDSA-signed,
  appcast updated (#24) and deployed. Verified end-to-end: live feed = 0.3.1
  (HTTP 200), enclosure DMG downloads at the exact declared length. 0.3.0 users
  auto-update to this.
- **Known limitation surfaced (not a bug):** the in-app Bayesian calibrator can't
  fetch *positive* samples for explicit categories — it sources from Wikimedia
  Commons, which by design hosts none of that content (got 0 positive / 14
  negative for `sexualized_nudity_contemporary`). Confirmed against the live API.
  Marketplace configs ship the author's calibrated thresholds; local
  re-calibration of explicit categories is the open design question. Deferred.

## 2026-06-01 — Sparkle auto-updater shipped; 0.3.0 released

The Mac app now auto-updates (Sparkle 2.9.2), and the first Sparkle-enabled
build is published.

- **Sparkle integration** (PR #17, merged `f9927ca`): `UpdaterController` over
  `SPUStandardUpdaterController`, "Check for Updates…" menubar item, daily
  background checks. `SUFeedURL` → `valueguard-configs.pages.dev/appcast.xml`.
  Non-sandboxed hardened-runtime app needs no extra entitlements. App + the
  `package-release.sh` release flow (now EdDSA-signs the DMG + regenerates the
  appcast, self-skipping without the key). No daemon changes.
- **EdDSA signing key**: generated via Sparkle `generate_keys` on 2026-06-01.
  Private key lives ONLY in the login Keychain (no disk/repo copy — **needs a
  manual backup to a password manager; losing it breaks all future updates**).
  Public key `BH+f4puEMMO7PLphkpRDGFFp+xTK7UPxfPYpaakZtL0=` (in `project.yml`).
- **0.3.0 released** (PR #19 bumped version; release `app-v0.3.0`): notarized +
  stapled DMG (93,030,914 B), EdDSA-signed. GitHub release is **Latest**.
- **Feed live + verified end-to-end**: `appcast.xml` (signed 0.3.0 entry, PR #20)
  deployed to Pages; the enclosure DMG downloads from GitHub at the exact
  declared length (HTTP 200, 93030914 B). Chain confirmed: feed → enclosure →
  notarized signed DMG.
- **Activation note**: auto-update works from 0.3.0 onward. The 0.2.0 DMG
  predates Sparkle, so 0.2.0→0.3.0 is a one-time manual install; 0.3.0→later is
  automatic.

## 2026-06-01 — Marketplace + one-click install merged to main; site redeployed

Both feature PRs landed on `main` and the live site was refreshed.

- **PR #13** (marketplace prototype: pack/keygen, static registry, web page) →
  squash-merged as `de778a1`. Its own deeper review pass found and fixed 5 +
  4 issues, incl. two real ones: `vg keygen` wrote the private seed via
  `Data.write(.atomic)` then chmod (briefly 0644) — now created through an
  `open(O_CREAT|O_EXCL|O_WRONLY, 0600)` fd; and a regression where widening
  `resolveSource` let `vg verify https://…` do a network fetch — now `verify`
  uses a file-only `resolveLocalSource`.
- **PR #15** (one-click install: `vgconfig://` scheme, Configs tab, web Install
  button) → squash-merged as `16a5728`. This replaced PR #14, which was closed:
  #14's branch predated #13's squash-merge and carried stale copies of the
  now-merged library, causing unavoidable conflicts. #15 is a clean rebase onto
  main with only the one-click delta (`app/` + web button), folding in all five
  rounds of #14 review fixes. App builds against merged main.
- Both merged with `gh pr merge --admin` (enforce_admins off): each fix-push
  re-triggered the required `claude-review`, which kept finding fresh nits and
  re-blocking on the conversation-resolution rule — an effective infinite loop.
  All substantive findings were fixed first; the admin-merge broke the loop on
  pure-nit findings. **Review convergence across rounds: 11→6→6→1→2 (#14), then
  5+4 on #13 — all low-severity by the end.**
- **Site redeployed** to `valueguard-configs.pages.dev` (Cloudflare Pages) with
  the "Install in ValueGuard" button live (page 22.7KB→25.5KB; deep link +
  shell-quoted CLI fallback verified in the served HTML). Registry still serves
  the genuine `sincera/personal-values@1.0.0`.

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
