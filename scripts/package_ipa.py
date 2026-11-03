from pathlib import Path
import hashlib
import plistlib
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    app = ROOT / "build/device/Build/Products/Release-iphoneos/UTubeMusic.app"
    with (app / "Info.plist").open("rb") as f:
        info = plistlib.load(f)
    assert "audio" in info["UIBackgroundModes"]
    assert info["CFBundleIdentifier"] == "local.utubemusic.player"
    assert (app / "app/music_engine.py").is_file()
    assert (app / "Frameworks/Python.framework/Python").is_file()
    assert (app / "python/lib/python3.13/encodings").is_dir()
    assert not (app / "python/lib/python3.13/test").exists(), "Development-only CPython tests must not ship"
    assert not list(app.rglob("*.so")), "Unpackaged native Python modules"
    output = ROOT / "build/UTubeMusic-0.3.6-unsigned.ipa"
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            relative = str(Path("Payload") / "UTubeMusic.app" / path.relative_to(app))
            if path.is_symlink():
                item = zipfile.ZipInfo(relative)
                item.create_system = 3
                item.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(item, str(path.readlink()))
            elif path.is_file():
                archive.write(path, relative)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".ipa.sha256").write_text(digest + "  " + output.name + "\n")
    print(output)


if __name__ == "__main__":
    main()
