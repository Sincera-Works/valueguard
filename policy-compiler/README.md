# policy-compiler

Compiles a plain-English values statement into a SigLIP-2-ready `policy.json`
via the Anthropic API. This is the *only* component of ValueGuard that ever
talks to the cloud — and it never sees a pixel of the user's screen.

## Install

```bash
npm install
export ANTHROPIC_API_KEY=sk-ant-...
```

## Use

```bash
# Personal mode (default)
npx tsx src/compile.ts examples/personal-values.md

# Corporate mode
npx tsx src/compile.ts examples/corporate-values.md corporate
```

Writes `<values>.policy.json` alongside the input file.

## What gets sent to Sonnet

Only the values statement itself. No screen content, no user identity, no
device information. Inspect the request shape in `src/compile.ts:46-54`.

## What you get back

A JSON document with one entry per category:

- `positive_captions` — 8-12 phrasings of the *unsafe* class
- `negative_captions` — 8-12 phrasings of the *safe* class
- `threshold` — cosine-similarity threshold for triggering the action
- `action` — `log` | `blur` | `block`
- `threshold_note` — reasoning the operator can use to tune

Plus `clarifications` (questions the model wants you to answer) and
`calibration_note` (general tuning advice).

## Design notes

- **No prefill, no `output_format`.** Uses `output_config.format` with a Zod
  schema for guaranteed parseable JSON.
- **Adaptive thinking.** The model decides how much to think; we don't set a
  fixed budget.
- **Model is Sonnet 4.6.** The compile happens rarely and the input is small,
  so Opus would be overkill. Sonnet handles this cleanly.
- **No caching.** The system prompt is ~600 tokens, well under Sonnet's 2048
  minimum cacheable prefix. And the compile runs rarely enough that caching
  would never hit anyway.

## Next step

Once `<values>.policy.json` exists, hand it to `model-conversion/embed_captions.py`
to turn the captions into 768-dim vectors for the daemon.
