# Deploying the ValueGuard marketplace (prototype)

The marketplace prototype is a **static registry**: a single browse page plus an
`index.json`, content-addressed bundle blobs, and extracted manifests. There is
no backend. The whole thing is one directory of static files served over HTTPS,
which the `vg` CLI installs from.

```
registry-site/
  index.html        tracked — the browse page (zero-dependency static)
  index.json        tracked — SAMPLE seed data (3 demo configs) for local preview
  build-site.sh     tracked — assembles dist/ from the page + a REAL vg reindex
  dist/             gitignored — the publishable tree (page + real registry)
```

`build-site.sh` overlays the page with a real `vg reindex` of
`daemon/dist/bundles/*.vgconfig`, so everything under `dist/` is genuinely
installable — every `vg install` shown on the page actually works.

## 1. Build the publishable tree

```sh
# Assemble dist/ from whatever signed bundles are in daemon/dist/bundles/.
registry-site/build-site.sh

# On a fresh checkout with no bundles yet, SEED=1 packs the example config first
# (generates a throwaway signing key under daemon/dist/keys/):
SEED=1 registry-site/build-site.sh
```

Preview locally before deploying:

```sh
(cd registry-site/dist && python3 -m http.server 8765)
# open http://localhost:8765
```

## 2. Deploy to Cloudflare Pages

The chosen host is **Cloudflare Pages** (matches the existing Sincera stack;
`wrangler` is already installed — 4.93.1). For a prototype this size (~70 KB,
one bundle), serving the bundle blobs straight from Pages is simplest and
keeps everything in one origin — **R2 is not required yet** (see §4 for when to
graduate).

First-time auth (interactive — run it yourself in this terminal with the `!`
prefix so the browser flow works):

```
! wrangler login
```

Create the Pages project once, then deploy the assembled tree:

```sh
# one-time
wrangler pages project create valueguard-configs --production-branch main

# every deploy
wrangler pages deploy registry-site/dist --project-name valueguard-configs
```

That publishes to `https://valueguard-configs.pages.dev` — which is exactly the
prototype default baked into the CLI (`RegistryClient.defaultRegistryBase`). So
after the first deploy:

```sh
vg search                              # hits the live registry by default
vg install sincera/personal-values     # downloads + verifies + installs
```

No env var or `--registry` flag needed once the live URL matches the default.
To point at a different origin during testing:

```sh
VALUEGUARD_REGISTRY=https://your-preview.pages.dev vg search
vg install sincera/personal-values --registry https://your-preview.pages.dev
```

## 3. Custom domain (optional)

In the Cloudflare dashboard → Pages → valueguard-configs → Custom domains, add
e.g. `configs.sincera.works`. Then repoint the CLI default
(`RegistryClient.defaultRegistryBase`) at the custom domain and rebuild `vg`.

## 4. When to graduate off "static on Pages"

This layout is deliberately the cheapest credible cut. Move pieces out when:

- **Bundles get large or numerous** → put `bundles/<sha>.vgconfig` in **R2**,
  serve via a custom domain or the R2 public bucket, and have `vg reindex` write
  absolute `bundle_path` URLs (or set a `bundle_base` in `index.json`). Pages
  then hosts only `index.html` + `index.json` + `configs/`.
  ```sh
  wrangler r2 bucket create valueguard-bundles
  wrangler r2 object put valueguard-bundles/<sha>.vgconfig \
      --file daemon/dist/registry/bundles/<sha>.vgconfig
  ```
- **You need publish/auth/abuse-reports** → that is marketplace spec phase P1+
  (a real REST API), out of scope for this prototype. See `docs/MARKETPLACE.md`.

## Privacy note

Nothing user-side ever reaches this host. The registry serves only authored
config bundles (JSON + signed metadata + float vectors); screen content, frames,
embeddings, and calibration evidence never leave the device. `vg install`
verifies each bundle's Ed25519 signature **offline** before activating it.
