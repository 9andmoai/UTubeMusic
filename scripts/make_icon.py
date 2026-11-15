"""Original, code-drawn opaque RGB icon; no external artwork or Pillow needed."""
from pathlib import Path
import json
import math
import struct
import zlib


def create_icon(folder, platform="ios"):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    size = 1024
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            dx, dy = x - 512, y - 512
            distance = math.hypot(dx, dy)
            rgb = (18, 20, 24)
            if distance < 348:
                fade = min(1, max(0, (y - 150) / 720))
                rgb = (int(255 - 30 * fade), int(110 - 35 * fade), int(85 - 18 * fade))
            # Four bars form a small waveform, then a counterweight dot.
            heights = [125, 230, 175, 90]
            for i, height in enumerate(heights):
                cx = 350 + i * 102
                if abs(x - cx) <= 27 and abs(y - 512) <= height:
                    rgb = (21, 22, 26)
                elif math.hypot(x - cx, abs(y - 512) - height) < 27 and abs(y - 512) > height:
                    rgb = (21, 22, 26)
            rows.extend(rgb)
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    (folder / "AppIcon.png").write_bytes(png)
    (folder / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"}], "info": {"author": "UTubeMusic", "version": 1}}, indent=2))


if __name__ == "__main__":
    create_icon(Path(__file__).resolve().parents[1] / "Sources/Assets.xcassets/AppIcon.appiconset")
