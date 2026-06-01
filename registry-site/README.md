# ValueGuard config registry — browse page

A minimal, zero-dependency **static** web page that lists the config bundles
published to the ValueGuard registry. It is a single self-contained
`index.html` that fetches `./index.json` (same directory) at runtime and renders
a searchable grid of config cards. No build step, no frameworks, no external
CDNs — it works offline and deploys to Cloudflare Pages with zero config.

## What ValueGuard is

ValueGuard is an on-device macOS content filter. It samples the screen at 1 Hz,
runs SigLIP-2 on the Apple Neural Engine, and compares each frame against a
policy compiled from a plain-English values statement. **Pixels never leave the
device.**

This registry distributes portable, signed **config bundles** (`.vgconfig`) — a
values policy + calibrated thresholds + an Ed25519 signature — that users install
locally with the `vg` CLI:

```
vg install <author>/<slug>
```

**Privacy boundary:** the registry hosts only configs (JSON + signed metadata +
float vectors). It never sees user screen content. Installing a bundle verifies
its signature **offline** before it is activated.

## The data contract

The page renders whatever it finds in `index.json` (schema `schema_version: 1`).
Top level: `schema_version`, `generated_at`, `registry.name`, and a `configs`
array. Each config carries `author`, `slug`, `name`, `description`,
`latest_version`, `license`, `tags`, `verified`, `author_fingerprint`, and a
`versions` array (each version: `version`, `created_at`, `bundle_sha256`,
`bundle_path`, `manifest_path`, `size_bytes`, and a `categories` list of
`{ id, action }` where `action` is `log` / `blur` / `block`). All paths are
relative to the site root.

> **The committed `index.json` here is SAMPLE / seed data** (3 example configs)
> so the page can be demoed before the real registry exists. At deploy time the
> Swift `vg reindex` tool overwrites `index.json` and populates `bundles/` and
> `configs/` with the real, signed artifacts. Do not rely on the sample hashes.

## Preview locally

From the repo root:

```bash
# Python (stdlib)
python3 -m http.server 8765 --directory registry-site
# then open http://localhost:8765/

# or, with Node
npx serve registry-site
```

Serve from the directory root so `./index.json` resolves correctly.

## Deploy

The whole `registry-site/` directory is the deploy artifact. `vg reindex`
populates it with the live `index.json`, `bundles/*.vgconfig`, and
`configs/<author>/<slug>/<version>/manifest.json`, then the directory is pushed
to Cloudflare Pages (static, no build command).

## Files

| File         | Purpose                                                        |
|--------------|---------------------------------------------------------------|
| `index.html` | The entire UI — HTML + CSS + JS inline, no dependencies.       |
| `index.json` | Sample registry index (overwritten by `vg reindex` at deploy).|
| `README.md`  | This file.                                                     |
| `bundles/`   | (generated) signed `.vgconfig` bundles.                        |
| `configs/`   | (generated) per-version `manifest.json` files.                |
