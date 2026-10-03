"""Statusmachine v2 voor worp-detectie — elke beslissing wordt gelogd met reden.

    S1 BEWEGING     kleine, korte beweging (statief-trilling weggerekend · touch-lockout)
    S2 STABIEL      300 ms stilte
    S3 VERSCHIL     t.o.v. baseline (uitgelijnd) → wát is nieuw?  + schaduwmasker (HSV) + nieuwe randen (Canny)
    S4 CONTROLE     grootte · vorm · contrast · schaduw · randen · licht · cooldown
    S5 YOLO ×3      op een ROI-patch rond de vlek; 3× binnen 5 px = goedgekeurd, anders terugval
    S6 KALIBRATIE   beeldpunt → mm
    S7 SCORE        ring + vak → "T20"
    BASELINE        direct na een worp + nogmaals na uittrillen

Logging:  import logging; logging.basicConfig(level=logging.DEBUG)   (of INFO voor enkel beslissingen)
Debugbeelden: DEBUG_VISUALS = True  (of Config.debug_dir) → diff, masker, schaduw, randen, YOLO-patch.
"""
from __future__ import annotations

import logging
import math
import time
from dataclasses import asdict, dataclass, field
from enum import Enum
from pathlib import Path

import cv2
import numpy as np

from .geometry import BoardCalibration

log = logging.getLogger("dartvision")

#: Zet op True om tussenbeelden op te slaan in Config.debug_dir (standaard ./debug_visuals).
DEBUG_VISUALS = False


@dataclass
class Config:
    # ── Beeldverwerking ────────────────────────────────────────────────────
    analysis_width: int = 480          # breedte van de bord-uitsnede voor analyse (px)
    motion_width: int = 160            # klein beeld voor bewegingsdetectie
    motion_pixel_thresh: int = 22
    # ── S1 Beweging ────────────────────────────────────────────────────────
    motion_frac_min: float = 0.0006
    still_frac: float = 0.0002
    obstruction_frac: float = 0.06
    obstruction_frames: int = 3
    max_motion_s: float = 0.8
    shake_max_shift: float = 3.0       # statief-trilling: globale verschuiving (px in bewegingsbeeld)
    shake_min_response: float = 0.25   # betrouwbaarheid phase correlation
    shake_edge_tolerance: float = 0.8  # extra tolerantie op scherpe randen na uitlijnen (× helling)
    touch_lockout_s: float = 0.35      # na notify_touch(): zo lang beweging negeren
    # ── S2 Stabilisatie ────────────────────────────────────────────────────
    settle_s: float = 0.30             # 300 ms stilte vóór analyse
    settle_frames: int = 5             # én minstens zoveel beelden (bij lage fps)
    # ── S3/S4 Verschil + controle ──────────────────────────────────────────
    diff_thresh: int = 30
    min_dart_area_frac: float = 0.0004
    max_dart_area_frac: float = 0.05
    min_elongation: float = 2.5
    min_contrast: float = 38.0
    lighting_delta: float = 6.0
    cooldown_s: float = 0.6
    # Schaduw (HSV): pixel wordt donkerder maar houdt dezelfde kleur
    shadow_v_ratio: tuple[float, float] = (0.30, 0.93)   # V_nu / V_baseline in dit bereik
    shadow_max_hue_diff: int = 12                          # OpenCV-hue (0..180)
    shadow_max_sat_diff: int = 45
    shadow_max_fraction: float = 0.60  # meer dan dit deel van de vlek is schaduw → ghost
    # Randen (Canny): een pijl voegt scherpe NIEUWE randen toe, een schaduw nauwelijks
    canny_low: int = 40
    canny_high: int = 120
    min_new_edge_density: float = 0.06 # nieuwe randpixels / vlekpixels
    # ── S5 YOLO ────────────────────────────────────────────────────────────
    require_model_confirmation: bool = False
    model_match_px: float = 40.0       # max. afstand YOLO-punt ↔ vlek (analysepixels)
    consensus_frames: int = 3
    consensus_radius_px: float = 5.0   # in modelpatch-pixels
    consensus_max_frames: int = 6
    yolo_width: int = 800              # bord-uitsnede wordt naar deze breedte geschaald (= training)
    yolo_patch_min: int = 192          # minimale patch (px, veelvoud van 32)
    yolo_patch_margin: float = 0.6     # patch = vlek-bbox × (1 + 2·marge)
    # ── Baseline ───────────────────────────────────────────────────────────
    baseline_refresh_s: float = 0.4    # na een worp: baseline opnieuw vastleggen als alles stil is
    # ── Bord leeg / persoon weg ────────────────────────────────────────────
    clear_still_frames: int = 25
    cleared_frac: float = 0.004
    baseline_still_frames: int = 15
    # ── Debug ──────────────────────────────────────────────────────────────
    debug_dir: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)


