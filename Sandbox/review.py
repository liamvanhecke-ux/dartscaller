"""Worp per worp controleren en er trainingsdata van maken.

    python review.py sessions/test1                 # beoordelen (venster)
    python review.py sessions/test1 --stats         # nauwkeurigheid + drempeladvies
    python review.py sessions/test1 --export dataset   # YOLO-dataset maken/aanvullen

Toetsen bij een gedetecteerde WORP:          Toetsen bij een genegeerde GHOST:
  j  = juist (echte worp, juiste score)        j  = terecht genegeerd
  f  = fout: klik de echte punt aan             w  = was tóch een worp: klik de punt aan
  t  = fout: typ de juiste score (T20, D16…)    t  = was tóch een worp: typ de score
  g  = geen worp (ghost / vals alarm)
Altijd:  ← / b = vorige   → / s = overslaan   q = stoppen   (na klikken: Enter = bevestigen, Esc = annuleren)
"""
from __future__ import annotations

import argparse
import json
import shutil
import statistics
import sys
from collections import Counter
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from dartvision.geometry import (CAL_ANGLES, CLASS_NAMES, DART_CLASS, BoardCalibration,   # noqa: E402
                                 cal_point_mm, nearest_point_in, parse_label, score_point)

REAL = {"correct", "wrong", "missed"}          # uitkomsten die een echte pijl betekenen
BOX = 0.025                                    # grootte keypoint-vakje (zelfde als het app-model)


