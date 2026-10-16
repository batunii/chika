#!/usr/bin/env python3
"""Convert a Manga109 / Manga109-s dataset into the shared 2-class YOLO dataset.

Manga109 layout (after you download + unzip the approved dataset):
  <root>/annotations/<Title>.xml          # per-book XML
  <root>/images/<Title>/<index:03d>.jpg    # pages, zero-padded 3-digit index
XML per page: <page index width height> with <frame .../> (= panel) and <text ...> elements,
each carrying xmin/ymin/xmax/ymax in ABSOLUTE PIXELS. We map frame→0 (panel), text→1 (text)
and drop <face>/<body>.

Usage:
  python manga109_to_yolo.py --root <manga109 root> --out <dataset dir> [--val-frac 0.1]
"""
import argparse, os, glob, zlib
import xml.etree.ElementTree as ET

PANEL_CLASS, TEXT_CLASS = 0, 1
MIN_SIDE_PX = 6


def box_line(el, W, H, cls):
    try:
        x1, y1 = float(el.get("xmin")), float(el.get("ymin"))
        x2, y2 = float(el.get("xmax")), float(el.get("ymax"))
    except (TypeError, ValueError):
        return None
    x1, x2 = sorted((x1, x2)); y1, y2 = sorted((y1, y2))
    bw, bh = x2 - x1, y2 - y1
    if bw < MIN_SIDE_PX or bh < MIN_SIDE_PX or W <= 0 or H <= 0:
        return None
    return f"{cls} {(x1+x2)/2/W:.6f} {(y1+y2)/2/H:.6f} {bw/W:.6f} {bh/H:.6f}"


def convert(root, out, val_frac):
    xmls = sorted(glob.glob(os.path.join(root, "annotations", "*.xml")))
    if not xmls:
        # Some distributions nest under Manga109_released_*/ — try one level down.
        xmls = sorted(glob.glob(os.path.join(root, "*", "annotations", "*.xml")))
    print(f"found {len(xmls)} Manga109 book annotation files")

    pages = 0
    step = max(1, int(1 / val_frac))
    # Split BY BOOK (stable hash of the title): pages of one manga share art style and characters,
    # so interleaving them across train/val leaks and inflates validation metrics.
    for xml in xmls:
        title = os.path.splitext(os.path.basename(xml))[0]
        split = "val" if zlib.crc32(title.encode()) % step == 0 else "train"
        img_root = os.path.join(os.path.dirname(os.path.dirname(xml)), "images", title)
        tree = ET.parse(xml)
        for page in tree.iter("page"):
            try:
                W, H = int(page.get("width")), int(page.get("height"))
                idx = int(page.get("index"))
            except (TypeError, ValueError):
                continue
            img_path = os.path.join(img_root, f"{idx:03d}.jpg")
            if not os.path.exists(img_path):
                continue
            lines = []
            for fr in page.findall("frame"):
                ln = box_line(fr, W, H, PANEL_CLASS)
                if ln: lines.append(ln)
            for tx in page.findall("text"):
                ln = box_line(tx, W, H, TEXT_CLASS)
                if ln: lines.append(ln)
            if not lines:
                continue
            dst_img = os.path.join(out, "images", split, f"m109_{title}_{idx:03d}.jpg")
            dst_lbl = os.path.join(out, "labels", split, f"m109_{title}_{idx:03d}.txt")
            os.makedirs(os.path.dirname(dst_img), exist_ok=True)
            os.makedirs(os.path.dirname(dst_lbl), exist_ok=True)
            if not os.path.exists(dst_img):
                os.symlink(os.path.abspath(img_path), dst_img)  # symlink to save disk
            open(dst_lbl, "w").write("\n".join(lines) + "\n")
            pages += 1
    print(f"wrote {pages} Manga109 pages into {out}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--val-frac", type=float, default=0.1)
    a = ap.parse_args()
    convert(a.root, a.out, a.val_frac)
