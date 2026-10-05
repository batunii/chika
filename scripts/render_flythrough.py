"""Render Chika's original comic-page camera flight into a seekable MP4.

The art is stored as two 2x2 atlases beside this script. Each plane has its own
scene and fixed position in the corridor; scrolling through the resulting film
therefore always moves the camera past different physical pages.
"""

from __future__ import annotations

import argparse
import math
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent
ATLAS_DIR = ROOT / "film-art"
PANELS = [
    ("story-atlas-a.png", 0, 16, 3.5, -0.5, -3),  # rainy rooftop
    ("story-atlas-a.png", 1, 30, -3.6, 0.2, 3),  # envelope
    ("story-atlas-b.png", 0, 44, 3.4, 0.9, -4),  # railway station
    ("story-atlas-b.png", 1, 58, -3.8, -0.9, 4),  # map
    ("story-atlas-a.png", 2, 72, 3.7, 0.0, -2),  # city window
    ("story-atlas-b.png", 2, 86, -3.5, 0.6, 2),  # glass bridge
    ("story-atlas-a.png", 3, 100, 3.2, -0.5, -3),  # robot's greenhouse
    ("story-atlas-b.png", 3, 119, 0.3, 0.0, 0),  # courier meets robot
]


def source_panels() -> list[Image.Image]:
    atlases: dict[str, Image.Image] = {}
    result = []
    for filename, quadrant, *_ in PANELS:
        if filename not in atlases:
            atlases[filename] = Image.open(ATLAS_DIR / filename).convert("RGB")
        atlas = atlases[filename]
        half_w, half_h = atlas.width // 2, atlas.height // 2
        x, y = quadrant % 2 * half_w, quadrant // 2 * half_h
        art = atlas.crop((x, y, x + half_w, y + half_h))
        surface = Image.new("RGB", (half_w + 42, half_h + 58), "#e9dec7")
        surface.paste(art, (21, 21))
        draw = ImageDraw.Draw(surface)
        draw.rectangle((20, 20, half_w + 21, half_h + 21), outline="#271c1b", width=3)
        draw.line((21, half_h + 39, half_w + 20, half_h + 39), fill="#a99b86", width=2)
        result.append(surface)
    return result


def camera_position(t: float) -> float:
    """Equal scroll movement always produces equal forward travel."""
    return t * 115


def solve_perspective(points: list[tuple[float, float]], source_w: int, source_h: int) -> tuple[float, ...]:
    """Map a projected screen quadrilateral back to page texture coordinates."""
    source = [(0, 0), (source_w, 0), (source_w, source_h), (0, source_h)]
    rows = []
    for (x, y), (u, v) in zip(points, source):
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
    for col in range(8):
        pivot = max(range(col, 8), key=lambda r: abs(rows[r][col]))
        rows[col], rows[pivot] = rows[pivot], rows[col]
        scale = rows[col][col]
        if abs(scale) < 1e-8:
            raise ValueError("Projected page is too thin")
        rows[col] = [value / scale for value in rows[col]]
        for row in range(8):
            if row == col:
                continue
            factor = rows[row][col]
            rows[row] = [a - factor * b for a, b in zip(rows[row], rows[col])]
    return tuple(row[8] for row in rows)