# ======================================================================= opslag / logica
class Session:
    def __init__(self, path: str | Path):
        self.dir = Path(path)
        info = json.loads((self.dir / "session.json").read_text())
        c = info["calibration"]
        self.cal = BoardCalibration({k: tuple(v) for k, v in c["image_points"].items()}, tuple(c["image_size"]))
        self.items = sorted(p for p in (self.dir / "throws").iterdir() if (p / "meta.json").exists())

    @staticmethod
    def meta(folder: Path) -> dict:
        return json.loads((folder / "meta.json").read_text())

    @staticmethod
    def save_meta(folder: Path, meta: dict) -> None:
        (folder / "meta.json").write_text(json.dumps(meta, indent=2))

    def decide(self, folder: Path, verdict: str, tip_img: tuple[float, float] | None = None,
               label: str | None = None) -> dict:
        """Beoordeling opslaan. verdict: correct | wrong | ghost | correct_reject | missed | skip."""
        meta = self.meta(folder)
        review: dict = {"verdict": verdict}
        if verdict in ("wrong", "missed"):
            if tip_img is None and label:
                # Alleen een score getypt: dichtste punt in dat vak t.o.v. de voorspelling/het blob-midden
                hit = parse_label(label)
                if hit is None:
                    raise ValueError(f"Onbekende score: {label}")
                guess = meta.get("tip_mm") or [0.0, 0.0]
                mx, my = nearest_point_in(hit, *guess)
                tip_img = tuple(self.cal.to_img([(mx, my)])[0])
                review["approximate"] = True
            if tip_img is None:
                raise ValueError("Positie of score nodig")
            hit = self.cal.score_image_point(*tip_img)
            review.update(tip_img=[round(float(tip_img[0]), 1), round(float(tip_img[1]), 1)],
                          label=hit.label, score=hit.score)
        meta["review"] = review
        self.save_meta(folder, meta)
        return meta

    def final_tip(self, meta: dict) -> tuple[float, float] | None:
        """Echte positie van deze pijl (na review), of None als het geen echte pijl was."""
        r = meta.get("review") or {}
        v = r.get("verdict")
        if v in ("wrong", "missed"):
            return tuple(r["tip_img"])
        if v == "correct" or (v is None and meta["kind"] == "throw"):
            return tuple(meta["tip_img"])
        return None

    # --------------------------------------------------------------- export
    def export(self, out: str | Path, include_unreviewed: bool = False) -> Counter:
        """YOLO-dataset: confirmed/, misclassifications/, false_positives/, missed/ (+ data.yaml)."""
        out = Path(out)
        folders = {"correct": "confirmed", "wrong": "misclassifications",
                   "ghost": "false_positives", "missed": "missed"}
        counts: Counter = Counter()
        board: dict[int, list[tuple[float, float]]] = {}      # beurt → echte pijlen tot nu toe
        for f in self.items:
            meta = self.meta(f)
            verdict = (meta.get("review") or {}).get("verdict")
            if verdict is None and include_unreviewed and meta["kind"] == "throw":
                verdict = "correct"
            turn = meta.get("turn", 0)
            earlier = list(board.get(turn, []))
            tip = self.final_tip(meta)
            if tip is not None:
                board.setdefault(turn, []).append(tip)
            if verdict not in folders:
                continue
            darts = earlier + ([tip] if verdict in REAL and tip is not None else [])
            lines = self._label_lines(meta["roi"], darts)
            sub = out / folders[verdict]
            (sub / "images").mkdir(parents=True, exist_ok=True)
            (sub / "labels").mkdir(parents=True, exist_ok=True)
            name = f"{self.dir.name}_{f.name}"
            shutil.copy(f / "after.jpg", sub / "images" / f"{name}.jpg")
            (sub / "labels" / f"{name}.txt").write_text("\n".join(lines) + "\n")
            counts[folders[verdict]] += 1
        self._write_yaml(out)
        return counts

    def _label_lines(self, roi, darts_img) -> list[str]:
        x0, y0, w, h = roi

        def norm(p):
            nx, ny = (p[0] - x0) / w, (p[1] - y0) / h
            return (nx, ny) if 0 <= nx <= 1 and 0 <= ny <= 1 else None

        lines = []
        for cls, name in enumerate(CLASS_NAMES):
            if name in CAL_ANGLES:
                p = norm(self.cal.to_img([cal_point_mm(name)])[0])
                if p:
                    lines.append(f"{cls} {p[0]:.6f} {p[1]:.6f} {BOX:.6f} {BOX:.6f}")
        for d in darts_img:
            p = norm(d)
            if p:
                lines.append(f"{DART_CLASS} {p[0]:.6f} {p[1]:.6f} {BOX:.6f} {BOX:.6f}")
        return lines

    @staticmethod
    def _write_yaml(out: Path) -> None:
        dirs = [f"{d}/images" for d in ("confirmed", "misclassifications", "false_positives", "missed")
                if (out / d / "images").exists()]
        text = "# Gemaakt met review.py — train met: python ../Training/train.py --data <deze map>/data.yaml\n"
        text += f"path: {out.resolve().as_posix()}\ntrain:\n" + "".join(f"  - {d}\n" for d in dirs)
        text += "val:\n" + "".join(f"  - {d}\n" for d in dirs) + "names:\n"
        text += "".join(f"  {i}: '{n}'\n" for i, n in enumerate(CLASS_NAMES))
        (out / "data.yaml").write_text(text)

    # --------------------------------------------------------------- statistiek
    def stats(self) -> dict:
        metas = [self.meta(f) for f in self.items]
        v = Counter((m.get("review") or {}).get("verdict", "niet beoordeeld") for m in metas)
        detected_real = v["correct"] + v["wrong"]
        res = {
            "beoordeeld": sum(n for k, n in v.items() if k != "niet beoordeeld"),
            "uitkomsten": dict(v),
            "precisie_detectie": _ratio(detected_real, detected_real + v["ghost"]),
            "recall_detectie": _ratio(detected_real, detected_real + v["missed"]),
            "score_juist": _ratio(v["correct"], detected_real),
            "ghost_redenen": dict(Counter(r for m in metas if m["kind"] == "ghost" for r in m.get("reasons", []))),
        }
        # Drempeladvies: vergelijk metingen van echte worpen met valse alarmen
        real = [m["metrics"] for m in metas if (m.get("review") or {}).get("verdict") in REAL and "elongation" in m.get("metrics", {})]
        fake = [m["metrics"] for m in metas if (m.get("review") or {}).get("verdict") in ("ghost", "correct_reject")
                and "elongation" in m.get("metrics", {})]
        advice = {}
        for key, cfg_name in (("elongation", "min_elongation"), ("contrast", "min_contrast"), ("area_frac", "min_dart_area_frac")):
            r = sorted(m[key] for m in real)
            f_ = sorted(m[key] for m in fake)
            if len(r) >= 3 and len(f_) >= 3:
                low_real = r[max(0, int(len(r) * 0.1) - 1)]          # 10% laagste echte worpen
                high_fake = f_[min(len(f_) - 1, int(len(f_) * 0.9))]  # 90% van de valse
                advice[cfg_name] = {
                    "echt_mediaan": round(statistics.median(r), 4), "vals_mediaan": round(statistics.median(f_), 4),
                    "voorstel": round((low_real + high_fake) / 2, 4) if low_real > high_fake else None,
                    "scheidbaar": low_real > high_fake,
                }
        res["drempeladvies"] = advice
        return res


