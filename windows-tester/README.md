# ValueGuard — Windows tester build

Thanks for trying this. ValueGuard is an on-device content filter: it looks
at your screen once a second, runs each frame through a small vision model
**on your machine**, and notes when something matches a category in your
values policy. The whole point of the product:

> **Your screen never leaves your computer.** No screenshots are uploaded,
> no classification happens in any cloud. The daemon does not use the
> network at all — only this setup script downloads things (Python and the
> model, from pinned, hash-verified URLs).

This tester build is **log-only**: it never blurs, blocks, or interferes
with anything. It just writes a local log of what it *would* have acted on,
so we can measure accuracy. It uses a default general-purpose policy.

## Install (Windows 10/11, x64)

1. Download `ValueGuard-Windows-Tester.zip` from the release page and
   extract it anywhere (e.g. Downloads).
2. In the extracted folder, right-click → "Open in Terminal" (or open
   PowerShell there) and run:

   ```
   powershell -ExecutionPolicy Bypass -File .\setup.ps1
   ```

   `-ExecutionPolicy Bypass` applies **only to this one invocation** —
   it does not change your system's script policy. It's needed because this
   tester script isn't code-signed (the polished installer will be).

3. That's it. Setup installs Python 3.12 (per-user) if you don't have it,
   downloads the vision model (~372 MB, one time), starts the filter, and
   registers it to start when you log in. The zip folder can be deleted
   afterwards.

Everything lands in `%LOCALAPPDATA%\ValueGuard`. Expect roughly 500 MB of
memory use while running (the tester ships the unoptimized model; the real
build will be much smaller).

## Seeing what it does

The log of flagged moments is a plain text file:

```
notepad %LOCALAPPDATA%\ValueGuard\audit.log
```

Each line is one event with the category, score, and timestamp. If the file
stays empty, it never saw anything it would have acted on.

## Uninstall

From the extracted folder (or re-download it):

```
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

That stops the daemon and removes the autostart entry. Your data —
including the audit log — stays in `%LOCALAPPDATA%\ValueGuard`; delete that
folder to remove every trace.

## Verifying what you downloaded (optional)

SHA-256, checkable with `Get-FileHash <file>` in PowerShell:

| File | SHA-256 |
|---|---|
| `SigLIP2Vision.fp32.onnx` (release asset) | `dd5f1505c2057a17e0d8cc8438e1d61cdc95737e26e94c9b94c52a3395623003` |
| `default.policy.bin` (in the zip) | `a81055ef5d6fd5f301345b4236a32feb521529c2dd079045fb9b7b8b4c863435` |

`setup.ps1` checks these (plus the Python and VC++ installers) automatically
before using anything it downloads.

## Feedback

Anything confusing, broken, or slow:
https://github.com/Sincera-Works/valueguard/issues
