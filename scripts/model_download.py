"""Provision development models from the shared source catalog or separate Mac/test profiles."""
import argparse
import concurrent.futures
import json
import hashlib
import tempfile
import zipfile
import stat
import fnmatch
from urllib.parse import quote, urlsplit, urlunsplit
from urllib.request import urlopen
from pathlib import Path
import subprocess

MODELS = Path(__file__).resolve().parents[1] / "MobileHarness/Resources/Models"


def file_hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

PRODUCTION = {"nemotron": "nemotron", "silero": "silero", "moss-tts-nano": "moss-tts-nano", "qwen3.5-2b": "qwen35", "yolo26-pose": "yolo26n-pose"}


def load_config(profile, platform=None):
    if platform not in (None, "ios", "macos") or (platform == "macos" and profile != "nemotron"):
        raise ValueError("Unsupported platform")
    if profile not in PRODUCTION:
        return json.loads((MODELS / (profile + ".download.json")).read_text())
    catalog = json.loads((MODELS / "model-catalog.json").read_text())
    if catalog["schemaVersion"] != 2:
        raise ValueError("Unsupported model catalog")
    model = next(p for p in catalog["packages"] if p["id"] == PRODUCTION[profile])
    return {"directory": model["directory"], "declaration": model["source"], "requiredFiles": model["requiredFiles"]}


def tree_page(url):
    with urlopen(url, timeout=30) as response:
        data = response.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError("Oversized Hub tree response")
        # Hub pages use standard Link headers.
        following = None
        for link in response.headers.get("Link", "").split(","):
            if 'rel="next"' in link:
                following = link.split("<", 1)[1].split(">", 1)[0]
        return json.loads(data), following


def resolve_hub(config, endpoint, read_page=tree_page):
    source = config["declaration"]
    base = endpoint.rstrip("/")
    repo = source["repoId"]
    revision = source.get("revision", "main")
    url = base + "/api/models/" + repo + "/tree/" + quote(revision, safe="") + "?recursive=true&limit=1000"
    entries, pages = [], set()
    while url:
        if url in pages or len(pages) >= 32 or urlsplit(url).netloc != urlsplit(base).netloc or urlsplit(url).scheme != "https":
            raise ValueError("Invalid Hub pagination")
        pages.add(url)
        page, url = read_page(url)
        entries.extend(page)
        if len(entries) > 16384:
            raise ValueError("Oversized Hub repository")
    files, hashes, sizes, urls = [], {}, {}, {}
    prefix = source.get("stripPrefix", "")
    for entry in entries:
        remote = entry["path"]
        if entry.get("type") != "file" or not any(fnmatch.fnmatchcase(remote, p) for p in source["allowPatterns"]):
            continue
        if prefix and not remote.startswith(prefix + "/"):
            raise ValueError("Selection outside stripPrefix")
        local = remote[len(prefix) + 1:] if prefix else remote
        if Path(local).is_absolute() or ".." in Path(local).parts or "\\" in local or local in files:
            raise ValueError("Unsafe or duplicate Hub path")
        files.append(local)
        if len(files) > 4096:
            raise ValueError("Too many selected Hub files")
        size = entry.get("lfs", {}).get("size", entry.get("size"))
        if size is not None:
            if not isinstance(size, int) or size < 0:
                raise ValueError("Invalid Hub file size")
            sizes[local] = size
        digest = entry.get("lfs", {}).get("oid", "")
        if len(digest) == 64 and all(c in "0123456789abcdef" for c in digest):
            hashes[local] = digest
        urls[local] = base + "/" + repo + "/resolve/" + quote(revision, safe="") + "/" + quote(remote, safe="/")
    if not set(config["requiredFiles"]).issubset(files):
        raise ValueError("Hub snapshot is missing required files")
    return {**config, "source": base + "/" + repo, "revision": revision, "files": files, "sha256": hashes, "fileSizes": sizes, "fileURLs": urls}