class State(str, Enum):
    NEEDS_BASELINE = "NEEDS_BASELINE"
    IDLE = "IDLE"
    MOTION = "MOTION"
    IMPACT = "IMPACT"
    CONFIRM = "CONFIRM"        # S5: YOLO-consensus over meerdere beelden
    OBSTRUCTED = "OBSTRUCTED"
    COOLDOWN = "COOLDOWN"


@dataclass
class Event:
    kind: str                  # baseline | throw | ghost | player_at_board | board_cleared | person_left
    t: float
    frame_index: int
    data: dict = field(default_factory=dict)
    before: np.ndarray | None = None
    after: np.ndarray | None = None
    diff: np.ndarray | None = None


@dataclass
class _Candidate:
    """Kandidaat-pijl die S4 doorstond en wacht op YOLO-consensus (S5)."""
    t: float
    tip_blob: tuple[float, float]          # analysepixels (huidige pose)
    bbox: tuple[int, int, int, int]        # vlek-bbox in analysepixels
    metrics: dict
    before: np.ndarray
    after: np.ndarray
    diff: np.ndarray
    yolo_points: list[list[tuple[float, float]]] = field(default_factory=list)
    trace: list[str] = field(default_factory=list)
    needs_model: bool = False              # twijfelgeval (schaduw?): zonder YOLO-consensus → ghost


