"""Per-platform data locations, mirroring the macOS daemon's layout."""

from __future__ import annotations

import os
import sys
from pathlib import Path


def data_dir() -> Path:
    """The ValueGuard support directory (policy.bin, audit.log)."""
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    elif sys.platform == "win32":
        base = Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local"))
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "ValueGuard"


def default_policy_path() -> Path:
    return data_dir() / "policy.bin"


def default_audit_path() -> Path:
    return data_dir() / "audit.log"
