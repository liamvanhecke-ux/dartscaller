"""Train YOLOv8 en exporteer naar Core ML voor de iOS-app.

    python train.py                              # verder trainen vanaf het meegeleverde model (aanrader)
    python train.py --model yolov8n.pt           # van nul trainen
    python train.py --export best.pt             # alleen exporteren (Mac, Linux of Colab)
    python train.py --data DartsCaller-dataset/data.yaml --epochs 30
                                                 # verder trainen op de foto's die de app tijdens het spelen verzamelde

Het meegeleverde startmodel (dartsense.pt) komt van github.com/bnww/dart-sense (CC BY-NC 4.0).
"""
import argparse
from ultralytics import YOLO

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="dartsense.pt", help="dartsense.pt (verder trainen) of yolov8n.pt (van nul)")
ap.add_argument("--epochs", type=int, default=100)
ap.add_argument("--imgsz", type=int, default=800)
ap.add_argument("--data", default="darts.yaml", help="dataset-yaml (bv. data.yaml uit de export van de app)")
ap.add_argument("--export", help="pad naar een getraind .pt-bestand: sla training over")
args = ap.parse_args()

if args.export:
    model = YOLO(args.export)
else:
    model = YOLO(args.model)
    model.train(
        data=args.data, epochs=args.epochs, imgsz=args.imgsz,
        # ── Geometrie ──────────────────────────────────────────────────────────
        fliplr=0.0, flipud=0.0,   # NOOIT spiegelen: kalibratieklassen (20, 3, 11, 6) wisselen dan van plaats
        degrees=8.0,              # statief iets scheef
        translate=0.08,           # bord niet altijd exact gecentreerd
        scale=0.25,               # afstand tot het bord varieert
        shear=2.0,
        perspective=0.0005,       # andere camerahoek (klein houden: de homografie doet de rest)
        # ── Kleur / licht (garage, tuin, TL, led) ──────────────────────────────
        hsv_h=0.01,               # rood/groen moet rood/groen blijven
        hsv_s=0.5,
        hsv_v=0.45,
        # ── Mosaic & co ────────────────────────────────────────────────────────
        mosaic=1.0,               # leert pijlen in elke positie/schaal
        close_mosaic=10,          # laatste 10 epochs zonder mosaic: realistische volledige borden
        mixup=0.05,               # een beetje: overlappende pijlen/schaduwen
        # Motion blur, ruis, JPEG en lampkleur: offline met Sandbox/augment.py (Ultralytics doet die amper)
        # ── Kleine, dicht opeengepakte objecten ────────────────────────────────
        box=7.5, dfl=1.5,         # standaard; keypoint-vakjes zijn klein en precies
        patience=30,
    )
    # Valideren met dezelfde NMS als in de app (DartDetector.Thresholds)
    YOLO(model.trainer.best).val(data=args.data, imgsz=args.imgsz, conf=0.20, iou=0.65)
    model = YOLO(model.trainer.best)

# nms=True is verplicht: dan geeft iOS Vision kant-en-klare VNRecognizedObjectObservation terug.
# conf/iou zijn standaardwaarden; de app zet ze zelf (DartDetector.Thresholds: 0.20 / 0.65).
path = model.export(format="coreml", nms=True, imgsz=args.imgsz, conf=0.20, iou=0.65)
print("Hernoem", path, "naar DartsYOLO.mlpackage en sleep het in Xcode.")
