"""Statusmachine voor worp-detectie zonder "ghost throws".

    IDLE ──kleine, korte beweging──► MOTION ──stilstand──► IMPACT ──N stille frames──► VERIFY
      ▲                                │  │                  │                           │
      │                    grote/lange beweging      beweging terug (trillende pijl)     │
      │                                ▼                     ▼                           │
      │                           OBSTRUCTED ◄──────────  MOTION                    worp ✔ / ghost ✘
      │                     (persoon/hand: NOOIT scoren)                                 │
      └──── bord stil + persoon weg ◄────┘                         COOLDOWN ◄────────────┘

Elke kandidaat-worp moet ALLE controles doorstaan (zie `_verify`). Faalt er één, dan wordt het
een "ghost"-event mét reden, zodat je in de sandbox ziet wélke drempel ingreep.
"""
from __future__ import annotations

import time
from dataclasses import asdict, dataclass, field
from enum import Enum

import cv2
import numpy as np

from .geometry import BoardCalibration, Hit


@dataclass
class Config:
    # Beeldverwerking
    analysis_width: int = 480          # breedte van de bord-uitsnede voor analyse (px)
    motion_width: int = 160            # kleiner beeld voor bewegingsdetectie
    motion_pixel_thresh: int = 22      # grijsverschil per pixel dat als beweging telt
    # Motion Phase
    motion_frac_min: float = 0.0006    # deel van de pixels dat moet bewegen om MOTION te starten
    still_frac: float = 0.0002         # hieronder = stil
    obstruction_frac: float = 0.06     # zoveel beweging in één frame = persoon/hand
    obstruction_frames: int = 3        # zoveel frames met grote beweging → OBSTRUCTED
    max_motion_s: float = 0.8          # een worp is kort; langere beweging = persoon
    # Impact Phase
    settle_frames: int = 5             # opeenvolgende stille frames voor analyse
    # Verificatie (vormverandering op het bord)
    diff_thresh: int = 30              # grijsverschil t.o.v. referentie
    min_dart_area_frac: float = 0.0004   # laag genoeg voor een pijl waarvan de flight buiten beeld valt
    max_dart_area_frac: float = 0.05
    min_elongation: float = 2.5        # pijl = langwerpig (verhouding hoofdassen)
    min_contrast: float = 38.0         # gem. verschil in de blob; schaduwen zijn zacht
    lighting_delta: float = 6.0        # gem. helderheidsverschil hele bord = lichtverandering
    cooldown_s: float = 0.6            # minimale tijd tussen twee worpen
    # Model (optioneel)
    require_model_confirmation: bool = False   # True: YOLO moet de nieuwe pijl ook zien
    model_match_px: float = 40.0       # max. afstand YOLO-punt ↔ verschil-blob (in analysebeeld)
    # Bord leeg / persoon weg
    clear_still_frames: int = 25
    cleared_frac: float = 0.004        # zo weinig verschil met het lege bord = pijlen zijn eruit
    baseline_still_frames: int = 15

    def to_dict(self) -> dict:
        return asdict(self)


class State(str, Enum):
    NEEDS_BASELINE = "NEEDS_BASELINE"
    IDLE = "IDLE"
    MOTION = "MOTION"
    IMPACT = "IMPACT"
    OBSTRUCTED = "OBSTRUCTED"
    COOLDOWN = "COOLDOWN"


@dataclass
class Event:
    kind: str                  # baseline | throw | ghost | player_at_board | board_cleared | person_left | lighting
    t: float
    frame_index: int
    data: dict = field(default_factory=dict)
    # Beelden voor de sandbox (uitsnede van het bord, BGR, volle resolutie van de ROI)
    before: np.ndarray | None = None
    after: np.ndarray | None = None
    diff: np.ndarray | None = None


