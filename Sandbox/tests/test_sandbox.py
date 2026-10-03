"""Tests met synthetische beelden.  Draaien:  python tests/test_sandbox.py"""
from __future__ import annotations

import json
import math
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from dartvision.geometry import (CAL_ANGLES, BoardCalibration, R_DOUBLE_OUT, R_TREBLE_IN,  # noqa: E402
                                 R_TREBLE_OUT, SEGMENTS, cal_point_mm, parse_label, score_point)
from dartvision.state_machine import Config, ThrowStateMachine                           # noqa: E402

W, H, FPS = 800, 600, 30


def mm_to_img(x, y):
    """Schuin perspectief: camera onder het bord (onderkant lijkt groter)."""
    w = 1 + y * 0.0012
    return 400 + 1.3 * x / w, 300 - 1.25 * y / w


def board_image() -> np.ndarray:
    img = np.full((H, W, 3), (70, 110, 150), np.uint8)       # houten muur
    def poly(r1, r2, a1, a2):
        pts = [mm_to_img(r2 * math.cos(math.radians(a)), r2 * math.sin(math.radians(a))) for a in np.linspace(a1, a2, 8)]
        pts += [mm_to_img(r1 * math.cos(math.radians(a)), r1 * math.sin(math.radians(a))) for a in np.linspace(a2, a1, 8)]
        return np.array(pts, np.int32)
    cv2.fillPoly(img, [poly(0, 225, 0, 359.9)], (25, 25, 25))
    for i in range(20):
        a1 = 81 - i * 18
        even = i % 2 == 0
        cv2.fillPoly(img, [poly(16, 99, a1, a1 + 18)], (30, 30, 30) if even else (200, 220, 230))
        cv2.fillPoly(img, [poly(99, 107, a1, a1 + 18)], (40, 40, 200) if even else (60, 140, 40))
        cv2.fillPoly(img, [poly(107, 162, a1, a1 + 18)], (30, 30, 30) if even else (200, 220, 230))
        cv2.fillPoly(img, [poly(162, 170, a1, a1 + 18)], (40, 40, 200) if even else (60, 140, 40))
    cv2.fillPoly(img, [poly(6.35, 15.9, 0, 359.9)], (60, 140, 40))
    cv2.fillPoly(img, [poly(0, 6.35, 0, 359.9)], (40, 40, 200))
    return img


def draw_dart(img, tip_mm, wobble=0):
    tx, ty = mm_to_img(*tip_mm)
    fx, fy = tx + 6 + wobble, ty - 70                        # flight boven de punt (camera zit onder)
    cv2.line(img, (int(tx), int(ty)), (int(fx), int(fy)), (120, 120, 130), 3, cv2.LINE_AA)   # grijze barrel
    cv2.rectangle(img, (int(fx) - 7, int(fy) - 22), (int(fx) + 7, int(fy)), (255, 60, 200), -1)


def calibration() -> BoardCalibration:
    return BoardCalibration({l: mm_to_img(*cal_point_mm(l)) for l in ("20", "6", "3", "11")}, (W, H))


class Sim:
    def __init__(self, cfg=None):
        self.sm = ThrowStateMachine(calibration(), cfg or Config())
        self.base = board_image()
        self.darts: list[tuple[float, float]] = []
        self.t = 0.0
        self.events = []
        self.frames = []

    def frame(self, extra=None):
        img = self.base.copy()
        for d in self.darts:
            draw_dart(img, d)
        if extra:
            extra(img)
        return img

    def run(self, n, extra=None):
        for _ in range(n):
            self.t += 1 / FPS
            img = self.frame(extra)
            self.frames.append(img)
            self.events += self.sm.process(img, self.t)

    def throw(self, tip_mm):
        # Pijl in de lucht: 2 frames een streep net naast het bord, dan impact + natrillen
        tx, ty = mm_to_img(*tip_mm)
        for dx in (-120, -60):
            self.run(1, lambda im, dx=dx: cv2.line(im, (int(tx + dx), int(ty - 40)), (int(tx + dx + 40), int(ty - 50)), (240, 240, 240), 3))
        self.darts.append(tip_mm)
        for wob in (3, -2, 1):
            self.t += 1 / FPS
            img = self.base.copy()
            for d in self.darts[:-1]:
                draw_dart(img, d)
            draw_dart(img, tip_mm, wobble=wob)
            self.frames.append(img)
            self.events += self.sm.process(img, self.t)
        self.run(20)

    def kinds(self):
        return [e.kind for e in self.events]


