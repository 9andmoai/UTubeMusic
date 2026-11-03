"""Reviewable source-only ZIP. Explicit allowlist; never includes local media or credentials."""
from pathlib import Path
import hashlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = {"Sources", "Python", "Tests", "tests_python", "scripts", "design", ".github"}
ROOT_FILES = {".gitignore", ".gitattributes", "project.yml", "README.md", "INSTALL_IPHONE.md", "LICENSE", "THIRD_PARTY_BASE.txt", "CLEANUP_REVIEW.md"}
EXTENSIONS = {".swift", ".m", ".h", ".py", ".yml", ".lock", ".html", ".mjs", ".sh", ".png", ".json", ".md", ".txt"}


def main():
    build = ROOT / "build"
    build.mkdir(exist_ok=True)
    output = build / "UTubeMusic-0.3.6-source.zip"
    paths = []
    candidates = [ROOT / name for name in ROOT_FILES]
    for folder in ALLOWED:
        candidates.extend((ROOT / folder).rglob("*"))
    for path in sorted(candidates):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(ROOT)
        if "__pycache__" in relative.parts:
            continue
        if str(relative) in ROOT_FILES or (relative.parts[0] in ALLOWED and path.suffix in EXTENSIONS):
            assert not any(part in {"vendor", "build", ".git"} for part in relative.parts)
            paths.append(path)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in paths:
            archive.write(path, path.relative_to(ROOT).as_posix())
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".zip.sha256").write_text(digest + "  " + output.name + "\n")
    print(f"{len(paths)} source/design files; {output.stat().st_size} bytes; SHA256 {digest}")


if __name__ == "__main__": main()
