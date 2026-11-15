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
    watch = app / "Watch/UTubeMusicWatch.app"
    with (watch / "Info.plist").open("rb") as f:
        watch_info = plistlib.load(f)
    assert watch_info["WKCompanionAppBundleIdentifier"] == info["CFBundleIdentifier"]
    assert watch_info["CFBundleIdentifier"] == info["CFBundleIdentifier"] + ".watchkitapp"
    assert watch_info["CFBundleVersion"] == info["CFBundleVersion"]
    assert watch_info["DTPlatformName"] == "watchos"
    assert "audio" in watch_info["UIBackgroundModes"]
    assert (watch / watch_info["CFBundleExecutable"]).is_file()
    version = info["CFBundleShortVersionString"]
    for variant, include_watch in (("", False), ("-Watch", True)):
        write_ipa(app, ROOT / f"build/UTubeMusic-{version}{variant}-unsigned.ipa", include_watch)


def write_ipa(app, output, include_watch):
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(app.rglob("*")):
            inside = path.relative_to(app)
            if not include_watch and inside.parts[0] == "Watch":
                continue
            relative = (Path("Payload") / "UTubeMusic.app" / inside).as_posix()
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
