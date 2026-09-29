"""Bordgeometrie, scoring en kalibratie (zelfde maten en kalibratiepunten als de iOS-app)."""
from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

SEGMENTS = [20, 1, 18, 4, 13, 6, 10, 15, 2, 17, 3, 19, 7, 16, 8, 11, 14, 9, 12, 5]
R_BULL, R_OUTER_BULL = 6.35, 15.9
R_TREBLE_IN, R_TREBLE_OUT = 99.0, 107.0
R_DOUBLE_IN, R_DOUBLE_OUT = 162.0, 170.0

# YOLO-klassen (zelfde als Training/darts.yaml en het meegeleverde model)
CLASS_NAMES = ["20", "3", "11", "6", "dart", "9", "15"]
DART_CLASS = 4
# Kalibratiepunt → hoek (graden, x rechts / y omhoog) op de buitenrand van de double-ring
CAL_ANGLES = {"20": 99.0, "6": 9.0, "3": -81.0, "11": -171.0, "9": 153.0, "15": -27.0}
# Volgorde bij handmatig klikken
MANUAL_ORDER = [("20", "draad 5|20 (boven)"), ("6", "draad 13|6 (rechts)"),
                ("3", "draad 17|3 (onder)"), ("11", "draad 8|11 (links)")]


def cal_point_mm(label: str) -> tuple[float, float]:
    a = math.radians(CAL_ANGLES[label])
    return R_DOUBLE_OUT * math.cos(a), R_DOUBLE_OUT * math.sin(a)


@dataclass(frozen=True)
class Hit:
    segment: int      # 1..20, 25 = bull, 0 = mis
    multiplier: int   # 0 mis, 1 single, 2 double, 3 triple
    x_mm: float = 0.0
    y_mm: float = 0.0

    @property
    def score(self) -> int:
        return self.segment * self.multiplier

    @property
    def label(self) -> str:
        if self.multiplier == 0:
            return "MIS"
        if self.segment == 25:
            return "BULL" if self.multiplier == 2 else "25"
        return {1: "S", 2: "D", 3: "T"}[self.multiplier] + str(self.segment)