def person(x):
    return lambda im: cv2.rectangle(im, (x, 0), (x + 260, H), (90, 70, 60), -1)


def test_geometry():
    assert score_point(0, 103).label == "T20"
    assert score_point(0, -166).label == "D3"
    assert score_point(3, 2).label == "BULL"
    assert parse_label("t20").label == "T20" and parse_label("bull").label == "BULL" and parse_label("x") is None
    cal = calibration()
    for mm, lab in (((0, 103), "T20"), ((166, 0), "D6"), ((-60, -40), "S16")):
        assert cal.score_image_point(*mm_to_img(*mm)).label == lab, lab
    side = cal.camera_side()
    assert side is not None and side[1] > 0.9, "camera onder het bord"


def test_real_throws_scored():
    s = Sim()
    s.run(20)
    assert s.kinds() == ["baseline"]
    errors = []
    for tip in ((1, 103), (60, -20), (-2, 165), (-70, -60), (25, -100)):
        lab = score_point(*tip).label
        s.events = []
        s.throw(tip)
        throws = [e for e in s.events if e.kind == "throw"]
        assert len(throws) == 1, (lab, s.kinds(), s.sm.last_metrics)       # statusmachine: precies 1 worp
        err = math.dist(throws[0].data["tip_mm"], tip)
        errors.append(err)
        # Puntbepaling zonder model: binnen 10 mm (exacte score = taak van YOLO + review)
        assert err < 10, (throws[0].data, lab, err)
    print(f"   puntfout heuristiek: gem. {sum(errors) / len(errors):.1f} mm, max {max(errors):.1f} mm")


def test_person_walking_up_no_score():
    s = Sim()
    s.run(20)
    s.throw((1, 103))
    s.events = []
    for x in range(-260, 900, 40):          # iemand loopt voor het bord langs
        s.run(1, person(x))
    s.run(40)
    k = s.kinds()
    assert "throw" not in k and "ghost" not in k, k
    assert k[0] == "player_at_board" and s.events[0].data["darts_seen"] == 1
    assert k[-1] == "person_left", k          # pijl zit er nog: geen "bord leeg"


def test_pickup_clears_board():
    s = Sim()
    s.run(20)
    s.throw((1, 103))
    s.throw((60, -20))
    s.events = []
    for _ in range(15):
        s.run(1, person(300))                # hand/persoon aan het bord
    s.darts = []                             # pijlen eruit
    for _ in range(10):
        s.run(1, person(320))
    s.run(40)
    k = s.kinds()
    assert "throw" not in k, k
    cleared = [e for e in s.events if e.kind == "board_cleared"]
    assert len(cleared) == 1 and cleared[0].data["darts_seen"] == 2, k


def test_slow_shadow_and_sudden_light_no_score():
    s = Sim()
    s.run(20)
    s.events = []
    for step in range(40):                   # wolk/schaduw schuift traag over het bord
        s.run(1, lambda im, st=step: cv2.subtract(im, (st, st, st, 0), dst=im, mask=_half_mask()))
    s.base = cv2.subtract(s.base, (40, 40, 40, 0))
    s.run(40)                                # plotse lichtwissel (lamp uit)
    assert "throw" not in s.kinds(), s.kinds()


