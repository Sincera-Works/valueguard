# Threat model

ValueGuard is unusual: the primary "adversary" is often the user themselves.
The threat model has to be explicit because the right answer depends on who
the user is to themselves in that moment.

## Modes of use

### Mode A — personal accountability

The user installed ValueGuard because they want to filter their own
behavior. They are aligned with the system in their long-term interests
but adversarial in moments of weakness. They may also have an
accountability partner (spouse, sponsor) who receives notifications.

**Trust calculus:** the system does not need to be unkillable. It needs to
make tampering *visible* to the accountability partner. A daemon that
silently quit is the failure mode; a daemon that loudly tells the partner
"I was just killed" is the success.

### Mode B — corporate acceptable use

The user is an employee on a corporate laptop. The IT admin installed
ValueGuard via MDM. The user may not want it running. The corporate trust
model is "user does not have local admin", which is enforced by MDM.

**Trust calculus:** standard corporate-managed-device assumptions. The
daemon runs as a LaunchDaemon under root, the user cannot uninstall it,
configuration changes are signed and audited.

### Mode C — corporate compliance

The user is a finance/healthcare/legal employee on a screen-monitored
workstation. ValueGuard's job is to enforce a content policy, but the
*marketing* is that no screen content ever leaves the device.

**Trust calculus:** same as Mode B for tamper resistance, plus a hard
guarantee that the daemon does not phone home with screen content. The
compliance story is the product.

## Threats and mitigations

| # | Threat | Likelihood | Mode | Mitigation |
|---|---|---|---|---|
| 1 | User kills the daemon | High | A, B | Partner notification on heartbeat loss (A); LaunchDaemon + MDM (B). |
| 2 | User revokes Screen Recording permission | High | A | Partner notification; daemon refuses to run silently. |
| 3 | User installs a network filter that blocks the partner endpoint | Medium | A | Heartbeat is fail-open from the partner's perspective — they get pinged when it stops, not when it works. |
| 4 | False-positive blur during a presentation / interview / financial transaction | Medium | All | v0.1 ships log-only; blur is gated on a measured FP rate. Sensitive-context detection (Zoom running, screen sharing, Keynote presenter mode) auto-pauses filtering. |
| 5 | False-negative on rare/adversarial content | Medium | All | Acknowledged limitation. The zero-shot SigLIP-2 classifier is ~85–92% accurate out of the box; a fine-tuned MLP head on logged flags pushes this to ~97% over time. Not perfect; not advertised as perfect. |
| 6 | Cloud compile leaks values statement | Low | All | The values statement is the only thing sent to the cloud LLM — whatever chat AI the user pastes it into (the app is model-agnostic), or Anthropic's API via the `policy-compiler` CLI. It contains the user's preferences but no pixels, no PII, no device info. **Mode C (compliance) deployments must use the CLI's fixed Anthropic endpoint, not the open-ended app paste-bridge, so the destination is contractually specifiable.** Documented explicitly. |
| 7 | Audit log leaks sensitive context | Medium | All | Audit log is local-only, encrypted at rest (SQLCipher in v0.2). Thumbnails (if ever stored) are blurred *before* writing to disk. |
| 8 | Adversarial inputs designed to fool SigLIP-2 | Low | A, C | Acknowledged. Trivially defeated by small crops, brightness shifts, or steganographic content. ValueGuard is a behavioral aid, not a hardened content gate. |
| 9 | Partner notification endpoint is compromised | Low | A | Notifications contain only blurred thumbnails + category metadata. No raw pixels. |
| 10 | Daemon binary is modified to disable filtering | Medium | B, C | Signed binary, hardened runtime, code signature verified by `launchd`. Out of scope for v0.1; will require Developer ID certificate. |

## What ValueGuard is NOT designed to prevent

- A motivated, technically sophisticated user from defeating it on their
  own machine. If they have root and know what they are doing, they win.
  That is true of every accountability tool.
- A motivated attacker on the network from sending unfiltered content to
  the screen. Network-layer filtering is a separate problem with a
  separate solution stack (we explicitly punted on it — see
  `docs/ARCHITECTURE.md`).
- All possible false positives or false negatives. The classifier is
  probabilistic. The calibration phase is the answer.

## Privacy guarantees (Mode C compliance language)

The following statements are intended to be defensible in a SOC 2 control
document. They are also true.

1. **No raw screen content is transmitted from the device to any
   third party.** Inference runs locally on the Apple Neural Engine via
   CoreML. Embeddings are computed locally and used only for cosine
   similarity against the local policy.
2. **No SigLIP-2 vision embeddings are transmitted from the device.**
   They live in memory for the duration of a single frame's scoring and
   are then discarded.
3. **The only data transmitted off-device is the values statement,
   transmitted once at policy-compile time.**
   - *App (personal use):* pasted into a user-chosen chat AI; the app holds
     no API key and never calls a model itself.
   - *`policy-compiler` CLI (Mode B/C):* sent to the Anthropic API (Sonnet)
     — a bounded, contractually-specifiable endpoint. **Compliance (Mode C)
     deployments must use this path**, not the open-ended app paste-bridge,
     so the data flow in this control statement is bounded.

   The values statement is authored by the admin (corporate mode) or
   user (personal mode) and contains generic English-language
   preferences.
4. **The audit log is local-only.** It contains category IDs, timestamps,
   and float similarity scores. No image data, no embeddings, no URLs,
   no application identifiers.
5. **The optional accountability bridge (Mode A) transmits only blurred
   thumbnails and category metadata, never raw pixels.** This module is
   off by default and must be explicitly configured by the user.

Every one of these statements is enforced in code, not by policy.