class ThrowStateMachine:

    def __init__(self, calibration: BoardCalibration, config: Config | None = None, detector=None):
        self.cal = calibration
        self.cfg = config or Config()
        self.detector = detector                    # dartvision.detector.DartDetector of None
        self.roi = calibration.roi()
        x, y, w, h = self.roi
        self.scale = self.cfg.analysis_width / w    # ROI-pixels → analysepixels
        self.aw, self.ah = self.cfg.analysis_width, max(8, int(round(h * self.scale)))
        side = calibration.camera_side()
        self.camera_side = side                      # zelfde oriëntatie als het analysebeeld

        self.state = State.NEEDS_BASELINE
        self.frame_index = 0
        self.prev_small: np.ndarray | None = None
        self.reference: np.ndarray | None = None     # grijs analysebeeld vóór de worp
        self.reference_color: np.ndarray | None = None
        self.empty_board: np.ndarray | None = None
        self.darts_this_turn: list[dict] = []        # {tip_img, hit} van getelde pijlen
        self.last_throw_t = -1e9
        self._still = 0
        self._motion_start = 0.0
        self._large_frames = 0
        self._peak_motion = 0.0
        self._cooldown_until = 0.0
        self.last_metrics: dict = {}

    # ------------------------------------------------------------------ publiek
    def reset_baseline(self) -> None:
        self.state = State.NEEDS_BASELINE
        self._still = 0

    def new_turn(self) -> None:
        self.darts_this_turn = []

    def process(self, frame_bgr: np.ndarray, t: float | None = None) -> list[Event]:
        t = time.monotonic() if t is None else t
        self.frame_index += 1
        crop = self._crop(frame_bgr)
        gray = cv2.GaussianBlur(cv2.cvtColor(cv2.resize(crop, (self.aw, self.ah), interpolation=cv2.INTER_AREA),
                                             cv2.COLOR_BGR2GRAY), (5, 5), 0)
        small = cv2.resize(gray, (self.cfg.motion_width, max(4, int(self.ah * self.cfg.motion_width / self.aw))),
                           interpolation=cv2.INTER_AREA)
        motion = self._motion(small)
        events: list[Event] = []
        s = self.state

        if s is State.NEEDS_BASELINE:
            self._still = self._still + 1 if motion < self.cfg.still_frac else 0
            if self._still >= self.cfg.baseline_still_frames:
                self._set_reference(gray, crop, empty=True)
                self.state = State.IDLE
                events.append(Event("baseline", t, self.frame_index))
            return events

        if s is State.COOLDOWN:
            if motion >= self.cfg.obstruction_frac:
                return self._enter_obstructed(t, crop, "grote beweging tijdens cooldown")
            if motion >= self.cfg.motion_frac_min:
                # Toch analyseren: _verify keurt af met reden "binnen cooldown" (zichtbaar in de sandbox)
                self.state, self._motion_start = State.MOTION, t
                self._large_frames, self._peak_motion = 0, motion
            elif t >= self._cooldown_until:
                self.state = State.IDLE
            return events

        if s is State.IDLE:
            if motion >= self.cfg.obstruction_frac:
                return self._enter_obstructed(t, crop, "grote beweging")
            if motion >= self.cfg.motion_frac_min:
                self.state, self._motion_start = State.MOTION, t
                self._large_frames, self._peak_motion = 0, motion
            return events

        if s is State.MOTION:
            self._peak_motion = max(self._peak_motion, motion)
            self._large_frames = self._large_frames + 1 if motion >= self.cfg.obstruction_frac else 0
            if self._large_frames >= self.cfg.obstruction_frames:
                return self._enter_obstructed(t, crop, "persoon/hand in beeld")
            if t - self._motion_start > self.cfg.max_motion_s:
                return self._enter_obstructed(t, crop, f"beweging > {self.cfg.max_motion_s}s")
            if motion < self.cfg.still_frac:
                self.state, self._still = State.IMPACT, 1
            return events

        if s is State.IMPACT:
            if motion >= self.cfg.obstruction_frac:
                return self._enter_obstructed(t, crop, "grote beweging na impact")
            if motion >= self.cfg.motion_frac_min:
                self.state = State.MOTION           # pijl trilt nog na
                return events
            self._still += 1
            if self._still >= self.cfg.settle_frames:
                events += self._verify(gray, crop, t)
            return events

        if s is State.OBSTRUCTED:
            self._still = self._still + 1 if motion < self.cfg.still_frac else 0
            if self._still >= self.cfg.clear_still_frames:
                events += self._after_obstruction(gray, crop, t)
            return events
        return events

    # ------------------------------------------------------------------ intern
    def _crop(self, frame: np.ndarray) -> np.ndarray:
        x, y, w, h = self.roi
        return frame[y:y + h, x:x + w]

    def _motion(self, small: np.ndarray) -> float:
        if self.prev_small is None or self.prev_small.shape != small.shape:
            self.prev_small = small
            return 1.0
        d = cv2.absdiff(small, self.prev_small)
        self.prev_small = small
        return float(np.count_nonzero(d > self.cfg.motion_pixel_thresh)) / d.size

    def _set_reference(self, gray, crop, empty=False) -> None:
        self.reference, self.reference_color = gray.copy(), crop.copy()
        if empty:
            self.empty_board = gray.copy()

    def _enter_obstructed(self, t, crop, reason) -> list[Event]:
        self.state, self._still = State.OBSTRUCTED, 0
        return [Event("player_at_board", t, self.frame_index,
                      {"reason": reason, "darts_seen": len(self.darts_this_turn)})]

    def _after_obstruction(self, gray, crop, t) -> list[Event]:
        """Persoon weg en beeld stil: pijlen opgehaald, of gewoon iemand die voorbij liep?"""
        self._set_reference(gray, crop)
        self.state = State.IDLE
        if self.empty_board is not None:
            m = (cv2.absdiff(gray, self.empty_board) > self.cfg.diff_thresh).astype(np.uint8)
            m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
            n, _, st, _ = cv2.connectedComponentsWithStats(m, 8)
            largest = float(st[1:, cv2.CC_STAT_AREA].max()) / m.size if n > 1 else 0.0
            frac = float(np.count_nonzero(m)) / m.size
            if largest < self.cfg.min_dart_area_frac * 0.6 and frac < self.cfg.cleared_frac:
                self.empty_board = gray.copy()      # licht bijwerken
                n = len(self.darts_this_turn)
                self.darts_this_turn = []
                return [Event("board_cleared", t, self.frame_index, {"darts_seen": n, "diff_frac": frac})]
        return [Event("person_left", t, self.frame_index, {"darts_seen": len(self.darts_this_turn)})]

    def _verify(self, gray, crop, t) -> list[Event]:
        """Meervoudige verificatie. Alle controles moeten slagen."""
        cfg = self.cfg
        ref = self.reference
        diff = cv2.absdiff(gray, ref)
        mask = (diff > cfg.diff_thresh).astype(np.uint8)
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))   # zacht: dunne schacht blijft

        total = gray.size
        lighting = abs(float(gray.mean()) - float(ref.mean()))
        n, labels, stats, cents = cv2.connectedComponentsWithStats(mask, 8)
        metrics = {"lighting": round(lighting, 2), "peak_motion": round(self._peak_motion, 5)}
        reasons: list[str] = []
        blob = None
        comps = [i for i in range(1, n) if stats[i, cv2.CC_STAT_AREA] >= 6]          # losse ruispixels weg
        mask = np.isin(labels, comps).astype(np.uint8)

        if comps:
            blob = self._merge_along_axis(labels, stats, cents, comps)
            ys, xs = np.nonzero(blob)
            area = xs.size / total
            cov = np.cov(np.stack([xs, ys]).astype(np.float64)) if xs.size > 2 else np.eye(2)
            ev = np.sort(np.linalg.eigvalsh(cov))
            elong = float(np.sqrt(ev[1] / max(ev[0], 1e-6)))
            contrast = float(diff[blob].mean())
            # Weggenomen i.p.v. bijgekomen? (lijkt nu meer op het lege bord)
            removal = 0.0
            if self.empty_board is not None:
                removal = float((cv2.absdiff(ref, self.empty_board)[blob].astype(np.float32) -
                                 cv2.absdiff(gray, self.empty_board)[blob].astype(np.float32)).mean())
            metrics.update(area_frac=round(area, 5), elongation=round(elong, 2),
                           contrast=round(contrast, 1), removal=round(removal, 1))

            if area < cfg.min_dart_area_frac:
                reasons.append("te kleine verandering")
            if area > cfg.max_dart_area_frac:
                reasons.append("te grote verandering")
            if elong < cfg.min_elongation:
                reasons.append("niet langwerpig (schaduw/ruis?)")
            if contrast < cfg.min_contrast:
                reasons.append("te zacht contrast (schaduw?)")
            if removal > 8:
                reasons.append("pijl verwijderd i.p.v. bijgekomen")
        else:
            reasons.append("geen verandering op het bord")
        if lighting > cfg.lighting_delta:
            reasons.append("lichtverandering")
        if t - self.last_throw_t < cfg.cooldown_s:
            reasons.append("binnen cooldown")

        tip_a, source = None, "verschil"
        if blob is not None and not reasons:
            tip_a = self._tip_from_blob(blob)
            model_tip = self._model_tip(crop, tip_a)
            if model_tip is not None:
                tip_a, source = model_tip, "yolo"
            elif self.detector is not None and cfg.require_model_confirmation:
                reasons.append("model ziet geen nieuwe pijl")

        self.last_metrics = metrics
        diff_vis = (mask * 255).astype(np.uint8)
        before, after = self.reference_color, crop.copy()
        self.state, self._cooldown_until = State.COOLDOWN, t + 0.15

        if reasons:
            if "pijl verwijderd i.p.v. bijgekomen" not in reasons:
                self._set_reference(gray, crop)       # deze verandering niet opnieuw beoordelen
            if "pijl verwijderd i.p.v. bijgekomen" in reasons:
                return self._enter_obstructed(t, crop, "pijlen worden opgehaald")
            return [Event("ghost", t, self.frame_index, {"reasons": reasons, "metrics": metrics},
                          before=before, after=after, diff=diff_vis)]

        # Geldige worp
        x, y, w, h = self.roi
        tip_img = (x + tip_a[0] / self.scale, y + tip_a[1] / self.scale)
        hit = self.cal.score_image_point(*tip_img)
        self._set_reference(gray, crop)
        self.last_throw_t = t
        self._cooldown_until = t + cfg.cooldown_s
        self.darts_this_turn.append({"tip_img": tip_img, "label": hit.label})
        return [Event("throw", t, self.frame_index,
                      {"tip_img": [round(tip_img[0], 1), round(tip_img[1], 1)],
                       "tip_mm": [round(hit.x_mm, 1), round(hit.y_mm, 1)],
                       "label": hit.label, "score": hit.score, "source": source,
                       "dart_number": len(self.darts_this_turn), "metrics": metrics,
                       "darts_in_board": [d["tip_img"] for d in self.darts_this_turn[:-1]]},
                      before=before, after=after, diff=diff_vis)]

    @staticmethod
    def _merge_along_axis(labels, stats, cents, comps) -> np.ndarray:
        """Grootste stuk + stukken die in het verlengde van de pijl liggen (schacht valt vaak weg)."""
        main = max(comps, key=lambda i: stats[i, cv2.CC_STAT_AREA])
        keep = [main]
        ys, xs = np.nonzero(labels == main)
        pts = np.stack([xs, ys], 1).astype(np.float64)
        c = pts.mean(0)
        if len(pts) >= 5:
            _, vecs = np.linalg.eigh(np.cov((pts - c).T))
            axis = vecs[:, 1]
            length = float(np.ptp((pts - c) @ axis)) + 1
        else:
            axis, length = np.array([0.0, 1.0]), 5.0
        for i in comps:
            if i == main:
                continue
            v = cents[i] - c
            along, perp = abs(float(v @ axis)), abs(float(v[0] * axis[1] - v[1] * axis[0]))
            near_box = np.hypot(*v) < max(12.0, 0.6 * length)
            if near_box or (perp <= max(6.0, 0.15 * length) and along <= 2.5 * length + 20):
                keep.append(i)
        return np.isin(labels, keep)

    def _tip_from_blob(self, blob: np.ndarray) -> tuple[float, float]:
        """Punt = uiteinde van de pijl aan de camerakant (PCA-as), anders het zwaartepunt."""
        ys, xs = np.nonzero(blob)
        pts = np.stack([xs, ys], 1).astype(np.float64)
        mean = pts.mean(0)
        if self.camera_side is None or len(pts) < 5:
            return float(mean[0]), float(mean[1])
        _, vecs = np.linalg.eigh(np.cov((pts - mean).T))
        axis = vecs[:, 1]
        if axis @ self.camera_side < 0:
            axis = -axis
        proj = (pts - mean) @ axis
        cap = pts[proj >= proj.max() - 2.0]
        return float(cap[:, 0].mean()), float(cap[:, 1].mean())

    def _model_tip(self, crop: np.ndarray, hint_a: tuple[float, float]) -> tuple[float, float] | None:
        """YOLO-pijlpunt die het dichtst bij de verschil-blob ligt en nog niet geteld is."""
        if self.detector is None:
            return None
        tips = [d for d in self.detector.detect(crop) if d.label == "dart"]
        known = [((p[0] - self.roi[0]) * self.scale, (p[1] - self.roi[1]) * self.scale)
                 for p in (d["tip_img"] for d in self.darts_this_turn)]
        best, best_d = None, float("inf")
        for d in tips:
            p = (d.x * self.scale, d.y * self.scale)            # crop-pixels → analysepixels
            if any(np.hypot(p[0] - k[0], p[1] - k[1]) < 8 for k in known):
                continue
            dist = float(np.hypot(p[0] - hint_a[0], p[1] - hint_a[1]))
            if dist < best_d:
                best, best_d = p, dist
        return best if best is not None and best_d <= self.cfg.model_match_px else None
