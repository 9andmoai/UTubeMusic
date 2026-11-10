"""Install the matching stdlib slice and package binary modules as Apple frameworks.

Follows CPython's iOS embedding layout; original implementation.
Executed by Xcode after resource copying. SideStore signs the resulting app later.
"""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess


def trim_development_resources(app):
    # CPython's regression suite is not an application dependency. Preserve
    # unittest, runtime modules, package metadata, certificates and all licenses.
    test_suite = app / "python/lib/python3.13/test"
    if test_suite.is_dir():
        if test_suite.is_symlink() or app.resolve() not in test_suite.resolve().parents:
            raise RuntimeError("Refusing to trim resources outside generated app")
        shutil.rmtree(test_suite)


def main():
    root = Path(os.environ["PROJECT_DIR"])
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    app.mkdir(parents=True, exist_ok=True)
    xcframework = root / "vendor/Python.xcframework"
    with (xcframework / "Info.plist").open("rb") as f:
        libraries = plistlib.load(f)["AvailableLibraries"]
    simulator = os.environ.get("EFFECTIVE_PLATFORM_NAME") == "-iphonesimulator"
    identifier = next(x["LibraryIdentifier"] for x in libraries
                      if x["SupportedPlatform"] == "ios"
                      and (x.get("SupportedPlatformVariant") == "simulator") == simulator)
    common = xcframework / "lib"
    arch = os.environ.get("CURRENT_ARCH", "arm64")
    if arch == "undefined_arch":
        arch = os.environ.get("ARCHS", "arm64").split()[0]
    source = xcframework / identifier / ("lib-" + arch)
    if not (common / "python3.13/encodings").is_dir() or not (source / "python3.13/lib-dynload").is_dir():
        raise RuntimeError("Pinned Python runtime stdlib layout changed")
    ignore = shutil.ignore_patterns("__pycache__", "*.pyc")
    shutil.copytree(common, app / "python/lib", dirs_exist_ok=True, ignore=ignore)
    shutil.copytree(source, app / "python/lib", dirs_exist_ok=True, ignore=ignore)
    shutil.copytree(root / "vendor/packages", app / "app", dirs_exist_ok=True, ignore=ignore)
    for module in (root / "Python").glob("*.py"):
        shutil.copy2(module, app / "app" / module.name)
    shutil.copy2(root / "vendor/ThirdPartyNotices.txt", app / "ThirdPartyNotices.txt")
    trim_development_resources(app)
    frameworks = app / "Frameworks"
    frameworks.mkdir(exist_ok=True)
    base = app / "python/lib/python3.13/lib-dynload"
    for binary in base.rglob("*.so"):
        relative = binary.relative_to(base)
        name = str(relative).split(".")[0].replace("/", ".")
        framework = frameworks / (name + ".framework")
        framework.mkdir(exist_ok=True)
        executable = framework / name
        shutil.copy2(binary, executable)
        with (framework / "Info.plist").open("wb") as f:
            plistlib.dump({"CFBundleDevelopmentRegion": "en", "CFBundleExecutable": name,
                          "CFBundleIdentifier": "local.utubemusic.python." + name.replace("_", "-"),
                          "CFBundleInfoDictionaryVersion": "6.0", "CFBundlePackageType": "FMWK",
                          "CFBundleShortVersionString": "3.13", "CFBundleVersion": "1",
                          "MinimumOSVersion": "17.0", "CFBundleSupportedPlatforms": ["iPhoneSimulator" if simulator else "iPhoneOS"]}, f)
        marker = binary.with_suffix(".fwork")
        marker.write_text(executable.relative_to(app).as_posix() + "\n")
        (framework / (name + ".origin")).write_text(marker.relative_to(app).as_posix() + "\n")
        privacy = binary.parent / (name + ".xcprivacy")
        if privacy.is_file():
            shutil.copy2(privacy, framework / "PrivacyInfo.xcprivacy")
        binary.unlink()
        if simulator:
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(framework)], check=True)


if __name__ == "__main__":
    main()
