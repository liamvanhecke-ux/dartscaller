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

    def detect(self, bgr: np.ndarray) -> list[Detection]:
        r = self.model.predict(bgr, imgsz=self.imgsz, conf=self.conf, verbose=False)[0]
        out = []
        for c, xywh, cf in zip(r.boxes.cls.tolist(), r.boxes.xywh.tolist(), r.boxes.conf.tolist()):
            out.append(Detection(self.names[int(c)], float(xywh[0]), float(xywh[1]), float(cf)))
        return out

    def calibration_points(self, bgr: np.ndarray, min_conf: float = 0.5) -> dict[str, tuple[float, float]]:
        """Beste detectie per kalibratiepunt (min. 4 nodig voor BoardCalibration)."""
        best: dict[str, Detection] = {}
        for d in self.detect(bgr):
            if d.label in CAL_ANGLES and d.conf >= min_conf and (d.label not in best or d.conf > best[d.label].conf):
                best[d.label] = d
        return {k: (v.x, v.y) for k, v in best.items()}
