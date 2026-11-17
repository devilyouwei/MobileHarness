"""Opt-in Vela native-choice evaluation of frozen Decision requests."""
import argparse
import asyncio
import hashlib
import importlib.util
import json
import platform
from pathlib import Path
import time

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent


def digest(path):
    return hashlib.file_digest(path.open("rb"), "sha256").hexdigest()


async def run(args):
    spec = json.loads((HERE / "vela-model.json").read_text())
    root = HERE / ".local/models" / spec["directory"]
    for item in spec["files"]:
        assert digest(root / item["path"]) == item["sha256"], item["path"]
    fixture = json.loads(args.input.read_text())

    def verify():
        for path, expected in fixture["sourceHashes"].items():
            assert digest(REPO / path) == expected, path

    verify()
    module_spec = importlib.util.spec_from_file_location("vela_coreai", root / "vela_coreai.py")
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    report = dict(model="vela3-fast", mode="native-choice-cpu-no-adoption-no-deadline",
                  revision=spec["revision"], inputSHA256=digest(args.input),
                  runnerSHA256=digest(Path(__file__)), sourceHashes=fixture["sourceHashes"],
                  platform=platform.platform(), warmup=[], rows=[], sourcesUnchanged=False)

    def save(first=False):
        with args.output.open("x" if first else "w") as output:
            json.dump(report, output, ensure_ascii=False, indent=2)
            output.write("\n")

    save(True)
    load_start = time.perf_counter()
    async with module.VelaCoreAI.open(root) as model:
        report["loadMilliseconds"] = (time.perf_counter() - load_start) * 1000

        async def measure(item):
            request = item["request"]
            # Same A/B/C/D keys and candidate text as D3; Vela owns its native markers.
            criteria = dict(zip("ABCD", request["candidates"]))
            assert len(criteria) == len(request["actions"])
            question = dict(type="choice", instructions=request["instructions"], criteria=criteria)
            arrays, _ = model.pack(request["text"], question)
            row = dict(variant=item["variant"], **item["scenario"],
                       inputTokens=int(arrays["attention_mask"].sum()))
            start = time.perf_counter()
            try:
                result = await model.predict(request["text"], question)
                index = list(criteria).index(result["choice"])
                row.update(prediction=request["actions"][index],
                           probabilities=result["probabilities"],
                           score=result["probabilities"][result["choice"]])
            except Exception as error:
                row.update(prediction=None, error=f"{type(error).__name__}: {error}")
            row["milliseconds"] = (time.perf_counter() - start) * 1000
            return row

        variants = sorted({item["variant"] for item in fixture["rows"]})
        for variant in variants:
            first = next(item for item in fixture["rows"] if item["variant"] == variant)
            for _ in range(3):
                report["warmup"].append(await measure(first))
                save()
        ids = sorted({item["scenario"]["id"] for item in fixture["rows"]})
        for index, case_id in enumerate(ids):
            for variant in variants[index % len(variants):] + variants[:index % len(variants)]:
                item = next((r for r in fixture["rows"]
                             if r["scenario"]["id"] == case_id and r["variant"] == variant), None)
                if item is not None:
                    report["rows"].append(await measure(item))
                    save()
            if index % 8 == 0:
                print(f"Vela: {len(report['rows'])}/{len(fixture['rows'])}", flush=True)
    verify()
    assert digest(args.input) == report["inputSHA256"]
    report["sourcesUnchanged"] = True
    save()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    asyncio.run(run(parser.parse_args()))
