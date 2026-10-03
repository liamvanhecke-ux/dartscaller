"""Test-sessie draaien op een video-opname of live camera.

    python run.py --source opname.mp4 --session sessions/test1
    python run.py --source 0 --session sessions/live            (webcam)
    python run.py --source opname.mp4 --session sessions/test1 --model ../Training/dartsense.pt

Toetsen in het venster:  spatie = pauze   r = leeg bord opnieuw vastleggen   n = nieuwe beurt   q = stoppen
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from dartvision.geometry import MANUAL_ORDER, BoardCalibration          # noqa: E402
from dartvision.logger import HardNegativeSaver, SessionLogger          # noqa: E402
from dartvision.state_machine import Config, State, ThrowStateMachine   # noqa: E402

STATE_COLORS = {State.NEEDS_BASELINE: (160, 160, 160), State.IDLE: (80, 200, 80), State.MOTION: (0, 200, 255),
                State.IMPACT: (0, 140, 255), State.CONFIRM: (255, 200, 0), State.OBSTRUCTED: (60, 60, 230),
                State.COOLDOWN: (200, 160, 60)}


def open_source(src: str) -> cv2.VideoCapture:
    cap = cv2.VideoCapture(int(src) if src.isdigit() else src)
    if not cap.isOpened():
        sys.exit(f"Kan bron niet openen: {src}")
    return cap


def manual_calibration(frame: np.ndarray) -> dict[str, tuple[float, float]]:
    """Klik de 4 punten op de buitenrand van de double-ring (zelfde als in de app)."""
    points: dict[str, tuple[float, float]] = {}
    scale = min(1.0, 1200 / max(frame.shape[:2]))
    view = cv2.resize(frame, None, fx=scale, fy=scale)

    def on_click(event, x, y, *_):
        if event == cv2.EVENT_LBUTTONDOWN and len(points) < 4:
            points[MANUAL_ORDER[len(points)][0]] = (x / scale, y / scale)

    cv2.namedWindow("Kalibratie")
    cv2.setMouseCallback("Kalibratie", on_click)
    while len(points) < 4:
        img = view.copy()
        for (label, _), p in zip(MANUAL_ORDER, points.values()):
            cv2.circle(img, (int(p[0] * scale), int(p[1] * scale)), 6, (0, 255, 255), 2)
        hint = MANUAL_ORDER[len(points)][1]
        cv2.putText(img, f"Klik {len(points) + 1}/4: buitenrand double-ring, {hint}", (15, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 255), 2)
        cv2.imshow("Kalibratie", img)
        if cv2.waitKey(20) & 0xFF == ord("q"):
            sys.exit("Kalibratie afgebroken")
    cv2.destroyWindow("Kalibratie")
    return points


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True, help="videobestand, camera-index (0) of stream-URL")
    ap.add_argument("--session", required=True, help="map voor deze test-sessie")
    ap.add_argument("--model", help="YOLO-gewichten (.pt), optioneel")
    ap.add_argument("--config", help="JSON met aangepaste drempels (zie Config)")
    ap.add_argument("--calibration", help="bestaand calibration.json hergebruiken")
    ap.add_argument("--no-display", action="store_true", help="zonder venster (sneller)")
    ap.add_argument("--log", default="info", choices=["debug", "info", "warning"],
                    help="debug = elke stap, info = enkel beslissingen (standaard)")
    ap.add_argument("--debug-visuals", action="store_true",
                    help="tussenbeelden (verschil, schaduw, randen, YOLO-patch) opslaan in <sessie>/debug/")
    ap.add_argument("--hard-negatives", type=int, default=0, metavar="N",
                    help="elke N-de frame tijdens beweging/obstructie bewaren als negatief voorbeeld (0 = uit)")
    args = ap.parse_args()

    logging.basicConfig(level=getattr(logging, args.log.upper()), format="%(message)s")
    cap = open_source(args.source)
    ok, first = cap.read()
    if not ok:
        sys.exit("Geen beeld ontvangen")
    h, w = first.shape[:2]
    session = Path(args.session)
    session.mkdir(parents=True, exist_ok=True)

    detector = None
    if args.model:
        from dartvision.detector import DartDetector
        detector = DartDetector(args.model)

    # Kalibratie: bestand → model → handmatig klikken
    cal_file = Path(args.calibration) if args.calibration else session / "calibration.json"
    if cal_file.exists():
        cal = BoardCalibration.load(cal_file)
        print(f"Kalibratie geladen uit {cal_file}")
    else:
        pts = detector.calibration_points(first) if detector else {}
        if len(pts) >= 4:
            print(f"Kalibratie door YOLO: {sorted(pts)}")
        elif args.no_display:
            sys.exit("Geen kalibratie: geef --calibration of draai één keer mét venster")
        else:
            pts = manual_calibration(first)
        cal = BoardCalibration(pts, (w, h))
        cal.save(session / "calibration.json")

    cfg = Config(**json.loads(Path(args.config).read_text())) if args.config else Config()
    if args.debug_visuals:
        cfg.debug_dir = str(session / "debug")
    sm = ThrowStateMachine(cal, cfg, detector)
    logger = SessionLogger(session, cal, cfg, sm.roi, args.source)
    hard_neg = HardNegativeSaver(session, cal, sm.roi, every_n=args.hard_negatives) if args.hard_negatives > 0 else None
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    is_file = not args.source.isdigit() and Path(args.source).exists()
    counts: dict[str, int] = {}
    last_text, frame_no, paused = "", 0, False
    frame = first

    while True:
        if not paused:
            if frame_no > 0:
                ok, frame = cap.read()
                if not ok:
                    break
            frame_no += 1
            t = frame_no / fps if is_file else None      # video: tijd uit framenummer (reproduceerbaar)
            events = sm.process(frame, t)
            if hard_neg and sm.state in (State.MOTION, State.OBSTRUCTED):
                x, y, rw, rh = sm.roi
                hard_neg.offer(frame[y:y + rh, x:x + rw], [d["tip_img"] for d in sm.darts_this_turn], frame_no)
            for ev in events:
                counts[ev.kind] = counts.get(ev.kind, 0) + 1
                folder = logger.log(ev)
                if ev.kind == "throw":
                    last_text = f"WORP {ev.data['label']} ({ev.data['score']}) via {ev.data['source']}"
                elif ev.kind == "ghost":
                    last_text = "GHOST genegeerd: " + ", ".join(ev.data["reasons"])
                else:
                    last_text = ev.kind.upper() + (f"  pijlen gezien: {ev.data['darts_seen']}" if "darts_seen" in ev.data else "")
                print(f"[{frame_no:6d}] {last_text}" + (f"  → {folder}" if folder else ""))

        if not args.no_display:
            view = frame.copy()
            x, y, rw, rh = sm.roi
            cal.draw(view, (0, 200, 255))
            color = STATE_COLORS.get(sm.state, (255, 255, 255))
            cv2.rectangle(view, (x, y), (x + rw, y + rh), color, 2)
            s = min(1.0, 1100 / max(view.shape[:2]))
            view = cv2.resize(view, None, fx=s, fy=s)
            cv2.putText(view, sm.state.value, (15, 35), cv2.FONT_HERSHEY_SIMPLEX, 1.0, color, 2)
            cv2.putText(view, last_text, (15, 70), cv2.FONT_HERSHEY_SIMPLEX, 0.65, (255, 255, 255), 2)
            cv2.imshow("DartsCaller sandbox", view)
            key = cv2.waitKey(1 if not paused else 50) & 0xFF
            if key == ord("q"):
                break
            if key == ord(" "):
                paused = not paused
            if key == ord("r"):
                sm.reset_baseline()
            if key == ord("n"):
                sm.new_turn()

    cap.release()
    if not args.no_display:
        cv2.destroyAllWindows()
    print("\nKlaar. Samenvatting:", counts)
    if hard_neg:
        print(f"Harde negatieven bewaard: {hard_neg.count} (in {session / 'hard_negatives'})")
    print(f"Beoordeel nu:  python review.py {session}")


if __name__ == "__main__":
    main()
