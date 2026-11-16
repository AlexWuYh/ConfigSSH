#!/usr/bin/env python3
"""Regenerate the approved Open C macOS icon from the logo-design SVG masters.

Requires Pillow, iconutil, and the installed logo-design skill renderer. Override
CONFIGSSH_LOGO_RENDERER if the skill lives outside ~/.codex/skills/logo-design.
"""

from pathlib import Path
import os
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "Assets" / "brand"
ASSETS = ROOT / "Assets"
RESOURCES = ROOT / "Sources" / "ConfigSSH" / "Resources"
RENDERER = Path(os.environ.get(
    "CONFIGSSH_LOGO_RENDERER",
    Path.home() / ".codex/skills/logo-design/scripts/render_png.py",
))


def render(svg: Path, png: Path, size: int) -> None:
    if not RENDERER.is_file():
        raise SystemExit(f"logo-design renderer not found: {RENDERER}")
    subprocess.run([sys.executable, str(RENDERER), str(svg), "-o", str(png),
                    "--size", str(size)], check=True)


def main() -> None:
    ASSETS.mkdir(exist_ok=True)
    RESOURCES.mkdir(exist_ok=True)
    app_svg = BRAND / "ConfigSSH-app-icon.svg"
    symbol_svg = BRAND / "ConfigSSH-black.svg"
    for source in (app_svg, symbol_svg):
        if not source.is_file():
            raise SystemExit(f"Missing approved SVG master: {source}")

    icon_png = ASSETS / "ConfigSSH-1024.png"
    render(app_svg, icon_png, 1024)
    render(symbol_svg, RESOURCES / "ConfigSSH-Menu.png", 64)
    icon = Image.open(icon_png).convert("RGBA")
    icon.resize((256, 256), Image.Resampling.LANCZOS).save(RESOURCES / "ConfigSSH-Mark.png")

    with tempfile.TemporaryDirectory(prefix="configssh-icon-") as temporary:
        iconset = Path(temporary) / "ConfigSSH.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            icon.resize((size, size), Image.Resampling.LANCZOS).save(iconset / f"icon_{size}x{size}.png")
            icon.resize((size * 2, size * 2), Image.Resampling.LANCZOS).save(
                iconset / f"icon_{size}x{size}@2x.png"
            )
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ASSETS / "ConfigSSH.icns")],
                       check=True)

    for output in (icon_png, ASSETS / "ConfigSSH.icns",
                   RESOURCES / "ConfigSSH-Mark.png", RESOURCES / "ConfigSSH-Menu.png"):
        print(output)


if __name__ == "__main__":
    main()
