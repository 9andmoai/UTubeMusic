"""Collect named XCTest image attachments from xcresulttool's exported manifest."""
from pathlib import Path
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT / "build/screenshots"
found = set()


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values(): yield from walk(child)
    elif isinstance(value, list):
        for child in value: yield from walk(child)


for manifest in folder.rglob("*.json"):
    data = json.loads(manifest.read_text())
    for item in walk(data):
        name = item.get("suggestedHumanReadableName", item.get("name", ""))
        filename = item.get("exportedFileName", "")
        for target in ("native-home", "native-player", "native-search-playing", "native-search-bottom", "native-save", "native-library", "native-album", "native-batch-save", "native-favorites-add", "native-playlist-add", "native-add-search", "native-add-saved", "native-preview", "native-download-menu", "native-download-library", "native-download-selection", "native-settings", "native-intro-skip", "native-search-keyboard", "native-search-restored"):
            if target in name and filename:
                source = (manifest.parent / filename).resolve()
                assert source.is_relative_to(folder.resolve())
                shutil.copy2(source, ROOT / "build" / (target + ".png"))
                found.add(target)
if found != {"native-home", "native-player", "native-search-playing", "native-search-bottom", "native-save", "native-library", "native-album", "native-batch-save", "native-favorites-add", "native-playlist-add", "native-add-search", "native-add-saved", "native-preview", "native-download-menu", "native-download-library", "native-download-selection", "native-settings", "native-intro-skip", "native-search-keyboard", "native-search-restored"}:
    print("Exported attachment files:", [str(p.relative_to(folder)) for p in folder.rglob("*") if p.is_file()])
    for manifest in folder.rglob("*.json"):
        print(manifest.read_text()[:5000])
    raise SystemExit("Native screen attachments missing")
print("Native home/player screenshots collected from the running simulator tests")
