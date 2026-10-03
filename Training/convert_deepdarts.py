"""Zet de DeepDarts-labels (labels.pkl) om naar YOLO-formaat.

DeepDarts slaat per foto een lijst genormaliseerde punten op (kolom 'xy'):
de eerste 4 = kalibratiepunten, de rest = pijlpunten. Elk punt wordt hier een klein vakje.

Gebruik:
    python convert_deepdarts.py --labels pad/naar/labels.pkl --images pad/naar/cropped_images
Controleer daarna de map preview/: 1 = draad 5|20 (boven), 2 = 17|3 (onder), 3 = 8|11 (links), 4 = 13|6 (rechts).
"""
import argparse, random, shutil
from pathlib import Path

import pandas as pd
from PIL import Image, ImageDraw

ap = argparse.ArgumentParser()
ap.add_argument("--labels", required=True)
ap.add_argument("--images", required=True, help="map met de (bijgesneden) DeepDarts-foto's, wordt recursief doorzocht")
ap.add_argument("--out", default="datasets/darts")
ap.add_argument("--box", type=float, default=0.025, help="vakjesgrootte rond elk punt (fractie van de foto)")
ap.add_argument("--val", type=float, default=0.1)
args = ap.parse_args()

df = pd.read_pickle(args.labels)
print("Kolommen:", list(df.columns), "| rijen:", len(df))
index = {p.name: p for p in Path(args.images).rglob("*") if p.suffix.lower() in {".jpg", ".jpeg", ".png"}}

out = Path(args.out)
for split in ("train", "val"):
    (out / "images" / split).mkdir(parents=True, exist_ok=True)
    (out / "labels" / split).mkdir(parents=True, exist_ok=True)
preview = Path("preview"); preview.mkdir(exist_ok=True)

random.seed(42)
done = missing = 0
for i, row in enumerate(df.itertuples()):
    src = index.get(row.img_name)
    if src is None:
        missing += 1
        continue
    split = "val" if random.random() < args.val else "train"
    lines = []
    for k, (x, y) in enumerate(row.xy):
        if not (0 <= x <= 1 and 0 <= y <= 1):      # ontbrekend punt
            continue
        cls = k if k < 4 else 4   # 0..3 = kalibratie (20, 3, 11, 6), 4 = dart
        lines.append(f"{cls} {x:.6f} {y:.6f} {args.box:.6f} {args.box:.6f}")
    name = f"{Path(row.img_folder).name}_{src.stem}"
    shutil.copy(src, out / "images" / split / f"{name}{src.suffix}")
    (out / "labels" / split / f"{name}.txt").write_text("\n".join(lines))
    done += 1

    if i < 5:   # controlebeelden
        im = Image.open(src).convert("RGB"); d = ImageDraw.Draw(im); W, H = im.size
        for k, (x, y) in enumerate(row.xy):
            c = "yellow" if k < 4 else "red"
            d.ellipse([x * W - 6, y * H - 6, x * W + 6, y * H + 6], outline=c, width=3)
            d.text((x * W + 8, y * H - 8), str(k + 1) if k < 4 else "D", fill=c)
        im.save(preview / f"{name}.jpg")

print(f"Klaar: {done} foto's omgezet, {missing} niet gevonden. Controlebeelden in {preview}/")
