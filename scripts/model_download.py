"""Development-only model provisioning. Runtime loads local files directly."""
import argparse
import concurrent.futures
import json
import hashlib
import tempfile
import zipfile
import stat
from pathlib import Path
import subprocess

MODELS = Path(__file__).resolve().parents[1] / "MobileHarness/Resources/Models"


def main(profile, variants=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="Replace existing files")
    parser.add_argument("--platform", help="Optional platform export from the download profile")
    if variants:
        parser.add_argument("--size", choices=variants, default="2b")
    args = parser.parse_args()
    if variants:
        profile = variants[args.size]
    config = json.loads((MODELS / (profile + ".download.json")).read_text())
    platform = args.platform or config.get("defaultPlatform")
    if "platforms" in config:
        if platform not in config["platforms"]:
            parser.error("Unsupported platform: " + str(platform))
        files = config["platforms"][platform]
        suffix = "" if platform == config["defaultPlatform"] else "-" + platform
    else:
        if platform:
            parser.error("This profile has no platform variants")
        files, suffix = config["files"], ""
    destination = MODELS / (config["directory"] + suffix)

    if "archive" in config:
        fetch_archive(config, destination, args.force)
        print(destination)
        return

    def fetch(relative):
        target = destination / relative
        if not target.resolve().is_relative_to(destination.resolve()):
            raise ValueError("Download path escapes model directory")
        if target.is_file() and not args.force:
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + ".partial")
        remote = (platform + "/" if platform else "") + relative
        url = config["source"] + "/resolve/" + config["revision"] + "/" + remote
        subprocess.run(["curl", "-fL", "--retry", "3", "--connect-timeout", "30", url, "-o", str(partial)], check=True)
        partial.replace(target)
        print("downloaded", relative, flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(fetch, files))
    print(destination)


def install_archive(config, archive, destination):
    """Verify a pinned single-package ZIP before changing the installed model."""
    archive = Path(archive)
    if archive.stat().st_size != config["archive"]["size"] or hashlib.sha256(archive.read_bytes()).hexdigest() != config["archive"]["sha256"]:
        raise ValueError("Model archive size/SHA-256 mismatch")
    expected = set(config["files"])
    roots = {Path(name).parts[0] for name in expected}
    if len(roots) != 1 or not next(iter(roots)).endswith(".mlpackage"):
        raise ValueError("Archive profile must describe one mlpackage")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination, prefix=".model-stage-") as temporary:
        staging = Path(temporary)
        with zipfile.ZipFile(archive) as package:
            entries = [item for item in package.infolist() if not item.is_dir()]
            if len(entries) != len(expected) or {item.filename for item in entries} != expected:
                raise ValueError("Unexpected archive members")
            for item in entries:
                target = staging / item.filename
                if not target.resolve().is_relative_to(staging.resolve()) or stat.S_ISLNK(item.external_attr >> 16):
                    raise ValueError("Unsafe archive member")
                if item.file_size > 64 * 1024 * 1024:
                    raise ValueError("Oversized model member")
                data = package.read(item)
                if hashlib.sha256(data).hexdigest() != config["sha256"][item.filename]:
                    raise ValueError("Model member SHA-256 mismatch")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
        name = next(iter(roots))
        installed = destination / name
        backup = staging / "previous.mlpackage"
        if installed.exists():
            installed.rename(backup)
        try:
            (staging / name).rename(installed)
        except BaseException:
            if backup.exists():
                backup.rename(installed)
            raise


def fetch_archive(config, destination, force):
    if not force and all((destination / name).is_file() and hashlib.sha256((destination / name).read_bytes()).hexdigest() == config["sha256"][name] for name in config["files"]):
        return
    with tempfile.TemporaryDirectory(prefix="model-download-") as temporary:
        archive = Path(temporary) / "model.zip"
        subprocess.run(["curl", "-fL", "--retry", "3", "--connect-timeout", "30", config["archive"]["url"], "-o", str(archive)], check=True)
        install_archive(config, archive, destination)
