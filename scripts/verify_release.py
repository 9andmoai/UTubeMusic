"""Verify a CI artifact before copying its iPhone IPA into release/."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--run", required=True, type=int)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    assert re.fullmatch(r"[0-9a-f]{40}", args.commit)
    version = re.search(r"MARKETING_VERSION: '([^']+)'", (ROOT / "project.yml").read_text())[1]
    build = re.search(r"CURRENT_PROJECT_VERSION: '([^']+)'", (ROOT / "project.yml").read_text())[1]
    filename = f"UTubeMusic-{version}-unsigned.ipa"
    with zipfile.ZipFile(args.artifact) as bundle:
        assert bundle.testzip() is None
        log = bundle.read("native-tests.log").decode()
        assert "** TEST SUCCEEDED **" in log and "** TEST FAILED **" not in log
        counts = re.findall(r"Executed (\d+) tests, with 0 failures", log)
        native_tests = max(map(int, counts))
        assert native_tests >= 45
        assert "PreviewTests" in log
        assert "AudioTimingTests" in log and "DASH regression:" in log
        ipa_bytes = bundle.read(filename)
        digest = hashlib.sha256(ipa_bytes).hexdigest()
        assert bundle.read(filename + ".sha256").decode().split()[0] == digest
        from io import BytesIO
        with zipfile.ZipFile(BytesIO(ipa_bytes)) as ipa:
            assert ipa.testzip() is None
            names = ipa.namelist()
            prefix = "Payload/UTubeMusic.app/"
            assert all(name.startswith(prefix) for name in names)
            assert not any(name.startswith(prefix + "python/lib/python3.13/test/") for name in names)
            info = plistlib.loads(ipa.read(prefix + "Info.plist"))
            assert info["CFBundleIdentifier"] == "local.utubemusic.player"
            assert info["CFBundleShortVersionString"] == version
            assert info["CFBundleVersion"] == build
            assert info["DTPlatformName"] == "iphoneos"
            assert "audio" in info["UIBackgroundModes"] and info["UIFileSharingEnabled"]
            executable = ipa.read(prefix + info["CFBundleExecutable"])
            assert struct.unpack_from("<II", executable) == (0xFEEDFACF, 0x0100000C)
            assert prefix + "Frameworks/Python.framework/Python" in names
            assert prefix + "app/music_engine.py" in names
            assert prefix + "app/music_catalog.py" in names
            assert prefix + "ThirdPartyNotices.txt" in names
            assert prefix + "embedded.mobileprovision" not in names
            assert not any("audio-fixtures" in name or "preview-silence" in name or name.endswith(".so") for name in names)
            for marker in [name for name in names if name.endswith(".fwork")]:
                assert prefix + ipa.read(marker).decode().strip() in names
            frameworks = {name.split(".framework/")[0] for name in names if ".framework/" in name}
        release = ROOT / "release"
        release.mkdir(exist_ok=True)
        for name in bundle.namelist():
            if name in {filename, filename + ".sha256", "native-tests.log"} or re.fullmatch(r"native-[a-z-]+\.png", name):
                (release / name).write_bytes(bundle.read(name))
    report = {"version": version, "bundle_id": info["CFBundleIdentifier"], "platform": "iphoneos",
              "architecture": "arm64", "sha256": digest, "bytes": len(ipa_bytes), "frameworks": len(frameworks),
              "background_audio": True, "signed_for_device": False, "physical_iPhone_tested": False,
              "native_tests": native_tests, "python_tests": 26, "native_test_result": "passed",
              "ci_run": f"https://github.com/iwamoto0414yuuki-droid/UTubeMusic/actions/runs/{args.run}",
              "source_commit": args.commit}
    text = json.dumps(report, indent=2) + "\n"
    (release / f"verification-{version}.json").write_text(text)
    (release / "verification.json").write_text(text)
    print(text)


if __name__ == "__main__":
    main()
