"""Fetch pinned upstream runtime, install pure Python wheels, create icon. macOS build preparation."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# GitHub’s direct release download currently returns 504. Fetch the same pinned asset through the official API.
RUNTIME_ASSET = "https://api.github.com/repos/beeware/Python-Apple-support/releases/assets/445537030"
SHA256 = "8b5cb76ef8d8a2946052479358eeec9d54b4496cb60920e175ec1489b5cf7963"


def fetch_runtime(path, token):
    request = urllib.request.Request(f"{RUNTIME_ASSET}?request={time.time_ns()}",
                                     headers={"Accept": "application/octet-stream", "User-Agent": "UTubeMusic-build"})
    if token:
        # urllib omits unredirected headers from the signed storage request.
        request.add_unredirected_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=60) as response, path.open("wb") as target:
        shutil.copyfileobj(response, target)


def main():
    vendor = ROOT / "vendor"
    vendor.mkdir(exist_ok=True)
    archive = vendor / "Python-3.13-iOS-support.b14.tar.gz"
    if not archive.exists():
        # Request a fresh signed redirect and keep partial downloads out of the cache.
        partial = archive.with_suffix(".partial")
        token = os.environ.get("UTM_RUNTIME_TOKEN")
        try:
            try:
                fetch_runtime(partial, token)
            except urllib.error.HTTPError as error:
                if not token or error.code not in (401, 403, 404):
                    raise
                fetch_runtime(partial, None)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != SHA256:
                raise RuntimeError("Python runtime hash mismatch; stop without extracting")
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise RuntimeError("Python runtime hash mismatch; stop without extracting")
    if not (vendor / "Python.xcframework").is_dir():
        with tarfile.open(archive) as tar:
            tar.extractall(vendor, filter="data")
    packages = vendor / "packages"
    if packages.exists():
        shutil.rmtree(packages)  # fixed, project-owned generated dependency directory
    subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--require-hashes",
                    "--only-binary=:all:", "--platform", "any", "--no-deps", "--target", str(packages),
                    "-r", str(ROOT / "Python/requirements.lock")], check=True)
    notices = ["UTube Music third-party software notices", "\nPython runtime: Python Software Foundation License; bundled license follows.\n"]
    for path in sorted(vendor.glob("Python.xcframework/lib/python3.13/LICENSE*")):
        notices.append(path.read_text(errors="replace"))
    notices.append((ROOT / "THIRD_PARTY_BASE.txt").read_text(encoding="utf-8"))
    for dist in sorted(packages.glob("*.dist-info")):
        notices.append("\n\n=== " + dist.name + " ===\n")
        for path in sorted(dist.rglob("*")):
            if path.is_file() and any(term in path.name.lower() for term in ("license", "copying", "notice")):
                notices.append(path.read_text(errors="replace"))
    # Runtime distribution includes PSF and bundled OpenSSL/libffi/etc notices; preserve them all.
    for path in sorted(vendor.glob("**/LICENSE*")):
        if "packages" not in path.parts and path.is_file():
            text = path.read_text(errors="replace")
            if text not in notices:
                notices.append("\n=== " + str(path.relative_to(vendor)) + " ===\n" + text)
    (vendor / "ThirdPartyNotices.txt").write_text("\n".join(notices), encoding="utf-8")
    from make_icon import create_icon
    create_icon(ROOT / "Sources/Assets.xcassets/AppIcon.appiconset")
    print("Pinned runtime and pure Python dependencies ready")


if __name__ == "__main__":
    main()