def _ratio(a: int, b: int) -> str:
    return f"{a}/{b} ({100 * a / b:.0f}%)" if b else "–"


# ======================================================================= venster
class ReviewUI:
    H = 460

    def __init__(self, session: Session):
        self.s = session
        self.click: tuple[float, float] | None = None
        self.panel_scale = 1.0
        self.after_x0 = 0

    def run(self) -> None:
        items = self.s.items
        if not items:
            print("Geen worpen in deze sessie.")
            return
        i = next((k for k, f in enumerate(items) if Session.meta(f).get("review") is None), 0)
        cv2.namedWindow("Review")
        cv2.setMouseCallback("Review", self._on_mouse)
        while 0 <= i < len(items):
            folder = items[i]
            meta = Session.meta(folder)
            self.click = None
            action = self._ask(folder, meta, i, len(items))
            if action == "quit":
                break
            if action == "back":
                i = max(0, i - 1)
                continue
            i += 1
        cv2.destroyAllWindows()
        print(json.dumps(self.s.stats(), indent=2, ensure_ascii=False))

    def _on_mouse(self, event, x, y, *_):
        if event == cv2.EVENT_LBUTTONDOWN and self.after_x0 <= x < self.after_x0 + self._aw:
            self.click = ((x - self.after_x0) / self.panel_scale, y / self.panel_scale)   # crop-pixels

    def _render(self, folder: Path, meta: dict, header: str, footer: str) -> np.ndarray:
        before = cv2.imread(str(folder / "before.jpg"))
        after = cv2.imread(str(folder / "after.jpg"))
        diff = cv2.imread(str(folder / "diff.png"))
        s = self.H / after.shape[0]
        self.panel_scale = s
        x0, y0 = meta["roi"][:2]
        a = cv2.resize(after, None, fx=s, fy=s)
        self.s.cal.draw(a, (0, 200, 255), offset=(x0, y0), scale=s)
        if meta.get("tip_img"):
            p = (int((meta["tip_img"][0] - x0) * s), int((meta["tip_img"][1] - y0) * s))
            cv2.drawMarker(a, p, (0, 0, 255), cv2.MARKER_CROSS, 22, 2)
        r = meta.get("review") or {}
        if r.get("tip_img"):
            p = (int((r["tip_img"][0] - x0) * s), int((r["tip_img"][1] - y0) * s))
            cv2.drawMarker(a, p, (0, 255, 0), cv2.MARKER_TILTED_CROSS, 22, 2)
        if self.click:
            p = (int(self.click[0] * s), int(self.click[1] * s))
            cv2.drawMarker(a, p, (0, 255, 0), cv2.MARKER_TILTED_CROSS, 26, 2)
        b = cv2.resize(before, (a.shape[1], a.shape[0]))
        d = cv2.resize(diff, (a.shape[1], a.shape[0])) if diff is not None else np.zeros_like(a)
        self.after_x0, self._aw = b.shape[1], a.shape[1]
        img = np.hstack([b, a, d])
        bar = np.zeros((70, img.shape[1], 3), np.uint8)
        cv2.putText(bar, header, (10, 28), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (255, 255, 255), 2)
        cv2.putText(bar, footer, (10, 58), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (180, 220, 255), 1)
        for k, name in enumerate(("VOOR", "NA (klik hier)", "VERSCHIL")):
            cv2.putText(img, name, (10 + k * a.shape[1], 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
        return np.vstack([bar, img])

    def _ask(self, folder: Path, meta: dict, i: int, n: int) -> str:
        is_throw = meta["kind"] == "throw"
        done = (meta.get("review") or {}).get("verdict")
        what = f"WORP  voorspeld: {meta['label']} ({meta['score']}) via {meta.get('source')}" if is_throw else \
               "GHOST genegeerd: " + ", ".join(meta.get("reasons", []))
        header = f"[{i + 1}/{n}] {what}" + (f"   (al beoordeeld: {done})" if done else "")
        keys = "j=juist  f=fout(klik)  t=fout(typ)  g=geen worp" if is_throw else \
               "j=terecht genegeerd  w=was worp(klik)  t=was worp(typ)"
        footer = keys + "   b=vorige  s=overslaan  q=stop"
        mode = None
        while True:
            foot = footer
            if mode:
                if self.click:
                    x0, y0 = meta["roi"][:2]
                    hit = self.s.cal.score_image_point(self.click[0] + x0, self.click[1] + y0)
                    foot = f"Aangeklikt: {hit.label} ({hit.score})   Enter=bevestigen  Esc=annuleren"
                else:
                    foot = "Klik de PUNT van de pijl aan in het middelste beeld   Esc=annuleren"
            cv2.imshow("Review", self._render(folder, meta, header, foot))
            k = cv2.waitKeyEx(30)
            if k == -1:
                continue
            c = k & 0xFF
            if mode:
                if c == 27:
                    mode, self.click = None, None
                elif c in (13, 10) and self.click:
                    x0, y0 = meta["roi"][:2]
                    self.s.decide(folder, mode, tip_img=(self.click[0] + x0, self.click[1] + y0))
                    return "next"
                continue
            if c == ord("q"):
                return "quit"
            if c == ord("b") or k in (2424832, 65361):
                return "back"
            if c == ord("s") or k in (2555904, 65363):
                self.s.decide(folder, "skip") if done is None else None
                return "next"
            if c == ord("j"):
                self.s.decide(folder, "correct" if is_throw else "correct_reject")
                return "next"
            if is_throw and c == ord("g"):
                self.s.decide(folder, "ghost")
                return "next"
            if c == ord("f") and is_throw or c == ord("w") and not is_throw:
                mode = "wrong" if is_throw else "missed"
            if c == ord("t"):
                txt = input("Juiste score (bv. T20, D16, S5, 25, BULL, MIS): ")
                try:
                    self.s.decide(folder, "wrong" if is_throw else "missed", label=txt)
                    return "next"
                except ValueError as e:
                    print(e)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("--stats", action="store_true")
    ap.add_argument("--export", metavar="MAP", help="YOLO-dataset aanmaken/aanvullen")
    ap.add_argument("--include-unreviewed", action="store_true",
                    help="niet-beoordeelde worpen als juist meenemen (pseudo-labels)")
    args = ap.parse_args()
    s = Session(args.session)
    if args.stats:
        print(json.dumps(s.stats(), indent=2, ensure_ascii=False))
    elif args.export:
        counts = s.export(args.export, args.include_unreviewed)
        print(f"Geëxporteerd naar {args.export}: {dict(counts)}")
        print(f"Trainen:  python ../Training/train.py --data {args.export}/data.yaml --epochs 30")
    else:
        ReviewUI(s).run()


if __name__ == "__main__":
    main()