def score_point(x: float, y: float) -> Hit:
    """Punt in mm (middelpunt = 0,0; y omhoog) → worp."""
    r = math.hypot(x, y)
    if r <= R_BULL:
        return Hit(25, 2, x, y)
    if r <= R_OUTER_BULL:
        return Hit(25, 1, x, y)
    if r > R_DOUBLE_OUT:
        return Hit(0, 0, x, y)
    angle = math.degrees(math.atan2(y, x))
    from_edge = (99.0 - angle) % 360.0
    segment = SEGMENTS[min(19, int(from_edge // 18))]
    if R_TREBLE_IN <= r <= R_TREBLE_OUT:
        mult = 3
    elif r >= R_DOUBLE_IN:
        mult = 2
    else:
        mult = 1
    return Hit(segment, mult, x, y)


def parse_label(text: str) -> Hit | None:
    """'T20', 'D16', 'S5', '5', '25', 'BULL', 'MIS' → Hit (zonder positie)."""
    t = text.strip().upper()
    if t in ("MIS", "MISS", "0", "M"):
        return Hit(0, 0)
    if t in ("BULL", "50", "DB"):
        return Hit(25, 2)
    if t in ("25", "SB", "OB"):
        return Hit(25, 1)
    mult = {"S": 1, "D": 2, "T": 3}.get(t[:1], 1)
    num = t[1:] if t[:1] in "SDT" else t
    if num.isdigit() and 1 <= int(num) <= 20:
        return Hit(int(num), mult)
    return None


def nearest_point_in(hit: Hit, x: float, y: float, margin: float = 2.0) -> tuple[float, float]:
    """Dichtste punt binnen het vak van `hit` (voor correcties zonder klik)."""
    r = math.hypot(x, y)
    th = math.degrees(math.atan2(y, x)) if r > 1e-9 else 90.0
    if hit.multiplier == 0:
        r = max(r, R_DOUBLE_OUT + margin)
    elif hit.segment == 25:
        r = min(r, R_BULL - margin) if hit.multiplier == 2 else min(max(r, R_BULL + margin), R_OUTER_BULL - margin)
    else:
        bands = {3: [(R_TREBLE_IN, R_TREBLE_OUT)], 2: [(R_DOUBLE_IN, R_DOUBLE_OUT)]}.get(
            hit.multiplier, [(R_OUTER_BULL, R_TREBLE_IN), (R_TREBLE_OUT, R_DOUBLE_IN)])
        r = min((min(max(r, a + margin), b - margin) for a, b in bands), key=lambda c: abs(c - r))
        center = 90.0 - SEGMENTS.index(hit.segment) * 18.0
        d = (th - center + 180.0) % 360.0 - 180.0
        half = 9.0 - math.degrees(margin / r)
        th = center + max(-half, min(half, d))
    return r * math.cos(math.radians(th)), r * math.sin(math.radians(th))


class BoardCalibration:
    """Beeld (pixels, oorsprong linksboven) ↔ bord (mm). Werkt met 4 tot 6 kalibratiepunten."""

    def __init__(self, image_points: dict[str, tuple[float, float]], image_size: tuple[int, int]):
        labels = [l for l in image_points if l in CAL_ANGLES]
        if len(labels) < 4:
            raise ValueError("Minstens 4 kalibratiepunten nodig")
        img = np.array([image_points[l] for l in labels], dtype=np.float64)
        mm = np.array([cal_point_mm(l) for l in labels], dtype=np.float64)
        H, _ = cv2.findHomography(img, mm, 0)   # 0 = kleinste kwadraten over alle punten
        if H is None:
            raise ValueError("Punten vormen geen geldig bord")
        self.image_points = {l: tuple(map(float, image_points[l])) for l in labels}
        self.image_size = (int(image_size[0]), int(image_size[1]))   # (breedte, hoogte)
        self.H_img2mm = H
        self.H_mm2img = np.linalg.inv(H)

    # --- omrekenen ---
    @staticmethod
    def _apply(H: np.ndarray, pts) -> np.ndarray:
        p = np.asarray(pts, dtype=np.float64).reshape(-1, 1, 2)
        return cv2.perspectiveTransform(p, H).reshape(-1, 2)

    def to_mm(self, pts) -> np.ndarray:
        return self._apply(self.H_img2mm, pts)

    def to_img(self, pts_mm) -> np.ndarray:
        return self._apply(self.H_mm2img, pts_mm)

    def score_image_point(self, x: float, y: float) -> Hit:
        mx, my = self.to_mm([(x, y)])[0]
        return score_point(float(mx), float(my))

    def roi(self, margin: float = 1.25) -> tuple[int, int, int, int]:
        """Uitsnede rond het bord (x, y, w, h), begrensd door het beeld."""
        a = np.radians(np.arange(0, 360, 10))
        ring = self.to_img(np.stack([np.cos(a), np.sin(a)], 1) * R_DOUBLE_OUT * margin)
        W, H = self.image_size
        x0, y0 = np.clip(ring.min(0), 0, [W - 1, H - 1]).astype(int)
        x1, y1 = np.clip(ring.max(0), 1, [W, H]).astype(int)
        return int(x0), int(y0), int(x1 - x0), int(y1 - y0)

    def camera_side(self) -> np.ndarray | None:
        """Eenheidsvector in het beeld richting camera (kant die groter lijkt). None = camera recht ervoor."""
        c = self.to_img([(0.0, 0.0)])[0]
        best, best_ratio = 0.0, 0.0
        for deg in range(0, 360, 5):
            a, b = math.radians(deg), math.radians(deg + 180)
            p = self.to_img([(170 * math.cos(a), 170 * math.sin(a)), (170 * math.cos(b), 170 * math.sin(b))])
            ratio = np.linalg.norm(p[0] - c) / max(np.linalg.norm(p[1] - c), 1e-6)
            if ratio > best_ratio:
                best, best_ratio = deg, ratio
        if best_ratio < 1.03:
            return None
        a = math.radians(best)
        v = self.to_img([(170 * math.cos(a), 170 * math.sin(a))])[0] - c
        return v / np.linalg.norm(v)

    def draw(self, img: np.ndarray, color=(0, 255, 255), offset=(0, 0), scale=1.0) -> None:
        """Bord-draadmodel over een (uitgesneden/geschaalde) afbeelding tekenen."""
        ox, oy = offset
        def to_px(pts_mm):
            p = self.to_img(pts_mm)
            return (((p - [ox, oy]) * scale)).astype(np.int32)
        a = np.radians(np.arange(0, 361, 5))
        for r in (R_OUTER_BULL, R_TREBLE_IN, R_TREBLE_OUT, R_DOUBLE_IN, R_DOUBLE_OUT):
            cv2.polylines(img, [to_px(np.stack([np.cos(a), np.sin(a)], 1) * r)], False, color, 1, cv2.LINE_AA)
        for k in range(20):
            t = math.radians(99 - 18 * k)
            p = to_px([(R_OUTER_BULL * math.cos(t), R_OUTER_BULL * math.sin(t)),
                       (R_DOUBLE_OUT * math.cos(t), R_DOUBLE_OUT * math.sin(t))])
            cv2.line(img, tuple(map(int, p[0])), tuple(map(int, p[1])), color, 1, cv2.LINE_AA)

    # --- opslaan ---
    def save(self, path: str | Path) -> None:
        Path(path).write_text(json.dumps({"image_points": self.image_points, "image_size": self.image_size}, indent=2))

    @classmethod
    def load(cls, path: str | Path) -> "BoardCalibration":
        d = json.loads(Path(path).read_text())
        return cls({k: tuple(v) for k, v in d["image_points"].items()}, tuple(d["image_size"]))
