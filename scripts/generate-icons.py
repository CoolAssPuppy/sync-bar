#!/usr/bin/env python3
"""
Generates the SyncNerds AppIcon set and menu bar status item templates from
a single drawing routine.

  AppIcon set: 1024 master + all macOS sizes, charcoal squircle + yellow loop.
  Menu bar templates: 18px (1x) and 36px (2x) silhouettes, plus a yellow
  "syncing" variant.

The shapes are drawn via PIL with the same geometry the Paper studies use:
two opposing arcs with flared triangular arrowheads.

Run:  python3 scripts/generate-icons.py
"""
from __future__ import annotations
import math
import os
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_ICON_DIR = os.path.join(ROOT, "Images.xcassets", "AppIcon.appiconset")
MENU_ICON_DIR = os.path.join(ROOT, "Images.xcassets", "MenuBarIcon.imageset")
MENU_SYNCING_DIR = os.path.join(ROOT, "Images.xcassets", "MenuBarIconSyncing.imageset")

CHARCOAL = (18, 18, 18, 255)      # #121212
YELLOW   = (253, 184, 23, 255)    # #FDB817


def supersampled(size: int) -> tuple[Image.Image, ImageDraw.ImageDraw, int]:
    """Draw at 4x for crisp downsample."""
    s = size * 4
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img), s


def draw_loop_shape(draw: ImageDraw.ImageDraw, s: int, color: tuple, *,
                    stroke_ratio: float = 0.105) -> None:
    """Draw the two opposing arrowed arcs filling a square of side `s`."""
    cx = cy = s / 2
    radius = s * 0.305
    stroke = s * stroke_ratio

    # Top arc: 0° points right; we want the arc from the right side (0°)
    # sweeping counter-clockwise up and over to ~12 o'clock minus a hair.
    # PIL's draw.arc uses degrees clockwise from 3 o'clock, so:
    #   start=270° (top) → end=0° (right): top-right quadrant
    # For top arc travelling right→top we use start=270, end=360
    bb_top = [cx - radius, cy - radius, cx + radius, cy + radius]
    draw.arc(bb_top, start=270, end=360, fill=color, width=int(stroke))

    # Bottom arc: start=90° (bottom), end=180° (left)
    draw.arc(bb_top, start=90, end=180, fill=color, width=int(stroke))

    # Arrowheads. Tangent at endpoint of each arc points along ±x.
    # Top arc ends at (cx, cy - radius). Arrowhead points west.
    head_depth = radius * 0.55
    head_half  = stroke * 1.05
    # Top tip
    top_x = cx - head_depth
    top_y = cy - radius
    draw.polygon([
        (top_x, top_y),
        (cx, top_y - head_half),
        (cx, top_y + head_half),
    ], fill=color)

    # Bottom arc ends at (cx, cy + radius). Arrowhead points east.
    bot_x = cx + head_depth
    bot_y = cy + radius
    draw.polygon([
        (bot_x, bot_y),
        (cx, bot_y - head_half),
        (cx, bot_y + head_half),
    ], fill=color)


def render_app_icon(size: int) -> Image.Image:
    """Charcoal rounded-square ground + yellow loop shape."""
    img, draw, s = supersampled(size)
    radius = int(s * 0.22)
    draw.rounded_rectangle([(0, 0), (s, s)], radius=radius, fill=CHARCOAL)

    # Subtle radial highlight on the top-left for a touch of life.
    highlight = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    hdraw = ImageDraw.Draw(highlight)
    hdraw.ellipse([(0, -s * 0.15), (s * 0.85, s * 0.65)], fill=(255, 255, 255, 14))
    img.alpha_composite(highlight)

    # Inset the loop slightly so it doesn't crowd the squircle edges.
    loop = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ldraw = ImageDraw.Draw(loop)
    draw_loop_shape(ldraw, s, YELLOW)
    img.alpha_composite(loop)

    return img.resize((size, size), Image.LANCZOS)


def render_menu_bar(size: int, color: tuple) -> Image.Image:
    """Just the loop shape on a transparent background."""
    img, draw, s = supersampled(size)
    draw_loop_shape(draw, s, color, stroke_ratio=0.13)
    return img.resize((size, size), Image.LANCZOS)


# MARK: - File outputs

APP_ICON_SIZES = [
    (16, "1x"), (16, "2x"),
    (32, "1x"), (32, "2x"),
    (128, "1x"), (128, "2x"),
    (256, "1x"), (256, "2x"),
    (512, "1x"), (512, "2x"),
]

