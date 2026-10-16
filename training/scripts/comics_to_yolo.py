#!/usr/bin/env python3
"""Convert the COMICS (UMIACS) panel annotations into the shared 2-class YOLO dataset.

COMICS panel annotation files are `Annotations/{book}_{page}.txt`, one box per line as
`cls x1 y1 x2 y2` in ABSOLUTE PIXELS of the bundled page image `Images/{book}_{page}.jpg`.
Every box is a panel → mapped to our class 0 (panel). COMICS textboxes are per-panel-crop
(relative coords) so they are NOT used here; the text class (1) comes from Manga109.

Usage:
  python comics_to_yolo.py --src <extracted panels dir> --out <dataset dir> [--val-frac 0.1]
The <src> dir must contain Images/ and Annotations/.
"""
import argparse, os, glob, shutil, zlib
from PIL import Image

PANEL_CLASS = 0
MIN_SIDE_PX = 10          # drop degenerate sliver boxes
MIN_AREA_FRAC = 0.002     # drop boxes smaller than this fraction of the page


def convert(src, out, val_frac):
    ann_dir = os.path.join(src, "Annotations")
    img_dir = os.path.join(src, "Images")
    anns = sorted(glob.glob(os.path.join(ann_dir, "*.txt")))
    step = max(1, int(1 / val_frac)) if val_frac > 0 else 0
    print(f"found {len(anns)} COMICS panel annotation files")

    kept = 0
    for i, ann in enumerate(anns):
        stem = os.path.splitext(os.path.basename(ann))[0]
        img_path = os.path.join(img_dir, stem + ".jpg")
        if not os.path.exists(img_path):
            continue
        try:
            with Image.open(img_path) as im:
                W, H = im.size
        except Exception:
            continue
        if W <= 0 or H <= 0:
            continue

        lines = []
        for raw in open(ann):
            parts = raw.split()
            if len(parts) < 5:
                continue
            _, x1, y1, x2, y2 = parts[:5]
            x1, y1, x2, y2 = map(float, (x1, y1, x2, y2))
            x1, x2 = sorted((x1, x2)); y1, y2 = sorted((y1, y2))
            bw, bh = x2 - x1, y2 - y1
            if bw < MIN_SIDE_PX or bh < MIN_SIDE_PX:
                continue
            if (bw * bh) / (W * H) < MIN_AREA_FRAC:
                continue
            cx, cy = (x1 + x2) / 2 / W, (y1 + y2) / 2 / H
            nw, nh = bw / W, bh / H
            lines.append(f"{PANEL_CLASS} {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")
        if not lines:
            continue

        # Split BY BOOK ("{book}_{page}"): neighbouring pages of one book must not straddle train/val.
        book = stem.rsplit("_", 1)[0]
        split = "val" if step and zlib.crc32(book.encode()) % step == 0 else "train"
        dst_img = os.path.join(out, "images", split, f"comics_{stem}.jpg")
        dst_lbl = os.path.join(out, "labels", split, f"comics_{stem}.txt")
        os.makedirs(os.path.dirname(dst_img), exist_ok=True)
        os.makedirs(os.path.dirname(dst_lbl), exist_ok=True)
        shutil.copy(img_path, dst_img)
        open(dst_lbl, "w").write("\n".join(lines) + "\n")
        kept += 1
    print(f"wrote {kept} COMICS pages into {out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--val-frac", type=float, default=0.1)
    a = ap.parse_args()
    convert(a.src, a.out, a.val_frac)