def _half_mask():
    m = np.zeros((H, W), np.uint8)
    m[:, : W // 2] = 255
    return m


def test_small_blob_is_ghost():
    s = Sim()
    s.run(20)
    s.events = []
    tx, ty = mm_to_img(40, 40)
    s.run(2, lambda im: cv2.circle(im, (int(tx) - 30, int(ty)), 4, (0, 0, 0), -1))   # vlieg
    fly = lambda im: cv2.circle(im, (int(tx), int(ty)), 4, (0, 0, 0), -1)
    s.run(20, fly)
    k = s.kinds()
    assert "throw" not in k, (k, s.sm.last_metrics)


def test_cooldown_blocks_double_trigger():
    cfg = Config(cooldown_s=2.0)
    s = Sim(cfg)
    s.run(20)
    s.throw((1, 103))
    s.throw((60, -20))                       # < 2 s later
    k = s.kinds()
    assert k.count("throw") == 1 and "ghost" in k, k
    ghost = [e for e in s.events if e.kind == "ghost"][0]
    assert any("binnen cooldown" in r for r in ghost.data["reasons"])


def test_run_review_export_pipeline():
    """Video → run.py → review-beslissingen → YOLO-export → statistiek."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        s = Sim()
        s.run(20)
        s.throw((1, 103))
        s.throw((60, -20))
        s.run(2, lambda im: None)
        tx, ty = mm_to_img(-40, 60)
        s.run(20, lambda im: cv2.circle(im, (int(tx), int(ty)), 5, (0, 0, 0), -1))
        video = tmp / "sessie.avi"
        vw = cv2.VideoWriter(str(video), cv2.VideoWriter_fourcc(*"MJPG"), FPS, (W, H))
        for f in s.frames:
            vw.write(f)
        vw.release()
        sess = tmp / "sessie"
        sess.mkdir()
        calibration().save(sess / "calibration.json")
        out = subprocess.run([sys.executable, str(ROOT / "run.py"), "--source", str(video), "--session", str(sess),
                              "--no-display"], capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        assert "WORP T20" in out.stdout and f"WORP {score_point(60, -20).label}" in out.stdout, out.stdout

        sys.path.insert(0, str(ROOT))
        from review import Session
        rs = Session(sess)
        throws = [f for f in rs.items if f.name.endswith("_throw")]
        ghosts = [f for f in rs.items if f.name.endswith("_ghost")]
        assert len(throws) == 2, [f.name for f in rs.items]
        rs.decide(throws[0], "correct")
        # tweede worp was eigenlijk T17: gebruiker klikt de juiste plek
        p = mm_to_img(*[103 * math.cos(math.radians(-72)), 103 * math.sin(math.radians(-72))])
        meta = rs.decide(throws[1], "wrong", tip_img=p)
        assert meta["review"]["label"] == "T17"
        typed = rs.decide(throws[1], "wrong", label="D10")          # of: score typen
        assert typed["review"]["label"] == "D10" and typed["review"]["approximate"]
        rs.decide(throws[1], "wrong", tip_img=p)
        for g in ghosts:
            rs.decide(g, "correct_reject")

        counts = rs.export(tmp / "dataset")
        assert counts["confirmed"] == 1 and counts["misclassifications"] == 1, counts
        lbl = [l for l in next((tmp / "dataset" / "misclassifications" / "labels").iterdir()).read_text().split("\n") if l]
        darts = [l for l in lbl if l.startswith("4 ")]
        assert len(darts) == 2, lbl                  # eerdere pijl (T20) + gecorrigeerde (T17)
        assert sum(1 for l in lbl if l.split()[0] in ("0", "1", "2", "3", "5", "6")) == 6, "6 kalibratiepunten in beeld"
        yaml = (tmp / "dataset" / "data.yaml").read_text()
        assert "misclassifications/images" in yaml and "dart" in yaml
        st = rs.stats()
        assert st["score_juist"].startswith("1/2"), st


class _StubDetector:
    """Doet alsof YOLO de echte pijlpunt ziet (met kleine ruis), en telt hoe groot de patches zijn."""
    def __init__(self, sim, jitter=1.0, wild=False):
        self.sim, self.jitter, self.wild, self.patch_sizes = sim, jitter, wild, []
        self.rng = np.random.default_rng(1)

    def detect(self, bgr, imgsz=None, iou=0.65):
        from dartvision.detector import Detection
        self.patch_sizes.append(bgr.shape[:2])
        sm = self.sim.sm
        x0, y0 = self._origin
        out = []
        for d in self.sim.darts:
            ix, iy = mm_to_img(*d)                                    # volledig beeld
            k = sm.cfg.yolo_width / sm.roi[2]                          # beeld → yolo-bord
            px, py = (ix - sm.roi[0]) * k - x0, (iy - sm.roi[1]) * k - y0
            if self.wild:                                              # hand/schaduw: springt rond
                px += self.rng.uniform(-30, 30); py += self.rng.uniform(-30, 30)
            else:
                px += self.rng.uniform(-self.jitter, self.jitter); py += self.rng.uniform(-self.jitter, self.jitter)
            if 0 <= px < bgr.shape[1] and 0 <= py < bgr.shape[0]:
                out.append(Detection("dart", px, py, 0.8))
        return out


def _attach_stub(s, **kw):
    """Koppel de stub en laat hem de patch-oorsprong kennen (zoals de echte pipeline die doorgeeft)."""
    stub = _StubDetector(s, **kw)
    orig = s.sm._yolo_patch
    def patched(crop, bbox):
        patch, origin, a2y = orig(crop, bbox)
        stub._origin = origin
        return patch, origin, a2y
    s.sm._yolo_patch = patched
    s.sm.detector = stub
    return stub


def test_every_rejection_is_logged(caplog=None):
    """Probleem 1: geen stille afkapping — elke kandidaat eindigt met een gelogde beslissing."""
    import logging
    records = []
    h = logging.Handler(); h.emit = lambda r: records.append(r.getMessage())
    lg = logging.getLogger("dartvision"); lg.addHandler(h); lg.setLevel(logging.DEBUG)
    try:
        s = Sim(); s.run(20)
        tx, ty = mm_to_img(40, 40)
        s.run(2, lambda im: cv2.circle(im, (int(tx) - 30, int(ty)), 4, (0, 0, 0), -1))
        s.run(20, lambda im: cv2.circle(im, (int(tx), int(ty)), 4, (0, 0, 0), -1))      # vlieg
        s.throw((1, 103))
    finally:
        lg.removeHandler(h)
    steps = {tag for m in records for tag in ("[S1 BEWEGING]", "[S2 STABIEL]", "[S3 VERSCHIL]", "[S4 CONTROLE]",
                                              "[S5 YOLO]", "[S6 KALIBRATIE]", "[S7 SCORE]", "[BASELINE]") if tag in m}
    assert len(steps) == 8, steps
    assert any("✗ GHOST" in m for m in records) and any("🎯 T20" in m for m in records), records[-6:]
    ghost = [e for e in s.events if e.kind == "ghost"][0]
    assert ghost.data["trace"] and ghost.data["reasons"], "reden + spoor in het event (ook voor review.py)"


def test_hard_shadow_is_rejected():
    """Probleem 2: harde, langwerpige schaduw (zelfde kleur, donkerder) → twijfel → YOLO ziet geen pijl → ghost."""
    s = Sim(); s.run(20)
    _attach_stub(s)                                  # model ziet enkel echte pijlen (hier: geen)
    s.events = []
    tx, ty = mm_to_img(-50, 40)
    def shadow(im):
        m = np.zeros(im.shape[:2], np.uint8)
        cv2.line(m, (int(tx), int(ty)), (int(tx) + 10, int(ty) - 75), 255, 6)    # schaduw van een schacht
        im[m > 0] = (im[m > 0] * 0.55).astype(np.uint8)
    s.run(2, lambda im: cv2.line(im, (int(tx) - 90, int(ty)), (int(tx) - 60, int(ty) - 20), (240, 240, 240), 3))
    s.run(20, shadow)
    k = s.kinds()
    assert "throw" not in k, (k, s.sm.last_metrics)
    g = [e for e in s.events if e.kind == "ghost"]
    assert g and any("schaduw" in r for r in g[0].data["reasons"]), g[0].data if g else k


def test_soft_shadow_rejected_without_model():
    """Zachte schaduw (vage rand) wordt ook zonder model afgekeurd."""
    s = Sim(); s.run(20)
    s.events = []
    tx, ty = mm_to_img(-50, 40)
    def soft(im):
        m = np.zeros(im.shape[:2], np.float32)
        cv2.line(m, (int(tx), int(ty)), (int(tx) + 10, int(ty) - 75), 1.0, 9)
        m = cv2.GaussianBlur(m, (31, 31), 0)[..., None]
        im[:] = (im * (1 - 0.5 * m)).astype(np.uint8)
    s.run(2, lambda im: cv2.line(im, (int(tx) - 90, int(ty)), (int(tx) - 60, int(ty) - 20), (240, 240, 240), 3))
    s.run(20, soft)
    assert "throw" not in s.kinds(), (s.kinds(), s.sm.last_metrics)


def test_dark_dart_on_cream_is_not_a_shadow():
    """Een donkergrijze pijl (zelfde tint als het vak, maar scherp) moet gewoon tellen."""
    s = Sim(); s.run(20)
    tip = (-60, -40)                                   # crèmekleurig vak (16)
    tx, ty = mm_to_img(*tip)
    def dark_dart(im):
        cv2.line(im, (int(tx), int(ty)), (int(tx) + 6, int(ty) - 70), (70, 85, 95), 3, cv2.LINE_AA)
        cv2.rectangle(im, (int(tx) - 1, int(ty) - 92), (int(tx) + 13, int(ty) - 70), (60, 70, 80), -1)
    tx0 = int(tx) - 120
    s.run(2, lambda im: cv2.line(im, (tx0, int(ty) - 40), (tx0 + 40, int(ty) - 50), (240, 240, 240), 3))
    s.run(25, dark_dart)
    throws = [e for e in s.events if e.kind == "throw"]
    assert len(throws) == 1, (s.kinds(), s.sm.last_metrics)
    assert math.dist(throws[0].data["tip_mm"], tip) < 8, throws[0].data

    # Met model: YOLO ziet de pijl → ook goedgekeurd
    s2 = Sim(); s2.run(20)
    _attach_stub(s2)
    s2.darts.append(tip)                              # stub "ziet" deze pijl
    s2.run(2, lambda im: cv2.line(im, (tx0, int(ty) - 40), (tx0 + 40, int(ty) - 50), (240, 240, 240), 3))
    s2.run(25, dark_dart)
    t2 = [e for e in s2.events if e.kind == "throw"]
    assert len(t2) == 1 and t2[0].data["source"] == "yolo", s2.kinds()


def test_second_dart_next_to_first():
    """Probleem 3: baseline correct bijgewerkt → pijl 2 vlak naast pijl 1 wordt apart herkend."""
    s = Sim(Config(cooldown_s=0.3)); s.run(20)
    s.throw((1, 103))
    s.throw((10, 101))                         # 9 mm ernaast, zelfde T20
    throws = [e for e in s.events if e.kind == "throw"]
    assert len(throws) == 2, s.kinds()
    assert all(t.data["label"] == "T20" for t in throws), [t.data["label"] for t in throws]
    assert math.dist(throws[1].data["tip_mm"], (10, 101)) < 6, throws[1].data["tip_mm"]


def test_yolo_on_roi_patch_with_consensus():
    """Probleem 4: YOLO draait op een kleine patch rond de vlek, en pas na 3× binnen 5 px telt het."""
    s = Sim(); s.run(20)
    stub = _attach_stub(s, jitter=1.0)
    s.throw((25, -100))
    t = [e for e in s.events if e.kind == "throw"][0]
    assert t.data["source"] == "yolo", t.data
    assert t.data["label"] == "T17" and math.dist(t.data["tip_mm"], (25, -100)) < 2, t.data
    assert len(stub.patch_sizes) == 3, stub.patch_sizes                      # 3 beelden = consensus
    h, w = stub.patch_sizes[0]
    assert w % 32 == 0 and w <= 320, (h, w)                                  # klein, i.p.v. hele bord (800)

    s2 = Sim(); s2.run(20)
    _attach_stub(s2, wild=True)                                              # springt rond → geen consensus
    s2.throw((1, 103))
    t2 = [e for e in s2.events if e.kind == "throw"][0]
    assert "geen YOLO-consensus" in t2.data["source"], t2.data


def test_debug_visuals_saved():
    with tempfile.TemporaryDirectory() as tmp:
        s = Sim(Config(debug_dir=tmp)); s.run(20)
        _attach_stub(s)
        s.throw((1, 103))
        files = {p.name for p in Path(tmp).rglob("*.png")}
        assert {"diff.png", "shadow.png", "new_edges.png", "patch.png"} <= files, files


def test_tripod_shake_ignored():
    s = Sim(); s.run(20)
    s.events = []
    for i in range(30):
        dx, dy = [2, -1, 1, -2, 0][i % 5], [1, 0, -2, 1, -1][i % 5]
        M = np.float32([[1, 0, dx], [0, 1, dy]])
        s.t += 1 / FPS
        img = cv2.warpAffine(s.frame(), M, (W, H), borderMode=cv2.BORDER_REPLICATE)
        s.events += s.sm.process(img, s.t)
    s.run(30)
    assert s.kinds() == [] or set(s.kinds()) <= {"ghost"}, s.kinds()
    assert "player_at_board" not in s.kinds() and "throw" not in s.kinds()


def test_hard_negatives_and_augment():
    """Persoon loopt voorbij met 1 pijl in het bord → negatieven met die pijl gelabeld; augment.py werkt."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        s = Sim()
        s.run(20)
        s.throw((1, 103))
        for x in range(-260, 900, 40):
            s.run(1, person(x))
        s.run(30)
        video = tmp / "v.avi"
        vw = cv2.VideoWriter(str(video), cv2.VideoWriter_fourcc(*"MJPG"), FPS, (W, H))
        for f in s.frames:
            vw.write(f)
        vw.release()
        sess = tmp / "s"
        sess.mkdir()
        calibration().save(sess / "calibration.json")
        out = subprocess.run([sys.executable, str(ROOT / "run.py"), "--source", str(video), "--session", str(sess),
                              "--no-display", "--hard-negatives", "3"], capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        imgs = sorted((sess / "hard_negatives" / "images").glob("*.jpg"))
        assert len(imgs) >= 5, out.stdout
        # Laatste negatief: na de worp → de pijl in het bord moet gelabeld zijn
        lbl = (sess / "hard_negatives" / "labels" / f"{imgs[-1].stem}.txt").read_text().split()
        assert lbl.count("4") >= 1 or any(l.startswith("4 ") for l in lbl), lbl

        from review import Session
        counts = Session(sess).export(tmp / "ds")
        assert counts["hard_negatives"] == len(imgs), counts
        neg = tmp / "neg"
        neg.mkdir()
        cv2.imwrite(str(neg / "hand.jpg"), s.frames[30])
        out = subprocess.run([sys.executable, str(ROOT / "augment.py"), "--src", str(tmp / "ds"), "--dst", str(tmp / "aug"),
                              "--copies", "2", "--negatives", str(neg)], capture_output=True, text=True)
        assert out.returncode == 0, out.stderr
        aug_imgs = list((tmp / "aug").rglob("*.jpg"))
        assert len(aug_imgs) == len(imgs) * 3 + 3, (len(aug_imgs), out.stdout)
        assert (tmp / "aug" / "background" / "labels" / "bg_hand_0.txt").read_text() == ""
        assert "background/images" in (tmp / "aug" / "data.yaml").read_text()


if __name__ == "__main__":
    tests = [v for k, v in dict(globals()).items() if k.startswith("test_")]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"✓ {t.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"✗ {t.__name__}: {e}")
    print(f"\n{len(tests) - failed}/{len(tests)} geslaagd")
    sys.exit(1 if failed else 0)
