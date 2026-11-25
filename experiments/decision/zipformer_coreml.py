"""Fetch and run the pinned Hugging Mac Zipformer Core ML release."""

import hashlib
import json
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from types import ModuleType
from urllib.request import urlopen

SPEC_PATH = Path(__file__).with_name("zipformer-coreml-model.json")
MODEL_ROOT = Path(__file__).resolve().parents[2] / "Models" / "ZipformerKWS"
RATE = 16000


def matches(path, entry):
    if not path.is_file() or path.stat().st_size != entry["bytes"]:
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest() == entry["sha256"]


def checked_path(root, name):
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Unsafe Core ML artifact path: {name}")
    path = root / relative
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError(f"Unexpected symlink in Core ML artifact path: {part}")
        if part == root:
            break
    return path


def download_file(url, path, entry):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        staged = Path(temporary.name)
    try:
        with urlopen(url, timeout=60) as response, staged.open("wb") as destination:
            remaining = entry["bytes"]
            while remaining:
                data = response.read(min(remaining, 1024 * 1024))
                if not data:
                    break
                destination.write(data)
                remaining -= len(data)
            if remaining or response.read(1):
                raise ValueError(f"Unexpected size for {url}")
        if not matches(staged, entry):
            raise ValueError(f"SHA-256 mismatch for {url}")
        staged.replace(path)
    finally:
        staged.unlink(missing_ok=True)


def prepare_release(spec, local_root=None):
    root = local_root or MODEL_ROOT / spec["revision"]
    base = f"https://huggingface.co/{spec['repository']}/resolve/{spec['revision']}"
    missing = []
    for name, entry in spec["files"].items():
        path = checked_path(root, name)
        if not matches(path, entry):
            if local_root is not None:
                raise ValueError(f"Invalid pinned Core ML file in --models directory: {path}")
            missing.append((f"{base}/{name}", path, entry))
    if missing:
        with ThreadPoolExecutor(max_workers=4) as executor:
            pending = [executor.submit(download_file, *item) for item in missing]
            for download in pending:
                download.result()
    return root


def load_host(root, spec):
    name = "_hugging_mac_zipformer_" + spec["revision"]
    path = root / "spotter.py"
    data = path.read_bytes()
    if hashlib.sha256(data).hexdigest() != spec["files"]["spotter.py"]["sha256"]:
        raise ValueError("Published Zipformer host SHA-256 mismatch")
    host = ModuleType(name)
    host.__file__ = str(path)
    # The published dataclasses look up their defining module at execution time.
    previous = sys.modules.get(name)
    sys.modules[name] = host
    try:
        exec(compile(data, str(path), "exec"), host.__dict__)
    finally:
        if previous is None:
            del sys.modules[name]
        else:
            sys.modules[name] = previous
    return host


class CoreMLReplay:
    def __init__(self, root, spec, keyword_file, compute_unit, blanks):
        self.host = load_host(root, spec)
        self.manifest = json.loads((root / "manifest.json").read_text())
        self.keywords = self.host.read_keywords(keyword_file, root / "tokens.txt")
        self.predict = self.host.CoreML(root, self.manifest["graphs"], compute_unit)
        self.blanks = blanks

    def replay(self, audio, offset_ms, trailer_ms, step):
        import numpy as np

        samples = np.pad(audio, (RATE * offset_ms // 1000, RATE * trailer_ms // 1000))
        stream = self.host.Stream(self.predict, self.manifest, self.keywords, self.blanks)
        timings, hits = [], []
        for start in range(0, len(samples), step):
            stop = min(start + step, len(samples))
            frame = stream.frame
            began = time.perf_counter_ns()
            detected = stream.accept(samples[start:stop])
            if stream.frame != frame:
                timings.append((time.perf_counter_ns() - began) / 1e6)
            for match in detected:
                hits.append({
                    "keyword": match.label,
                    "tokenTimesSeconds": [index * self.host.FRAME_SECONDS for index in match.frames],
                    "inputFedMS": 1000 * stop / RATE,
                })
        return hits, timings
