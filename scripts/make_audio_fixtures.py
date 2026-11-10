"""Generate synthetic AAC fixtures only; FFmpeg is a developer tool, not an app dependency.

Usage: python scripts/make_audio_fixtures.py /path/to/ffmpeg
The middle 0.6 seconds is intentional silence and the final second contains tone.
"""
import base64
import json
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def inflate_dash_headers(data):
    data = bytearray(data)

    def visit(start, end):
        offset = start
        while offset + 8 <= end:
            size, kind = struct.unpack_from(">I4s", data, offset)
            assert size >= 8 and offset + size <= end
            payload = offset + 8
            if kind in (b"moov", b"trak", b"mdia"):
                visit(payload, offset + size)
            elif kind in (b"mvhd", b"mdhd"):
                assert data[payload] == 0
                scale = struct.unpack_from(">I", data, payload + 12)[0]
                struct.pack_into(">I", data, payload + 16, scale * 3)
            elif kind == b"tkhd":
                assert data[payload] == 0
                struct.pack_into(">I", data, payload + 20, 3000)
            offset += size

    visit(0, len(data))
    return bytes(data)


def main():
    work = ROOT / "build/audio-fixtures"
    work.mkdir(parents=True, exist_ok=True)
    fixtures = {}
    for name, flags in [("regular", "+faststart"), ("dash", "+dash+global_sidx")]:
        output = work / (name + ".m4a")
        subprocess.run([sys.argv[1], "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        r"aevalsrc=if(between(t\,0.6\,1.2)\,0\,0.2*sin(2*PI*440*t)):s=44100:d=3",
                        "-c:a", "aac", "-b:a", "96k", "-movflags", flags,
                        *(["-frag_duration", "500000"] if name == "dash" else []),
                        "-f", "mp4", str(output)], check=True)
        fixtures[name] = base64.b64encode(output.read_bytes()).decode()
    for name, flags in [("intro_regular", "+faststart"), ("intro_dash", "+dash+global_sidx")]:
        output = work / (name + ".m4a")
        subprocess.run([sys.argv[1], "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        r"aevalsrc=if(lt(t\,2)\,0\,0.1*sin(2*PI*440*t)):s=44100:d=12",
                        "-c:a", "aac", "-b:a", "96k", "-movflags", flags,
                        *(["-frag_duration", "500000"] if name == "intro_dash" else []),
                        "-f", "mp4", str(output)], check=True)
        fixtures[name] = base64.b64encode(output.read_bytes()).decode()
    fixtures["dash_nonzero_headers"] = base64.b64encode(inflate_dash_headers(base64.b64decode(fixtures["dash"]))).decode()
    folder = ROOT / "Tests/Fixtures"
    folder.mkdir(exist_ok=True)
    (folder / "audio-fixtures.json").write_text(json.dumps(fixtures, indent=2) + "\n", encoding="utf-8")
    print("Wrote synthetic 3-second regular/DASH/nonzero-header fixtures")


if __name__ == "__main__":
    main()