APP_ICON_CONTENTS = {
    "images": [
        {"size": "16x16", "idiom": "mac", "filename": "icon_16x16.png",     "scale": "1x"},
        {"size": "16x16", "idiom": "mac", "filename": "icon_16x16@2x.png",  "scale": "2x"},
        {"size": "32x32", "idiom": "mac", "filename": "icon_32x32.png",     "scale": "1x"},
        {"size": "32x32", "idiom": "mac", "filename": "icon_32x32@2x.png",  "scale": "2x"},
        {"size": "128x128", "idiom": "mac", "filename": "icon_128x128.png",    "scale": "1x"},
        {"size": "128x128", "idiom": "mac", "filename": "icon_128x128@2x.png", "scale": "2x"},
        {"size": "256x256", "idiom": "mac", "filename": "icon_256x256.png",    "scale": "1x"},
        {"size": "256x256", "idiom": "mac", "filename": "icon_256x256@2x.png", "scale": "2x"},
        {"size": "512x512", "idiom": "mac", "filename": "icon_512x512.png",    "scale": "1x"},
        {"size": "512x512", "idiom": "mac", "filename": "icon_512x512@2x.png", "scale": "2x"},
    ],
    "info": {"version": 1, "author": "xcode"},
}


def write_app_icons() -> None:
    os.makedirs(APP_ICON_DIR, exist_ok=True)
    # Build the actual pixel sizes (1x = nominal; 2x = double).
    nominal_to_files = [
        (16, "icon_16x16.png", "icon_16x16@2x.png"),
        (32, "icon_32x32.png", "icon_32x32@2x.png"),
        (128, "icon_128x128.png", "icon_128x128@2x.png"),
        (256, "icon_256x256.png", "icon_256x256@2x.png"),
        (512, "icon_512x512.png", "icon_512x512@2x.png"),
    ]
    for nominal, one_x, two_x in nominal_to_files:
        render_app_icon(nominal).save(os.path.join(APP_ICON_DIR, one_x))
        render_app_icon(nominal * 2).save(os.path.join(APP_ICON_DIR, two_x))
        print(f"  app icon {nominal}px and {nominal*2}px (@2x)")

    import json
    with open(os.path.join(APP_ICON_DIR, "Contents.json"), "w") as f:
        json.dump(APP_ICON_CONTENTS, f, indent=2)


def write_menu_bar_icons() -> None:
    """Black template (auto-tinted by macOS) + yellow syncing variant."""
    os.makedirs(MENU_ICON_DIR, exist_ok=True)
    os.makedirs(MENU_SYNCING_DIR, exist_ok=True)

    # Template (black silhouette, macOS tints it for menu bar)
    render_menu_bar(18, (0, 0, 0, 255)).save(os.path.join(MENU_ICON_DIR, "menubar.png"))
    render_menu_bar(36, (0, 0, 0, 255)).save(os.path.join(MENU_ICON_DIR, "menubar@2x.png"))
    render_menu_bar(54, (0, 0, 0, 255)).save(os.path.join(MENU_ICON_DIR, "menubar@3x.png"))

    # Yellow syncing variant (rendered directly, not tinted)
    render_menu_bar(18, YELLOW).save(os.path.join(MENU_SYNCING_DIR, "menubar.png"))
    render_menu_bar(36, YELLOW).save(os.path.join(MENU_SYNCING_DIR, "menubar@2x.png"))
    render_menu_bar(54, YELLOW).save(os.path.join(MENU_SYNCING_DIR, "menubar@3x.png"))

    import json
    template_contents = {
        "images": [
            {"idiom": "universal", "filename": "menubar.png",    "scale": "1x"},
            {"idiom": "universal", "filename": "menubar@2x.png", "scale": "2x"},
            {"idiom": "universal", "filename": "menubar@3x.png", "scale": "3x"},
        ],
        "info": {"version": 1, "author": "xcode"},
        "properties": {"template-rendering-intent": "template"},
    }
    syncing_contents = {
        "images": [
            {"idiom": "universal", "filename": "menubar.png",    "scale": "1x"},
            {"idiom": "universal", "filename": "menubar@2x.png", "scale": "2x"},
            {"idiom": "universal", "filename": "menubar@3x.png", "scale": "3x"},
        ],
        "info": {"version": 1, "author": "xcode"},
    }
    with open(os.path.join(MENU_ICON_DIR, "Contents.json"), "w") as f:
        json.dump(template_contents, f, indent=2)
    with open(os.path.join(MENU_SYNCING_DIR, "Contents.json"), "w") as f:
        json.dump(syncing_contents, f, indent=2)
    print("  menu bar template + syncing variants (1x/2x/3x)")


if __name__ == "__main__":
    print("Rendering SyncNerds icons…")
    write_app_icons()
    write_menu_bar_icons()
    print("Done.")
