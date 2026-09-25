"""Development-only model provisioning. Runtime loads local files directly."""
import argparse
import concurrent.futures
import json
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
