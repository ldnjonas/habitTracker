"""Erzeugt das App-Icon: eine Mini-Heatmap auf blauem Grund.

Das Motiv ist bewusst die Heatmap und kein Häkchen: Häkchen hat jede
Aufgaben-App, das Raster gehört zu dieser hier.

Der Erzeuger liegt im Repo, damit das Icon änderbar bleibt. Zehn PNGs im
Asset-Katalog sind sonst ein Klumpen, den niemand mehr anfassen kann.

    python3 tools/make-app-icon.py        # braucht Pillow

Schreibt direkt in apple/HabitTrackerMac/Assets.xcassets/AppIcon.appiconset.
Danach `cd apple && xcodegen generate` ist nicht nötig — der Katalog liegt
schon im Quellordner des Targets.
"""
from PIL import Image, ImageDraw
import os

S = 1024
SS = 4                      # Überabtastung fürs Kantenglätten
N = S * SS

# macOS zeichnet den Inhalt in ein Rechteck von 824 von 1024 Punkten.
INSET = (S - 824) // 2

def superellipse_mask(size, radius_ratio=0.235, n=5.0):
    """Apples Squircle — ein Kreisradius sieht daneben eckig aus."""
    mask = Image.new("L", (size, size), 0)
    px = mask.load()
    a = size / 2
    # Der Exponent formt die Ecke; 5 kommt Apples Kurve sehr nahe.
    for y in range(size):
        dy = abs(y - a + 0.5) / a
        for x in range(size):
            dx = abs(x - a + 0.5) / a
            if dx ** n + dy ** n <= 1.0:
                px[x, y] = 255
    return mask

def lerp(c1, c2, t):
    return tuple(round(a + (b - a) * t) for a, b in zip(c1, c2))

def build():
    inner = (824) * SS
    # Grund: senkrechter Verlauf im Blau der App.
    top, bottom = (0x6F, 0xA8, 0xFF), (0x28, 0x5F, 0xDC)
    bg = Image.new("RGB", (inner, inner))
    d = ImageDraw.Draw(bg)
    for y in range(inner):
        d.line([(0, y), (inner, y)], fill=lerp(top, bottom, y / inner))

    # Raster: 4 Spalten, 3 Zeilen. Grob genug, dass es auch klein trägt.
    cols, rows = 4, 3
    pad = inner * 0.155
    gap = inner * 0.045
    field = inner - 2 * pad
    # Quadratisch: eine Heatmap besteht aus Quadraten, nicht aus Hochkantfeldern.
    cell = (field - gap * (cols - 1)) / cols
    cell_h = cell
    top_y = (inner - (cell_h * rows + gap * (rows - 1))) / 2

    # Dichte nimmt nach rechts zu — das Bild einer Serie, die trägt.
    alpha = [
        [0.30, 0.55, 0.80, 1.00],
        [0.45, 0.80, 1.00, 1.00],
        [0.25, 0.45, 0.70, 1.00],
    ]
    overlay = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    for r in range(rows):
        for c in range(cols):
            x0 = pad + c * (cell + gap)
            y0 = top_y + r * (cell_h + gap)
            od.rounded_rectangle(
                [x0, y0, x0 + cell, y0 + cell_h],
                radius=cell * 0.24,
                fill=(255, 255, 255, round(255 * alpha[r][c])))
    bg = Image.alpha_composite(bg.convert("RGBA"), overlay)

    mask = superellipse_mask(inner)
    icon_inner = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    icon_inner.paste(bg, (0, 0), mask)

    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    canvas.paste(icon_inner, (INSET * SS, INSET * SS), icon_inner)
    return canvas.resize((S, S), Image.LANCZOS)

import json, os

SET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "apple/HabitTrackerMac/Assets.xcassets/AppIcon.appiconset")

icon = build()
os.makedirs(SET, exist_ok=True)

# macOS erwartet fünf Kantenlängen in je einfacher und doppelter Auflösung.
specs = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
         (256, 1), (256, 2), (512, 1), (512, 2)]
images = []
for pt, scale in specs:
    px = pt * scale
    name = f"icon_{pt}x{pt}@{scale}x.png"
    icon.resize((px, px), Image.LANCZOS).save(os.path.join(SET, name))
    images.append({"size": f"{pt}x{pt}", "idiom": "mac",
                   "filename": name, "scale": f"{scale}x"})

with open(os.path.join(SET, "Contents.json"), "w") as f:
    json.dump({"images": images, "info": {"version": 1, "author": "xcode"}}, f, indent=2)

print(f"{len(images)} Größen nach {SET}")
print("Zeigt das Dock noch das alte Icon, hält LaunchServices es fest:")
print("  touch <App>.app && killall Dock")
