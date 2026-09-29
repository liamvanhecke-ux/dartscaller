"""Slaat elke (kandidaat-)worp op: vóór, ná, verschilmasker en metadata."""
from __future__ import annotations

import json
import time
from pathlib import Path

import cv2

from .geometry import BoardCalibration
from .state_machine import Config, Event

LOGGED_KINDS = {"throw", "ghost"}


class SessionLogger:
    """
    sessions/<naam>/
      session.json                      kalibratie, ROI, config
      events.jsonl                      alle events (ook player_at_board, board_cleared…)
      throws/0001_throw/  before.jpg  after.jpg  diff.png  meta.json
      throws/0002_ghost/  …
    """

    def __init__(self, session_dir: str | Path, calibration: BoardCalibration, config: Config,
                 roi: tuple[int, int, int, int], source: str = ""):
        self.dir = Path(session_dir)
        (self.dir / "throws").mkdir(parents=True, exist_ok=True)
        self.count = len(list((self.dir / "throws").iterdir()))
        self.turn = 0
        (self.dir / "session.json").write_text(json.dumps({
            "created": time.strftime("%Y-%m-%d %H:%M:%S"),
            "source": source,
            "calibration": {"image_points": calibration.image_points, "image_size": calibration.image_size},
            "roi": list(roi),
            "config": config.to_dict(),
        }, indent=2))
        self.roi = roi

    def log(self, event: Event) -> Path | None:
        with open(self.dir / "events.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps({"kind": event.kind, "t": round(event.t, 3), "frame": event.frame_index,
                                "turn": self.turn, **event.data}) + "\n")
        if event.kind == "board_cleared":
            self.turn += 1
        if event.kind not in LOGGED_KINDS or event.after is None:
            return None
        self.count += 1
        folder = self.dir / "throws" / f"{self.count:04d}_{event.kind}"
        folder.mkdir(parents=True, exist_ok=True)
        cv2.imwrite(str(folder / "before.jpg"), event.before, [cv2.IMWRITE_JPEG_QUALITY, 92])
        cv2.imwrite(str(folder / "after.jpg"), event.after, [cv2.IMWRITE_JPEG_QUALITY, 92])
        if event.diff is not None:
            cv2.imwrite(str(folder / "diff.png"), event.diff)
        meta = {"id": folder.name, "kind": event.kind, "t": round(event.t, 3), "frame": event.frame_index,
                "turn": self.turn, "roi": list(self.roi), **event.data, "review": None}
        (folder / "meta.json").write_text(json.dumps(meta, indent=2))
        return folder
