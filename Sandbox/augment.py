"""Offline augmentatie, afgestemd op een iPhone-camera op 60 fps.

Ultralytics doet zelf al Mosaic, schaal, translatie en HSV. Wat het NIET (of amper) doet en wat bij
jou wél gebeurt: bewegingsonscherpte, sensorruis bij weinig licht, andere lampkleur, compressie.
Dit script maakt daarvan extra kopieën. Labels blijven gelijk (alleen kleur/scherpte verandert).

    python augment.py --src dataset --dst dataset_aug --copies 2
    python augment.py --src dataset --dst dataset_aug --negatives negatieven\\   (foto's zonder pijlen)

Daarna trainen op dataset_aug/data.yaml.
"""
from __future__ import annotations

import argparse
import random
import shutil
from pathlib import Path

import cv2
import numpy as np

CLASS_NAMES = ["20", "3", "11", "6", "dart", "9", "15"]


# ── losse augmentaties (BGR uint8 in/uit) ─────────────────────────────────────
def motion_blur(img, rng):
    """Bewegingsonscherpte (hand, statief-tik, sluitertijd 1/60 s)."""
    k = rng.choice([5, 7, 9, 11, 15])
    kernel = np.zeros((k, k), np.float32)
    kernel[k // 2, :] = 1.0 / k
    M = cv2.getRotationMatrix2D((k / 2 - 0.5, k / 2 - 0.5), rng.uniform(0, 180), 1.0)
    kernel = cv2.warpAffine(kernel, M, (k, k))
    kernel /= max(kernel.sum(), 1e-6)
    return cv2.filter2D(img, -1, kernel)


def defocus(img, rng):
    k = rng.choice([3, 5])
    return cv2.GaussianBlur(img, (k, k), 0)


def sensor_noise(img, rng):
    """Ruis zoals bij weinig licht / hoge ISO."""
    sigma = rng.uniform(3, 12)
    noise = rng.normal(0, sigma, img.shape) if hasattr(rng, "normal") else np.random.normal(0, sigma, img.shape)
    return np.clip(img.astype(np.float32) + noise, 0, 255).astype(np.uint8)


def exposure(img, rng):
    """Donkere garage ↔ fel tuinlicht (gamma) + iets meer/minder contrast."""
    gamma = rng.uniform(0.55, 1.6)
    lut = np.clip(((np.arange(256) / 255.0) ** gamma) * 255 * rng.uniform(0.85, 1.15), 0, 255).astype(np.uint8)
    return cv2.LUT(img, lut)


def white_balance(img, rng):
    """Lampkleur: warm (gloeilamp) ↔ koel (TL/led)."""
    gains = np.array([rng.uniform(0.85, 1.15), 1.0, rng.uniform(0.85, 1.15)], np.float32)
    return np.clip(img.astype(np.float32) * gains, 0, 255).astype(np.uint8)


def jpeg(img, rng):
    q = int(rng.uniform(45, 90))
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])
    return cv2.imdecode(buf, cv2.IMREAD_COLOR) if ok else img


# (functie, kans)
PIPELINE = [(exposure, 0.6), (white_balance, 0.5), (motion_blur, 0.35), (defocus, 0.15),
            (sensor_noise, 0.4), (jpeg, 0.5)]


def augment(img: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    out = img
    for fn, p in PIPELINE:
        if rng.random() < p:
            out = fn(out, rng)
    return out


# ── dataset doorlopen ────────────────────────────────────────────────────────
def image_label_pairs(root: Path):
    """Vindt alle (beeld, label)-paren in een YOLO-dataset (elke map met images/ + labels/)."""
    for img in root.rglob("*.jpg"):
        if img.parent.name not in ("images", "train", "val") and "images" not in img.parts:
            continue
        parts = list(img.parts)
        idx = len(parts) - 1 - parts[::-1].index("images")
        label = Path(*parts[:idx], "labels", *parts[idx + 1:]).with_suffix(".txt")
        rel = Path(*img.parts[len(root.parts):idx])
        yield img, label, rel


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="bestaande YOLO-dataset (bv. export van de app of review.py)")
    ap.add_argument("--dst", required=True)
    ap.add_argument("--copies", type=int, default=2, help="extra varianten per beeld")
    ap.add_argument("--negatives", help="map met foto's zonder pijlen (handen, schaduwen, leeg bord…)")
    ap.add_argument("--seed", type=int, default=42)
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    src, dst = Path(args.src), Path(args.dst)
    groups: set[str] = set()
    n = 0
    for img_path, label_path, rel in image_label_pairs(src):
        img = cv2.imread(str(img_path))
        if img is None:
            continue
        group = rel.as_posix() or "train"
        groups.add(group)
        out_img = dst / group / "images"
        out_lbl = dst / group / "labels"
        out_img.mkdir(parents=True, exist_ok=True)
        out_lbl.mkdir(parents=True, exist_ok=True)
        label_text = label_path.read_text() if label_path.exists() else ""
        # origineel + varianten
        shutil.copy(img_path, out_img / img_path.name)
        (out_lbl / f"{img_path.stem}.txt").write_text(label_text)
        for k in range(args.copies):
            name = f"{img_path.stem}_aug{k}"
            cv2.imwrite(str(out_img / f"{name}.jpg"), augment(img, rng), [cv2.IMWRITE_JPEG_QUALITY, 92])
            (out_lbl / f"{name}.txt").write_text(label_text)
        n += 1

    # Achtergrondbeelden: LEEG labelbestand = "hier is niets", leert het model handen/schaduwen negeren.
    neg = 0
    if args.negatives:
        out_img, out_lbl = dst / "background" / "images", dst / "background" / "labels"
        out_img.mkdir(parents=True, exist_ok=True)
        out_lbl.mkdir(parents=True, exist_ok=True)
        for p in Path(args.negatives).rglob("*"):
            if p.suffix.lower() not in (".jpg", ".jpeg", ".png"):
                continue
            img = cv2.imread(str(p))
            if img is None:
                continue
            for k in range(1 + args.copies):
                name = f"bg_{p.stem}_{k}"
                cv2.imwrite(str(out_img / f"{name}.jpg"), img if k == 0 else augment(img, rng), [cv2.IMWRITE_JPEG_QUALITY, 92])
                (out_lbl / f"{name}.txt").write_text("")
                neg += 1
        groups.add("background")

    dirs = sorted(f"{g}/images" for g in groups)
    yaml = "train:\n" + "".join(f"  - {d}\n" for d in dirs) + "val:\n" + "".join(f"  - {d}\n" for d in dirs if d != "background/images")
    yaml += "names:\n" + "".join(f"  {i}: '{c}'\n" for i, c in enumerate(CLASS_NAMES))
    dst.mkdir(parents=True, exist_ok=True)
    (dst / "data.yaml").write_text(yaml)
    total = n * (1 + args.copies)
    print(f"{n} beelden → {total} (x{1 + args.copies}), {neg} achtergrondbeelden. Train met: --data {dst / 'data.yaml'}")
    if total and neg / (total + neg) > 0.15:
        print("Let op: meer dan 15% achtergrond. Ultralytics raadt 0–10% aan; te veel maakt het model voorzichtig.")


if __name__ == "__main__":
    main()
