#!/usr/bin/env python3
"""Run Assistant's Decision protocols against matching synthetic language cases."""
import argparse
from collections import Counter
import json
import math
import os
from pathlib import Path
import runpy
import subprocess
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
CLOUD = ("qwen3.7-flash", "qwen3.8-flash")
MATRIX = {
    "d3-edge": ("jev",),
    "d3-lite": ("jev",),
    "apple-system": ("text",),
    "gemma4-e2b": ("tool", "text"),
    **{model: ("tool", "text") for model in CLOUD},
}


def summarize(rows, budget):
    valid = [row for row in rows if "prediction" in row]
    elapsed = sorted(row["elapsedMS"] for row in valid)
    correct = [row for row in valid if row["prediction"] == row["expected"]]
    return {
        "count": len(rows),
        "valid": len(valid),
        "correct": len(correct),
        "p95ValidMS": elapsed[math.ceil(len(elapsed) * .95) - 1] if elapsed else None,
        "correctWithinBudget": sum(row["elapsedMS"] <= budget for row in correct),
        "correctWithin500MS": sum(row["elapsedMS"] <= 500 for row in correct),
        "budgetMS": budget,
        "falseInterrupt": sum(row["prediction"] == "interrupt" and row["expected"] != "interrupt" for row in valid),
        "falseDiscard": sum(row["prediction"] == "discard" and row["expected"] != "discard" for row in valid),
        "missedInterrupt": sum(row["expected"] == "interrupt" and row.get("prediction") != "interrupt" for row in rows),
        "failures": dict(Counter(row["error"] for row in rows if "error" in row)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("models", choices=MATRIX, nargs="+")
    parser.add_argument("--mode", choices=("jev", "tool", "text"))
    parser.add_argument("--limit", type=int, choices=range(1, 28), default=27)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env.local")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    if args.output.exists() or len(args.models) != len(set(args.models)):
        parser.error("Use a new output path and distinct model IDs")
    if args.mode and any(args.mode not in MATRIX[m] for m in args.models):
        parser.error("Selected protocol is unavailable for one of the models")
    environment = {k: v for k, v in os.environ.items() if not k.startswith("MH_DECISION_")}
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    cloud_env = {}
    if any(model in CLOUD for model in args.models):
        load = runpy.run_path(str(ROOT / "scripts/evaluate-qwen.py"))["read_aliyun_env"]
        try:
            config = load(args.env_file)
            if urlsplit(config["ALIYUN_API_URL"]).scheme != "https":
                raise ValueError
        except (ValueError, OSError, KeyError):
            parser.error("The provider settings file must define an HTTPS Aliyun endpoint and an API key")
        cloud_env = {"MH_DECISION_CLOUD_KEY": config["ALIYUN_API_KEY"], "MH_DECISION_CLOUD_URL": config["ALIYUN_API_URL"]}
    if not args.skip_build:
        subprocess.run(["swift", "test", "--filter", "decisionModeCapability"], cwd=ROOT, env=environment, check=True)
    binary_root = Path(subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=ROOT, env=environment, text=True).strip())
    developer = Path(environment["DEVELOPER_DIR"])
    helper = developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    binary = binary_root / "IntegrationTests.xctest/Contents/MacOS/IntegrationTests"
    platform = developer / "Platforms/MacOSX.platform/Developer"
    environment["DYLD_FRAMEWORK_PATH"] = str(platform / "Library/Frameworks")
    environment["DYLD_LIBRARY_PATH"] = ":".join([
        str(platform / "usr/lib"), str(developer / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"),
    ])
    command = [
        str(helper), "--test-bundle-path", str(binary), "--filter", "decisionProtocolBenchmark",
        str(binary), "--testing-library", "swift-testing",
    ]
    report = {"fixture": "docs/measurements/decision-language-scenarios-2026-11-14.json", "results": []}
    with args.output.open("x") as output:
        json.dump(report, output)
    failed = False
    for model in args.models:
        for mode in ((args.mode,) if args.mode else MATRIX[model]):
            print(f"Running {model} {mode}", flush=True)
            result = {"model": model, "mode": mode, "segments": [], "summary": {}}
            report["results"].append(result)
            all_rows = []
            budget = 2000 if model in CLOUD else 250 if mode == "jev" else 500
            for language in ("en", "zh-Hans"):
                size = 14 if model == "gemma4-e2b" else args.limit
                language_rows = []
                for offset in range(0, args.limit, size):
                    path = args.output.with_name(f"{args.output.stem}-{model}-{mode}-{language}-{offset}.json")
                    limit = min(size, args.limit - offset)
                    child = dict(
                        environment, **(cloud_env if model in CLOUD else {}), MH_DECISION_REPORT=str(path.resolve()),
                        MH_DECISION_MODEL=model, MH_DECISION_MODE=mode, MH_DECISION_LANGUAGE=language,
                        MH_DECISION_LIMIT=str(limit), MH_DECISION_OFFSET=str(offset),
                    )
                    with path.with_suffix(".log").open("x") as log:
                        try:
                            process = subprocess.run(
                                command, cwd=ROOT, env=child, stdout=log, stderr=subprocess.STDOUT, timeout=420,
                            )
                            exit_code = process.returncode
                        except subprocess.TimeoutExpired:
                            exit_code = 124
                    raw = path.read_text() if path.exists() else "{}"
                    if model in CLOUD and any(value in raw for value in cloud_env.values()):
                        raise ValueError("Protected provider configuration was found in the benchmark output")
                    data = json.loads(raw)
                    rows = data.get("rows", [])
                    if exit_code or len(rows) != limit:
                        failed = True
                    language_rows.extend(rows)
                    result["segments"].append({
                        "language": language, "offset": offset, "exitCode": exit_code,
                        "warmup": data.get("warmup", []), "rows": rows,
                    })
                result["summary"][language] = summarize(language_rows, budget)
                all_rows.extend(language_rows)
            result["summary"]["all"] = summarize(all_rows, budget)
            args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