def draw_frame(art: list[Image.Image], t: float, width: int, height: int) -> Image.Image:
    camera_z = camera_position(t)
    camera_x = 0.24 * math.sin(2.0 * math.pi * t)
    camera_y = 0.08 * math.sin(3.0 * math.pi * t)
    portrait = height > width
    focal = height * 0.68 if portrait else width * 0.78
    centre_x, centre_y = width * 0.5, height * 0.51

    frame = Image.new("RGB", (width, height), "#0c0e13")
    pen = ImageDraw.Draw(frame)

    # Architectural lines hold the perspective even between illustrated pages.
    vanish_x = centre_x - camera_x * 30
    for side in (-1, 1):
        x = vanish_x + side * width * 0.93
        pen.line((vanish_x, centre_y + height * 0.13, x, height), fill="#403834", width=2)
        pen.line((vanish_x, centre_y - height * 0.21, x, 0), fill="#29272b", width=2)

    visible = []
    for i, (_, _, panel_z, panel_x, panel_y, tilt) in enumerate(PANELS):
        depth = panel_z - camera_z
        if depth <= 2.5 or depth > 130:
            continue
        if portrait:
            panel_x *= 0.34
            camera_shift_x = camera_x * 0.34
        else:
            camera_shift_x = camera_x
        yaw = math.radians(-16 if panel_x > 1 else 16 if panel_x < -1 else 0)
        roll = math.radians(tilt)
        world_w = 8.5 if portrait else 7.0
        world_h = world_w * art[i].height / art[i].width
        points = []
        for local_x, local_y in [(-world_w / 2, -world_h / 2), (world_w / 2, -world_h / 2),
                                 (world_w / 2, world_h / 2), (-world_w / 2, world_h / 2)]:
            corner_z = depth - math.sin(yaw) * local_x
            if corner_z <= 1.5:
                points = []
                break
            corner_x = panel_x + math.cos(yaw) * local_x
            corner_y = panel_y + local_y + math.tan(roll) * local_x
            points.append((centre_x + focal * (corner_x - camera_shift_x) / corner_z,
                           centre_y + focal * (corner_y - camera_y) / corner_z))
        if points:
            visible.append((depth, i, points))

    for depth, i, points in sorted(visible, reverse=True):
        left = max(0, int(math.floor(min(p[0] for p in points))))
        top = max(0, int(math.floor(min(p[1] for p in points))))
        right = min(width, int(math.ceil(max(p[0] for p in points))))
        bottom = min(height, int(math.ceil(max(p[1] for p in points))))
        if right <= left or bottom <= top:
            continue
        pen = ImageDraw.Draw(frame)
        shadow_offset = max(5, round(width / 85))
        pen.polygon([(x + shadow_offset, y + shadow_offset) for x, y in points], fill="#04050a")
        local_points = [(x - left, y - top) for x, y in points]
        try:
            coefficients = solve_perspective(local_points, art[i].width, art[i].height)
        except ValueError:
            continue
        warped = art[i].convert("RGBA").transform(
            (right - left, bottom - top), Image.Transform.PERSPECTIVE, coefficients,
            resample=Image.Resampling.BICUBIC, fillcolor=(0, 0, 0, 0),
        )
        frame.paste(warped, (left, top), warped)
        pen = ImageDraw.Draw(frame)
        pen.line(points + [points[0]], fill="#f3e7ce", width=max(1, round(width / 640)), joint="curve")

    # Cinematic edge falloff, stable across frames for clean scroll scrubbing.
    veil = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    vdraw = ImageDraw.Draw(veil)
    vdraw.rectangle((0, 0, width, height), fill=(5, 4, 7, 25))
    frame = Image.alpha_composite(frame.convert("RGBA"), veil).convert("RGB")
    return frame


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=int, default=24)
    parser.add_argument("--seconds", type=float, default=8.0)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    art = source_panels()
    command = [
        "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgb24",
        "-s", f"{args.width}x{args.height}", "-r", str(args.fps), "-i", "-",
        "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "19",
        "-pix_fmt", "yuv420p", "-g", "6", "-keyint_min", "6", "-sc_threshold", "0",
        "-movflags", "+faststart", str(args.output),
    ]
    process = subprocess.Popen(command, stdin=subprocess.PIPE)
    assert process.stdin is not None
    try:
        count = round(args.seconds * args.fps)
        for n in range(count):
            t = n / max(1, count - 1)
            process.stdin.write(draw_frame(art, t, args.width, args.height).tobytes())
    finally:
        process.stdin.close()
    if process.wait() != 0:
        raise SystemExit("ffmpeg failed to render the fly-through")


if __name__ == "__main__":
    main()