class ThrowStateMachine:

    def __init__(self, calibration: BoardCalibration, config: Config | None = None, detector=None):
        self.cal = calibration
        self.cfg = config or Config()
        self.detector = detector
        self.roi = calibration.roi()
        x, y, w, h = self.roi
        self.scale = self.cfg.analysis_width / w
        self.aw, self.ah = self.cfg.analysis_width, max(8, int(round(h * self.scale)))
        self.camera_side = calibration.camera_side()

        self.state = State.NEEDS_BASELINE
        self.frame_index = 0
        self.prev_small: np.ndarray | None = None
        self.reference: np.ndarray | None = None          # grijs, analyse-resolutie
        self.reference_hsv: np.ndarray | None = None
        self.reference_color: np.ndarray | None = None    # BGR ROI, volle resolutie
        self.empty_board: np.ndarray | None = None
        self.pose_offset = np.zeros(2)                     # blijvende statiefverschuiving (analysepx)
        self.darts_this_turn: list[dict] = []
        self.last_throw_t = -1e9
        self.last_metrics: dict = {}
        self._still = 0
        self._still_since: float | None = None
        self._motion_start = 0.0
        self._large_frames = 0
        self._peak_motion = 0.0
        self._cooldown_until = 0.0
        self._lockout_until = -1e9
        self._refresh_at: float | None = None
        self._candidate: _Candidate | None = None
        self._t = 0.0

    # ═════════════════════════════════════════════════════════════ publiek
    def reset_baseline(self) -> None:
        self._log("BASELINE", "reset: nieuw leeg bord vastleggen")
        self.state, self._still = State.NEEDS_BASELINE, 0

    def new_turn(self) -> None:
        self._log("BEURT", f"nieuwe beurt ({len(self.darts_this_turn)} pijlen vergeten)")
        self.darts_this_turn = []

    def notify_touch(self, t: float | None = None) -> None:
        """S1: scherm aangeraakt → statief kan trillen. Beweging telt `touch_lockout_s` niet."""
        t = self._t if t is None else t
        self._lockout_until = t + self.cfg.touch_lockout_s
        self._log("S1 BEWEGING", f"touch-lockout tot t={self._lockout_until:.2f}s")

    def process(self, frame_bgr: np.ndarray, t: float | None = None) -> list[Event]:
        t = time.monotonic() if t is None else t
        self._t = t
        self.frame_index += 1
        crop = self._crop(frame_bgr)
        small_bgr = cv2.resize(crop, (self.aw, self.ah), interpolation=cv2.INTER_AREA)
        gray = cv2.GaussianBlur(cv2.cvtColor(small_bgr, cv2.COLOR_BGR2GRAY), (5, 5), 0)
        hsv = cv2.cvtColor(small_bgr, cv2.COLOR_BGR2HSV)
        motion, shift = self._motion(gray)
        locked = t < self._lockout_until
        if locked:
            motion = 0.0                          # S1: touch-lockout
        s = self.state

        # ── Baseline vastleggen ─────────────────────────────────────────────
        if s is State.NEEDS_BASELINE:
            self._still = self._still + 1 if motion < self.cfg.still_frac else 0
            if self._still >= self.cfg.baseline_still_frames:
                self._set_reference(gray, hsv, crop, empty=True, why="leeg bord vastgelegd")
                self.state = State.IDLE
                return [Event("baseline", t, self.frame_index)]
            return []

        # ── S5: YOLO-consensus loopt ────────────────────────────────────────
        if s is State.CONFIRM:
            if motion >= self.cfg.obstruction_frac:
                self._log("S5 YOLO", "grote beweging tijdens consensus → pijl met terugvalpunt melden", logging.WARNING)
                ev = self._finish_candidate(gray, hsv, crop, t, source="verschil (consensus onderbroken)")
                return ev + self._enter_obstructed(t, "grote beweging na worp")
            return self._step_consensus(gray, hsv, crop, t)

        # ── Geplande baseline-verversing (na uittrillen) ───────────────────
        if self._refresh_at is not None and t >= self._refresh_at and s in (State.IDLE, State.COOLDOWN):
            if motion < self.cfg.still_frac:
                self._set_reference(gray, hsv, crop, why="ververst na uittrillen (resttrilling/belichting weg)")
                self._refresh_at = None
            else:
                self._refresh_at = t + 0.1
                self._log("BASELINE", "verversing uitgesteld: nog beweging", logging.DEBUG)

        if s is State.COOLDOWN:
            if motion >= self.cfg.obstruction_frac:
                return self._enter_obstructed(t, "grote beweging tijdens cooldown")
            if motion >= self.cfg.motion_frac_min:
                self._log("S1 BEWEGING", f"beweging tijdens cooldown ({motion:.4f}) → toch analyseren (S4 beslist)")
                self._start_motion(t, motion)
            elif t >= self._cooldown_until:
                self.state = State.IDLE
                self._log("STATUS", "cooldown voorbij → IDLE", logging.DEBUG)
            return []

        if s is State.IDLE:
            if motion >= self.cfg.obstruction_frac:
                return self._enter_obstructed(t, f"grote beweging ({motion:.3f} ≥ {self.cfg.obstruction_frac})")
            if motion >= self.cfg.motion_frac_min:
                self._log("S1 BEWEGING", f"start: {motion:.4f} van de pixels beweegt"
                          + (f", trilling gecompenseerd {shift}" if shift else ""))
                self._start_motion(t, motion)
            elif shift:
                self._log("S1 BEWEGING", f"enkel statief-trilling {shift} → genegeerd", logging.DEBUG)
            return []

        if s is State.MOTION:
            self._peak_motion = max(self._peak_motion, motion)
            self._large_frames = self._large_frames + 1 if motion >= self.cfg.obstruction_frac else 0
            if self._large_frames >= self.cfg.obstruction_frames:
                return self._enter_obstructed(t, f"{self._large_frames} beelden grote beweging (persoon/hand)")
            if t - self._motion_start > self.cfg.max_motion_s:
                return self._enter_obstructed(t, f"beweging {t - self._motion_start:.2f}s > {self.cfg.max_motion_s}s")
            if motion < self.cfg.still_frac:
                self.state, self._still, self._still_since = State.IMPACT, 1, t
                self._log("S2 STABIEL", f"impact: beweging gestopt na {t - self._motion_start:.2f}s, wachten op stilte",
                          logging.DEBUG)
            return []

        if s is State.IMPACT:
            if motion >= self.cfg.obstruction_frac:
                return self._enter_obstructed(t, "grote beweging na impact")
            if motion >= self.cfg.motion_frac_min:
                self._log("S2 STABIEL", f"onderbroken: pijl trilt na ({motion:.4f}) → terug naar MOTION", logging.DEBUG)
                self.state = State.MOTION
                return []
            self._still += 1
            waited = t - (self._still_since or t)
            if self._still >= self.cfg.settle_frames and waited >= self.cfg.settle_s:
                self._log("S2 STABIEL", f"✓ {waited * 1000:.0f} ms stil ({self._still} beelden) → analyse")
                return self._analyze(gray, hsv, crop, t)
            return []

        if s is State.OBSTRUCTED:
            self._still = self._still + 1 if motion < self.cfg.still_frac else 0
            if self._still >= self.cfg.clear_still_frames:
                return self._after_obstruction(gray, hsv, crop, t)
            return []
        return []

    # ═════════════════════════════════════════════════════════════ S1
    def _motion(self, gray: np.ndarray) -> tuple[float, tuple[float, float] | None]:
        """Deel van de pixels dat LOKAAL beweegt, na compensatie van statief-trilling."""
        small = cv2.resize(gray, (self.cfg.motion_width, max(4, int(self.ah * self.cfg.motion_width / self.aw))),
                           interpolation=cv2.INTER_AREA)
        if self.prev_small is None or self.prev_small.shape != small.shape:
            self.prev_small = small
            return 1.0, None
        prev = self.prev_small
        shift = None
        (dx, dy), response = cv2.phaseCorrelate(prev.astype(np.float32), small.astype(np.float32))
        # Ook sub-pixel: 1–2 px trilling in het camerabeeld is hier maar 0,3–0,6 px
        if response >= self.cfg.shake_min_response and 0.15 <= math.hypot(dx, dy) <= self.cfg.shake_max_shift:
            M = np.float32([[1, 0, dx], [0, 1, dy]])
            prev = cv2.warpAffine(prev, M, (prev.shape[1], prev.shape[0]), borderMode=cv2.BORDER_REPLICATE)
            shift = (round(dx, 1), round(dy, 1))
        d = cv2.absdiff(small, prev).astype(np.float32)
        tol = np.full(d.shape, float(self.cfg.motion_pixel_thresh), np.float32)
        if shift:
            # Sub-pixel uitlijnen laat kleine fouten op scherpe randen (draden, ringen) achter.
            # Daar mag het verschil groter zijn; op egale vlakken (waar een pijl opvalt) niet.
            gx = cv2.Sobel(prev, cv2.CV_32F, 1, 0, ksize=3) / 4
            gy = cv2.Sobel(prev, cv2.CV_32F, 0, 1, ksize=3) / 4
            tol += self.cfg.shake_edge_tolerance * cv2.magnitude(gx, gy) * max(1.0, math.hypot(*shift))
        b = 4 if shift else 0                          # randen van het beeld na verschuiving niet meetellen
        if b:
            d, tol = d[b:-b, b:-b], tol[b:-b, b:-b]
        self.prev_small = small
        return float(np.count_nonzero(d > tol)) / d.size, shift

    def _start_motion(self, t: float, motion: float) -> None:
        self.state, self._motion_start = State.MOTION, t
        self._large_frames, self._peak_motion = 0, motion

    # ═════════════════════════════════════════════════════════════ S3 + S4
    def _analyze(self, gray, hsv, crop, t) -> list[Event]:
        cfg = self.cfg
        trace: list[str] = []
        ref, ref_hsv = self._aligned_reference(gray, trace)

        # S3: verschilbeeld
        diff = cv2.absdiff(gray, ref)
        mask = cv2.morphologyEx((diff > cfg.diff_thresh).astype(np.uint8), cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
        n, labels, stats, cents = cv2.connectedComponentsWithStats(mask, 8)
        comps = [i for i in range(1, n) if stats[i, cv2.CC_STAT_AREA] >= 6]
        mask = np.isin(labels, comps).astype(np.uint8)
        changed = int(mask.sum())
        self._log("S3 VERSCHIL", f"{changed} veranderde pixels in {len(comps)} vlek(ken)", trace=trace)

        # S3: schaduwmasker (HSV) — donkerder, zelfde tint, zelfde verzadiging
        v_now, v_ref = hsv[..., 2].astype(np.float32), ref_hsv[..., 2].astype(np.float32) + 1
        ratio = v_now / v_ref
        hue_d = np.abs(hsv[..., 0].astype(np.int16) - ref_hsv[..., 0].astype(np.int16))
        hue_d = np.minimum(hue_d, 180 - hue_d)
        sat_d = np.abs(hsv[..., 1].astype(np.int16) - ref_hsv[..., 1].astype(np.int16))
        lo, hi = cfg.shadow_v_ratio
        shadow = ((ratio >= lo) & (ratio <= hi) & (hue_d <= cfg.shadow_max_hue_diff)
                  & (sat_d <= cfg.shadow_max_sat_diff) & (mask > 0))
        # S3: NIEUWE randen (Canny): randen nu, die er in de baseline niet waren
        e_now = cv2.Canny(gray, cfg.canny_low, cfg.canny_high)
        e_ref = cv2.dilate(cv2.Canny(ref, cfg.canny_low, cfg.canny_high), np.ones((3, 3), np.uint8))
        new_edges = (e_now > 0) & (e_ref == 0)

        reasons: list[str] = []
        metrics: dict = {"lighting": round(abs(float(gray.mean()) - float(ref.mean())), 2),
                         "peak_motion": round(self._peak_motion, 5)}
        blob = None
        if comps:
            blob = self._merge_along_axis(labels, stats, cents, comps)
            ys, xs = np.nonzero(blob)
            area = xs.size / gray.size
            ev = np.sort(np.linalg.eigvalsh(np.cov(np.stack([xs, ys]).astype(np.float64)))) if xs.size > 2 else np.ones(2)
            elong = float(np.sqrt(ev[1] / max(ev[0], 1e-6)))
            contrast = float(diff[blob].mean())
            shadow_frac = float(shadow[blob].mean())
            # Randdichtheid op het NIET-schaduw-deel (de pijl zelf)
            solid = blob & ~shadow
            edge_density = float(new_edges[cv2.dilate(blob.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0].sum()) / max(1, xs.size)
            removal = 0.0
            if self.empty_board is not None:
                removal = float((cv2.absdiff(ref, self.empty_board)[blob].astype(np.float32)
                                 - cv2.absdiff(gray, self.empty_board)[blob].astype(np.float32)).mean())
            metrics.update(area_frac=round(area, 5), elongation=round(elong, 2), contrast=round(contrast, 1),
                           shadow_frac=round(shadow_frac, 2), edge_density=round(edge_density, 3),
                           removal=round(removal, 1))

            # S4: controles — elke afkeuring met reden
            checks = [
                (area >= cfg.min_dart_area_frac, f"te klein ({area:.5f} < {cfg.min_dart_area_frac})"),
                (area <= cfg.max_dart_area_frac, f"te groot ({area:.4f} > {cfg.max_dart_area_frac})"),
                (elong >= cfg.min_elongation, f"niet langwerpig ({elong:.1f} < {cfg.min_elongation})"),
                (contrast >= cfg.min_contrast, f"zacht contrast ({contrast:.0f} < {cfg.min_contrast:.0f})"),
                # Zachte schaduw (donkerder, zelfde kleur, weinig randen) → afkeuren.
                # Schaduwachtig MET scherpe randen is twijfel (harde schaduw óf donkere pijl op crème) → YOLO beslist.
                (shadow_frac <= cfg.shadow_max_fraction or edge_density >= 2 * cfg.min_new_edge_density,
                 f"schaduw: {shadow_frac:.0%} van de vlek is donkerder-zelfde-kleur, weinig randen ({edge_density:.3f})"),
                (edge_density >= cfg.min_new_edge_density, f"geen scherpe nieuwe randen ({edge_density:.3f})"),
                (removal <= 8, "pijl verwijderd i.p.v. bijgekomen"),
            ]
            for ok, why in checks:
                if not ok:
                    reasons.append(why)
            # De pijl zelf = vlek zonder schaduw (betere punt). Te weinig over? dan de hele vlek.
            if solid.sum() >= 0.3 * xs.size:
                blob = solid
        else:
            reasons.append("geen verandering op het bord")
        if metrics["lighting"] > cfg.lighting_delta:
            reasons.append(f"lichtverandering ({metrics['lighting']:.1f} > {cfg.lighting_delta})")
        if t - self.last_throw_t < cfg.cooldown_s:
            reasons.append(f"binnen cooldown ({t - self.last_throw_t:.2f}s < {cfg.cooldown_s}s)")

        self.last_metrics = metrics
        diff_vis = (mask * 255).astype(np.uint8)
        before, after = self.reference_color, crop.copy()
        self._save_debug("analyse", diff=diff_vis, shadow=(shadow * 255).astype(np.uint8),
                         new_edges=(new_edges * 255).astype(np.uint8), after=after)

        if reasons:
            self._log("S4 CONTROLE", "✗ GHOST: " + "; ".join(reasons) + f" | {metrics}", logging.INFO, trace)
            self.state, self._cooldown_until = State.COOLDOWN, t + 0.15
            if any("verwijderd" in r for r in reasons):
                return self._enter_obstructed(t, "pijlen worden opgehaald")
            self._set_reference(gray, hsv, crop, why="ghost-verandering opgenomen (niet opnieuw beoordelen)")
            return [Event("ghost", t, self.frame_index, {"reasons": reasons, "metrics": metrics, "trace": trace},
                          before=before, after=after, diff=diff_vis)]

        shadow_doubt = metrics.get("shadow_frac", 0) > cfg.shadow_max_fraction
        if shadow_doubt:
            self._log("S4 CONTROLE", f"? twijfel: schaduwachtig ({metrics['shadow_frac']:.0%}) maar scherpe randen "
                      f"→ {'YOLO moet bevestigen' if self.detector else 'geen model: telt als pijl'}", logging.INFO, trace)
        self._log("S4 CONTROLE", f"✓ geldig: {metrics}", logging.INFO, trace)
        ys, xs = np.nonzero(blob)
        bbox = (int(xs.min()), int(ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1))
        cand = _Candidate(t=t, tip_blob=self._tip_from_blob(blob), bbox=bbox, metrics=metrics,
                          before=before, after=after, diff=diff_vis, trace=trace, needs_model=shadow_doubt)
        self._log("S5 YOLO", f"terugvalpunt uit vlek: {tuple(round(v, 1) for v in cand.tip_blob)}", trace=trace)

        # Baseline METEEN bijwerken: de nieuwe pijl hoort er nu bij
        self._set_reference(gray, hsv, crop, why="pijl toegevoegd aan baseline")
        self._refresh_at = t + cfg.baseline_refresh_s

        if self.detector is None:
            self._log("S5 YOLO", "geen model geladen → terugvalpunt", trace=trace)
            self._candidate = cand
            return self._finish_candidate(gray, hsv, crop, t, source="verschil")
        self._candidate = cand
        self.state = State.CONFIRM
        return self._step_consensus(gray, hsv, crop, t)

    # ═════════════════════════════════════════════════════════════ S5
    def _yolo_patch(self, crop: np.ndarray, bbox) -> tuple[np.ndarray, tuple[int, int], float]:
        """Patch rond de vlek, op dezelfde schaal als tijdens training (bord-uitsnede = yolo_width)."""
        k = self.cfg.yolo_width / crop.shape[1]
        board = cv2.resize(crop, (self.cfg.yolo_width, int(round(crop.shape[0] * k))), interpolation=cv2.INTER_AREA)
        a2y = self.cfg.yolo_width / self.aw                       # analysepixels → yolo-bordpixels
        bx, by, bw, bh = (v * a2y for v in bbox)
        size = max(bw, bh) * (1 + 2 * self.cfg.yolo_patch_margin)
        size = int(math.ceil(max(self.cfg.yolo_patch_min, size) / 32) * 32)
        size = min(size, board.shape[1] // 32 * 32, board.shape[0] // 32 * 32)
        cx, cy = bx + bw / 2, by + bh / 2
        x0 = int(min(max(0, cx - size / 2), board.shape[1] - size))
        y0 = int(min(max(0, cy - size / 2), board.shape[0] - size))
        return board[y0:y0 + size, x0:x0 + size], (x0, y0), a2y

    def _step_consensus(self, gray, hsv, crop, t) -> list[Event]:
        c = self._candidate
        cfg = self.cfg
        patch, (px0, py0), a2y = self._yolo_patch(crop, c.bbox)
        tips = [d for d in self.detector.detect(patch, imgsz=patch.shape[1]) if d.label == "dart"]
        # Al getelde pijlen, omgerekend naar de HUIDIGE pose (kalibratiepose + statiefverschuiving)
        known = [((d["tip_img"][0] - self.roi[0]) * self.scale + self.pose_offset[0],
                  (d["tip_img"][1] - self.roi[1]) * self.scale + self.pose_offset[1]) for d in self.darts_this_turn]
        hint = c.tip_blob
        chosen, why = None, "geen pijlpunt in de patch"
        best = float("inf")
        for d in tips:
            pa = ((d.x + px0) / a2y, (d.y + py0) / a2y)                 # patch → analysepixels
            if any(math.hypot(pa[0] - k[0], pa[1] - k[1]) < 8 for k in known):
                why = "enige punt(en) = al getelde pijl"
                continue
            dist = math.hypot(pa[0] - hint[0], pa[1] - hint[1])
            if dist < best:
                best, chosen = dist, (d.x, d.y, pa, d.conf)
        frame_pts: list[tuple[float, float]] = []
        if chosen and best <= cfg.model_match_px:
            frame_pts.append((chosen[0], chosen[1]))
            self._log("S5 YOLO", f"beeld {len(c.yolo_points) + 1}: punt ({chosen[0]:.1f}, {chosen[1]:.1f}) "
                      f"conf {chosen[3]:.2f}, {best:.1f}px van de vlek", logging.DEBUG, c.trace)
        elif chosen:
            self._log("S5 YOLO", f"beeld {len(c.yolo_points) + 1}: dichtste punt te ver ({best:.0f}px > "
                      f"{cfg.model_match_px}px)", logging.DEBUG, c.trace)
        else:
            self._log("S5 YOLO", f"beeld {len(c.yolo_points) + 1}: {why} ({len(tips)} detecties)", logging.DEBUG, c.trace)
        c.yolo_points.append(frame_pts)
        self._save_debug("yolo_patch", patch=self._draw_points(patch, tips, frame_pts))

        # Consensus: in de laatste N beelden telkens een punt binnen de straal
        last = c.yolo_points[-cfg.consensus_frames:]
        if len(last) == cfg.consensus_frames and all(last):
            p0 = last[-1][0]
            if all(math.hypot(f[0][0] - p0[0], f[0][1] - p0[1]) <= cfg.consensus_radius_px for f in last):
                mx = sum(f[0][0] for f in last) / len(last) + px0
                my = sum(f[0][1] for f in last) / len(last) + py0
                c.tip_blob = (mx / a2y, my / a2y)
                self._log("S5 YOLO", f"✓ consensus: {cfg.consensus_frames}× binnen {cfg.consensus_radius_px}px", trace=c.trace)
                return self._finish_candidate(gray, hsv, crop, t, source="yolo")
        if len(c.yolo_points) >= cfg.consensus_max_frames:
            if cfg.require_model_confirmation or c.needs_model:
                why = "schaduw (model ziet geen pijl)" if c.needs_model else "model ziet geen stabiele nieuwe pijl"
                self._log("S5 YOLO", f"✗ geen consensus → GHOST: {why}", logging.INFO, c.trace)
                self._candidate = None
                self.state, self._cooldown_until = State.COOLDOWN, t + 0.15
                return [Event("ghost", t, self.frame_index,
                              {"reasons": [why], "metrics": c.metrics, "trace": c.trace},
                              before=c.before, after=c.after, diff=c.diff)]
            self._log("S5 YOLO", f"geen consensus na {len(c.yolo_points)} beelden → terugval op vlek-uiteinde",
                      logging.WARNING, c.trace)
            return self._finish_candidate(gray, hsv, crop, t, source="verschil (geen YOLO-consensus)")
        return []

    # ═════════════════════════════════════════════════════════════ S6 + S7
    def _finish_candidate(self, gray, hsv, crop, t, source: str) -> list[Event]:
        c = self._candidate
        self._candidate = None
        if c is None:
            return []
        x, y, _, _ = self.roi
        # S6: analysepixels (huidige pose) → kalibratiepose → volledig beeld → mm
        ax, ay = c.tip_blob[0] - self.pose_offset[0], c.tip_blob[1] - self.pose_offset[1]
        tip_img = (x + ax / self.scale, y + ay / self.scale)
        hit = self.cal.score_image_point(*tip_img)
        self._log("S6 KALIBRATIE", f"beeld ({tip_img[0]:.1f}, {tip_img[1]:.1f}) → mm ({hit.x_mm:.1f}, {hit.y_mm:.1f}), "
                  f"r = {math.hypot(hit.x_mm, hit.y_mm):.1f} mm", trace=c.trace)
        self._log("S7 SCORE", f"🎯 {hit.label} ({hit.score}) via {source}", logging.INFO, c.trace)
        self.last_throw_t = c.t
        self._cooldown_until = t + self.cfg.cooldown_s
        self.state = State.COOLDOWN
        self.darts_this_turn.append({"tip_img": tip_img, "label": hit.label})
        return [Event("throw", t, self.frame_index,
                      {"tip_img": [round(tip_img[0], 1), round(tip_img[1], 1)],
                       "tip_mm": [round(hit.x_mm, 1), round(hit.y_mm, 1)],
                       "label": hit.label, "score": hit.score, "source": source,
                       "dart_number": len(self.darts_this_turn), "metrics": c.metrics,
                       "darts_in_board": [d["tip_img"] for d in self.darts_this_turn[:-1]], "trace": c.trace},
                      before=c.before, after=c.after, diff=c.diff)]

    # ═════════════════════════════════════════════════════════════ hulp
    def _aligned_reference(self, gray, trace) -> tuple[np.ndarray, np.ndarray]:
        """Statief blijvend verschoven? Baseline mee verschuiven (en onthouden voor de kalibratie)."""
        ref, ref_hsv = self.reference, self.reference_hsv
        (dx, dy), resp = cv2.phaseCorrelate(ref.astype(np.float32), gray.astype(np.float32))
        if resp >= self.cfg.shake_min_response and 0.3 <= math.hypot(dx, dy) <= 12:
            M = np.float32([[1, 0, dx], [0, 1, dy]])
            size = (ref.shape[1], ref.shape[0])
            ref = cv2.warpAffine(ref, M, size, borderMode=cv2.BORDER_REPLICATE)
            ref_hsv = cv2.warpAffine(ref_hsv, M, size, borderMode=cv2.BORDER_REPLICATE)
            if self.empty_board is not None:
                self.empty_board = cv2.warpAffine(self.empty_board, M, size, borderMode=cv2.BORDER_REPLICATE)
            self.pose_offset += (dx, dy)
            self._log("S3 VERSCHIL", f"statief verschoven ({dx:.1f}, {dy:.1f})px → baseline uitgelijnd", trace=trace)
        return ref, ref_hsv

    def _crop(self, frame: np.ndarray) -> np.ndarray:
        x, y, w, h = self.roi
        return frame[y:y + h, x:x + w]

    def _set_reference(self, gray, hsv, crop, empty=False, why="") -> None:
        self.reference, self.reference_hsv, self.reference_color = gray.copy(), hsv.copy(), crop.copy()
        if empty:
            self.empty_board = gray.copy()
        self._log("BASELINE", why or "bijgewerkt", logging.DEBUG)

    def _enter_obstructed(self, t, reason) -> list[Event]:
        self.state, self._still = State.OBSTRUCTED, 0
        self._candidate = None
        self._log("S1 BEWEGING", f"OBSTRUCTIE: {reason} → niet scoren tot het bord weer stil is", logging.INFO)
        return [Event("player_at_board", t, self.frame_index,
                      {"reason": reason, "darts_seen": len(self.darts_this_turn)})]

    def _after_obstruction(self, gray, hsv, crop, t) -> list[Event]:
        self._set_reference(gray, hsv, crop, why="na obstructie")
        self.state = State.IDLE
        if self.empty_board is not None:
            m = cv2.morphologyEx((cv2.absdiff(gray, self.empty_board) > self.cfg.diff_thresh).astype(np.uint8),
                                 cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
            n, _, st, _ = cv2.connectedComponentsWithStats(m, 8)
            largest = float(st[1:, cv2.CC_STAT_AREA].max()) / m.size if n > 1 else 0.0
            frac = float(np.count_nonzero(m)) / m.size
            if largest < self.cfg.min_dart_area_frac * 0.6 and frac < self.cfg.cleared_frac:
                self.empty_board = gray.copy()
                n_darts = len(self.darts_this_turn)
                self.darts_this_turn = []
                self._log("BORD", f"leeg (grootste restvlek {largest:.5f}) → {n_darts} pijlen opgehaald", logging.INFO)
                return [Event("board_cleared", t, self.frame_index, {"darts_seen": n_darts, "diff_frac": frac})]
            self._log("BORD", f"persoon weg, maar er zit nog iets in het bord (restvlek {largest:.5f})", logging.INFO)
        return [Event("person_left", t, self.frame_index, {"darts_seen": len(self.darts_this_turn)})]

    @staticmethod
    def _merge_along_axis(labels, stats, cents, comps) -> np.ndarray:
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
            if np.hypot(*v) < max(12.0, 0.6 * length) or (perp <= max(6.0, 0.15 * length) and along <= 2.5 * length + 20):
                keep.append(i)
        return np.isin(labels, keep)

    def _tip_from_blob(self, blob: np.ndarray) -> tuple[float, float]:
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

    # ── logging & debugbeelden ─────────────────────────────────────────────
    def _log(self, step: str, msg: str, level: int = logging.INFO, trace: list[str] | None = None) -> None:
        line = f"[{self.frame_index:06d} {self._t:7.2f}s] [{step}] {msg}"
        log.log(level, line)
        if trace is not None:
            trace.append(f"[{step}] {msg}")

    def _save_debug(self, tag: str, **images: np.ndarray) -> None:
        if not (DEBUG_VISUALS or self.cfg.debug_dir):
            return
        d = Path(self.cfg.debug_dir or "debug_visuals") / f"{self.frame_index:06d}_{tag}"
        d.mkdir(parents=True, exist_ok=True)
        for name, img in images.items():
            if img is not None:
                cv2.imwrite(str(d / f"{name}.png"), img)

    @staticmethod
    def _draw_points(patch, tips, chosen) -> np.ndarray:
        vis = patch.copy()
        for d in tips:
            cv2.drawMarker(vis, (int(d.x), int(d.y)), (0, 200, 255), cv2.MARKER_CROSS, 14, 1)
        for p in chosen:
            cv2.circle(vis, (int(p[0]), int(p[1])), 6, (0, 255, 0), 2)
        return vis