def main(profile, variants=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="Replace existing files")
    parser.add_argument("--platform", help="ios or macos (Nemotron uses the same Core ML catalog)")
    if variants:
        parser.add_argument("--size", choices=variants, default="2b")
    parser.add_argument("--endpoint", default="https://huggingface.co", help="HTTPS Hugging Face download domain")
    args = parser.parse_args()
    if variants:
        profile = variants[args.size]
    endpoint = urlsplit(args.endpoint if "://" in args.endpoint else "https://" + args.endpoint)
    if endpoint.scheme != "https" or not endpoint.hostname or endpoint.path not in ("", "/") or endpoint.username or endpoint.password or endpoint.query or endpoint.fragment:
        parser.error("Endpoint must be an HTTPS domain without credentials/path/query")
    def resolve(url):
        source = urlsplit(url)
        return urlunsplit(("https", endpoint.netloc, source.path, source.query, source.fragment)) if source.hostname == "huggingface.co" else url
    try:
        config = load_config(profile, args.platform)
    except ValueError as error:
        parser.error(str(error))
    if "declaration" in config:
        source = config["declaration"]
        if source["kind"] == "huggingface":
            config = resolve_hub(config, "https://" + endpoint.netloc)
        else:
            config["archive"] = {"url": source["url"], "sha256": source.get("sha256")}
    files, suffix = config.get("files", []), ""
    destination = MODELS / (config["directory"] + suffix)

    if "archive" in config:
        fetch_archive(config, destination, args.force)
        print(destination)
        return

    def fetch(relative):
        target = destination / relative
        if not target.resolve().is_relative_to(destination.resolve()):
            raise ValueError("Download path escapes model directory")
        expected_hash = config.get("sha256", {}).get(relative)
        if target.is_file() and not args.force:
            size_matches = relative not in config.get("fileSizes", {}) or target.stat().st_size == config["fileSizes"][relative]
            if size_matches and (not expected_hash or file_hash(target) == expected_hash):
                return
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + ".partial")
        remote = (config.get("remotePrefix", "") + "/" if config.get("remotePrefix") else "") + relative
        url = config.get("fileURLs", {}).get(relative) or config["source"] + "/resolve/" + config["revision"] + "/" + remote
        subprocess.run(["curl", "-fL", "--retry", "3", "--connect-timeout", "30", resolve(url), "-o", str(partial)], check=True)
        if expected_hash and file_hash(partial) != expected_hash:
            partial.unlink(missing_ok=True)
            raise ValueError("Model file SHA-256 mismatch")
        if relative in config.get("fileSizes", {}) and partial.stat().st_size != config["fileSizes"][relative]:
            partial.unlink(missing_ok=True)
            raise ValueError("Model file size mismatch")
        partial.replace(target)
        print("downloaded", relative, flush=True)

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        list(executor.map(fetch, files))
    print(destination)


def install_archive(config, archive, destination):
    """Verify a pinned single-package ZIP before changing the installed model."""
    archive = Path(archive)
    if archive.stat().st_size > 64 * 1024 * 1024 or (config["archive"].get("size") is not None and archive.stat().st_size != config["archive"]["size"]) or (config["archive"].get("sha256") and file_hash(archive) != config["archive"]["sha256"]):
        raise ValueError("Model archive size/SHA-256 mismatch")
    expected = set(config["files"]) if "files" in config else None
    required = set(config.get("requiredFiles", []))
    roots = {Path(name).parts[0] for name in (expected or required)}
    if len(roots) != 1 or not next(iter(roots)).endswith(".mlpackage"):
        raise ValueError("Archive profile must describe one mlpackage")
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination, prefix=".model-stage-") as temporary:
        staging = Path(temporary)
        with zipfile.ZipFile(archive) as package:
            entries = [item for item in package.infolist() if not item.is_dir()]
            if len(entries) > 4096 or (expected is not None and (len(entries) != len(expected) or {item.filename for item in entries} != expected)) or not required.issubset({item.filename for item in entries}):
                raise ValueError("Unexpected archive members")
            if sum(item.file_size for item in entries) > 256 * 1024 * 1024:
                raise ValueError("Oversized model archive")
            seen = set()
            for item in entries:
                target = staging / item.filename
                if not target.resolve().is_relative_to(staging.resolve()) or stat.S_ISLNK(item.external_attr >> 16) or ".." in Path(item.filename).parts or "\\" in item.filename or item.filename in seen or Path(item.filename).parts[0] not in roots:
                    raise ValueError("Unsafe archive member")
                if item.file_size > 64 * 1024 * 1024:
                    raise ValueError("Oversized model member")
                seen.add(item.filename)
                data = package.read(item)
                if config.get("sha256", {}).get(item.filename) and hashlib.sha256(data).hexdigest() != config["sha256"][item.filename]:
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
    if not force and all((destination / name).is_file() and (not config.get("sha256", {}).get(name) or file_hash(destination / name) == config["sha256"][name]) for name in config.get("files", config.get("requiredFiles", []))):
        return
    with tempfile.TemporaryDirectory(prefix="model-download-") as temporary:
        archive = Path(temporary) / "model.zip"
        subprocess.run(["curl", "-fL", "--retry", "3", "--connect-timeout", "30", config["archive"]["url"], "-o", str(archive)], check=True)
        install_archive(config, archive, destination)
