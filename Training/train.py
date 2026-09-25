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
    model.train(data=args.data, epochs=args.epochs, imgsz=args.imgsz,
                fliplr=0.0,        # NIET spiegelen: dan wisselen de kalibratiepunten van plaats
                degrees=10.0,      # licht roteren mag (camera iets scheef)
                mosaic=0.5)
    model = YOLO(model.trainer.best)

# nms=True is verplicht: dan geeft iOS Vision kant-en-klare VNRecognizedObjectObservation terug.
path = model.export(format="coreml", nms=True, imgsz=args.imgsz)
print("Hernoem", path, "naar DartsYOLO.mlpackage en sleep het in Xcode.")
