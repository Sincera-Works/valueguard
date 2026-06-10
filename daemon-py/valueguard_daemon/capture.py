"""1 Hz per-monitor frame source built on mss.

mss is the cross-platform pivot of this daemon: XGetImage/XShm under X11,
GDI BitBlt on Windows, CoreGraphics on macOS — all comfortably fast enough
at 1 frame per second. Per-monitor capture is the documented v0.1 narrowing
of macOS's per-window model.

Frames come back from mss as BGRA; each monitor's frame is converted to RGB
and resized to 256×256 here so the engine and hash always see the same
buffer geometry the classifier consumes (as on macOS, where the stream is
rasterized straight to 256×256).
"""

from __future__ import annotations

import numpy as np

from .preprocess import resize_rgb


class MonitorCapture:
    def __init__(self) -> None:
        import mss

        self._sct = mss.mss()
        # monitors[0] is the all-monitors union; 1.. are individual monitors.
        self.monitor_ids = list(range(1, len(self._sct.monitors)))

    def grab(self, monitor_id: int) -> np.ndarray:
        """Capture one monitor -> 256×256 uint8 RGB."""
        shot = self._sct.grab(self._sct.monitors[monitor_id])
        bgra = np.frombuffer(shot.bgra, dtype=np.uint8).reshape(shot.height, shot.width, 4)
        rgb = bgra[:, :, 2::-1]  # BGRA -> RGB, drops alpha
        return resize_rgb(np.ascontiguousarray(rgb))

    def close(self) -> None:
        self._sct.close()
