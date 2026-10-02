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
    assert "binnen cooldown" in ghost.data["reasons"]


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
