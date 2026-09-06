"""Erzeugt das App-Icon: eine Mini-Heatmap auf blauem Grund.

Das Motiv ist bewusst die Heatmap und kein Häkchen: Häkchen hat jede
Aufgaben-App, das Raster gehört zu dieser hier.

Der Erzeuger liegt im Repo, damit das Icon änderbar bleibt. Zehn PNGs im
Asset-Katalog sind sonst ein Klumpen, den niemand mehr anfassen kann.

    python3 tools/make-app-icon.py         # macOS-Asset-Katalog
    python3 tools/make-app-icon.py --ios   # iOS-Asset-Katalog
    python3 tools/make-app-icon.py --web   # Symbole der WebApp

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

def motiv(inner):
    """Das Bild selbst: Verlauf und Raster, ohne Maske und ohne Rand."""
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

    return bg


def build():
    """macOS: Squircle, und der Inhalt sitzt in 824 von 1024 Punkten."""
    inner = 824 * SS
    bg = motiv(inner)
    mask = superellipse_mask(inner)
    icon_inner = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    icon_inner.paste(bg, (0, 0), mask)

    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    canvas.paste(icon_inner, (INSET * SS, INSET * SS), icon_inner)
    return canvas.resize((S, S), Image.LANCZOS)


def build_web(rand=0.0):
    """Randlos und quadratisch — iOS und Android runden selbst.

    Ein Icon mit eingebautem Squircle sieht auf dem Homescreen aus wie ein Bild
    in einem Rahmen in einem Rahmen. `rand` ist die Schutzzone für `maskable`:
    Android schneidet je nach Gerät bis zu 10 % je Seite ab, also muss das
    Motiv entsprechend kleiner sitzen.
    """
    inner = 824 * SS
    kern = motiv(inner)
    if rand <= 0:
        return kern.resize((S, S), Image.LANCZOS)

    voll = Image.new("RGBA", (inner, inner), (0x28, 0x5F, 0xDC, 255))
    klein = round(inner * (1 - 2 * rand))
    voll.paste(kern.resize((klein, klein), Image.LANCZOS), (round(inner * rand),) * 2)
    return voll.resize((S, S), Image.LANCZOS)

import json, os, sys

WURZEL = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SET = os.path.join(WURZEL, "apple/HabitTrackerMac/Assets.xcassets/AppIcon.appiconset")
WEB = os.path.join(WURZEL, "web/public/icons")

IOS = os.path.join(WURZEL, "apple/HabitTrackerIOS/Assets.xcassets")

if "--ios" in sys.argv:
    # iOS nimmt seit Xcode 14 ein einziges 1024er und rundet selbst. Randlos
    # und ohne Transparenz — beides verlangt Apple, und beides liefert
    # `build_web()` schon.
    ordner = os.path.join(IOS, "AppIcon.appiconset")
    os.makedirs(ordner, exist_ok=True)
    build_web().convert("RGB").save(os.path.join(ordner, "icon-1024.png"))
    with open(os.path.join(ordner, "Contents.json"), "w") as f:
        json.dump({"images": [{"filename": "icon-1024.png", "idiom": "universal",
                               "platform": "ios", "size": "1024x1024"}],
                   "info": {"version": 1, "author": "xcode"}}, f, indent=2)
    with open(os.path.join(IOS, "Contents.json"), "w") as f:
        json.dump({"info": {"version": 1, "author": "xcode"}}, f, indent=2)
    print(f"1 Symbol nach {ordner}")
    sys.exit(0)

if "--web" in sys.argv:
    os.makedirs(WEB, exist_ok=True)
    randlos = build_web()
    # `maskable` mit Schutzzone; die anderen randlos, sonst schrumpft das Motiv
    # zweimal — einmal hier und einmal durch die Maske des Systems.
    geschuetzt = build_web(rand=0.10)
    for name, bild, px in [
        ("icon-192.png", randlos, 192),
        ("icon-512.png", randlos, 512),
        ("icon-maskable-512.png", geschuetzt, 512),
        # iOS rundet ein Homescreen-Symbol selbst und erwartet es randlos.
        ("apple-touch-icon-180.png", randlos, 180),
        ("favicon-32.png", randlos, 32),
    ]:
        bild.resize((px, px), Image.LANCZOS).save(os.path.join(WEB, name))
    print(f"5 Symbole nach {WEB}")
    sys.exit(0)

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
