"""Optionele YOLO-detector (Ultralytics). Zelfde klassen als het app-model: 20, 3, 11, 6, dart, 9, 15."""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .geometry import CAL_ANGLES


@dataclass
class Detection:
    label: str
    x: float      # pixels in het beeld dat aan detect() gegeven werd
    y: float
    conf: float


class DartDetector:
    def __init__(self, weights: str, conf: float = 0.25, imgsz: int = 800):
        from ultralytics import YOLO          # pas laden als je echt een model gebruikt
        self.model = YOLO(weights)
        self.conf, self.imgsz = conf, imgsz
        self.names = self.model.names

    def detect(self, bgr: np.ndarray, imgsz: int | None = None, iou: float = 0.65) -> list[Detection]:
        """imgsz=None → standaard (800). Voor een ROI-patch: geef de patchgrootte (veelvoud van 32),
        dan blijft de pijl even groot als tijdens training (geen op-/afschalen)."""
        r = self.model.predict(bgr, imgsz=imgsz or self.imgsz, conf=self.conf, iou=iou, verbose=False)[0]
        out = []
        for c, xywh, cf in zip(r.boxes.cls.tolist(), r.boxes.xywh.tolist(), r.boxes.conf.tolist()):
            out.append(Detection(self.names[int(c)], float(xywh[0]), float(xywh[1]), float(cf)))
        return out

    def calibration_points(self, bgr: np.ndarray, min_conf: float = 0.5) -> dict[str, tuple[float, float]]:
        """Kalibratiepunten, robuust tegen verwisselde labels (zie robust_calibration)."""
        return robust_calibration(self.detect(bgr), min_conf)


def robust_calibration(dets: list[Detection], min_conf: float = 0.5, tol_mm: float = 12.0) -> dict[str, tuple[float, float]]:
    """RANSAC: het model verwart soms links/rechts (bv. 8|11 gelabeld als "15").
    Probeer alle 4-tallen labels × kandidaten en houd de punten die samen een geldig bord vormen."""
    import itertools
    import math
    import cv2
    from .geometry import cal_point_mm
    cands: dict[str, list[Detection]] = {}
    for d in dets:
        if d.label in CAL_ANGLES and d.conf >= min_conf * 0.4:
            cands.setdefault(d.label, []).append(d)
    for k in cands:
        cands[k] = sorted(cands[k], key=lambda d: -d.conf)[:3]
    names = sorted(cands)
    best_score, best = -1.0, {}
    for quad in itertools.combinations(names, 4):
        for pick in itertools.product(*(cands[n] for n in quad)):
            if not any(d.conf >= min_conf for d in pick):
                continue
            src = np.float32([cal_point_mm(n) for n in quad])
            dst = np.float32([(d.x, d.y) for d in pick])
            try:
                H = cv2.getPerspectiveTransform(src, dst)
                inv = np.linalg.inv(H)
            except (cv2.error, np.linalg.LinAlgError):
                continue
            score, inl = 0.0, {}
            for n in names:
                tx, ty = cal_point_mm(n)
                ok = []
                for d in cands[n]:
                    q = cv2.perspectiveTransform(np.float32([[[d.x, d.y]]]), inv)[0, 0]
                    if math.hypot(q[0] - tx, q[1] - ty) <= tol_mm:
                        ok.append(d)
                if ok:
                    d = max(ok, key=lambda d: d.conf)
                    score += d.conf
                    inl[n] = (d.x, d.y)
            if score > best_score:
                best_score, best = score, inl
    return best if len(best) >= 4 else {}
