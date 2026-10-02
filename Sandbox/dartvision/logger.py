"""Slaat elke (kandidaat-)worp op: vóór, ná, verschilmasker en metadata."""
from __future__ import annotations

import json
import time
from pathlib import Path

import cv2

from .geometry import CAL_ANGLES, CLASS_NAMES, DART_CLASS, BoardCalibration, cal_point_mm
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


def yolo_lines(cal: BoardCalibration, roi, darts_img, box: float = 0.025) -> list[str]:
    """Kalibratiepunten + pijlen (beeldpixels) als YOLO-regels voor een uitsnede `roi`."""
    x0, y0, w, h = roi

    def norm(p):
        nx, ny = (p[0] - x0) / w, (p[1] - y0) / h
        return (nx, ny) if 0 <= nx <= 1 and 0 <= ny <= 1 else None

    lines = []
    for cls, name in enumerate(CLASS_NAMES):
        if name in CAL_ANGLES:
            p = norm(cal.to_img([cal_point_mm(name)])[0])
            if p:
                lines.append(f"{cls} {p[0]:.6f} {p[1]:.6f} {box:.6f} {box:.6f}")
    for d in darts_img:
        p = norm(d)
        if p:
            lines.append(f"{DART_CLASS} {p[0]:.6f} {p[1]:.6f} {box:.6f} {box:.6f}")
    return lines


class HardNegativeSaver:
    """Bewaart beelden TIJDENS beweging (hand, persoon, vliegende pijl, schaduw).
    Gelabeld worden enkel de kalibratiepunten en de pijlen die al in het bord zitten:
    alles wat beweegt is dus 'geen pijl' voor het model."""

    def __init__(self, session_dir, calibration: BoardCalibration, roi, every_n: int = 6, max_count: int = 400):
        self.dir = Path(session_dir) / "hard_negatives"
        (self.dir / "images").mkdir(parents=True, exist_ok=True)
        (self.dir / "labels").mkdir(parents=True, exist_ok=True)
        self.cal, self.roi, self.every_n, self.max = calibration, roi, every_n, max_count
        self.count = len(list((self.dir / "images").glob("*.jpg")))
        self._tick = 0

    def offer(self, crop, darts_img, frame_index: int) -> bool:
        self._tick += 1
        if self.count >= self.max or self._tick % self.every_n:
            return False
        name = f"hn_{frame_index:07d}"
        cv2.imwrite(str(self.dir / "images" / f"{name}.jpg"), crop, [cv2.IMWRITE_JPEG_QUALITY, 92])
        (self.dir / "labels" / f"{name}.txt").write_text("\n".join(yolo_lines(self.cal, self.roi, darts_img)) + "\n")
        self.count += 1
        return True
