#!/usr/bin/env python3
"""Opt-in real-provider Writer/Gateway/files/SQLite regression; never prints credentials."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from importlib.util import module_from_spec, spec_from_file_location

ROOT = Path(__file__).resolve().parent.parent


def source_hashes():
    paths = [ROOT / "Tests/IntegrationTests/WriterModelEvaluationTests.swift", Path(__file__).resolve()]
    paths += list((ROOT / "MobileHarness/Resources").rglob("*.json"))
    paths += list((ROOT / "MobileHarness/Resources").rglob("*.md"))
    paths += list((ROOT / "Tests/AgentModelEvaluationTests/Scenarios").glob("writer-*.json"))
    for directory in ("Agents/Writer", "Actions/Artifacts", "ModelKit/Language/LLM/OpenAI", "Storage/Database/WriterWorkspaces", "Storage/Database/WriterMessages"):
        paths += list((ROOT / "MobileHarness" / directory).glob("*.swift"))
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(paths)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env.local")
    parser.add_argument("--models", nargs="+", choices=["qwen3.8-max", "gpt-6.1-sol", "deepseek-v4.1-flash", "deepseek4.1-flash"], default=None)
    parser.add_argument("--thinking", choices=["enabled", "minimum"], default=None, help="Evaluation-only provider thinking; production Agent settings are unchanged")
    parser.add_argument("--matrix", action="store_true", help="Use JSON-owned Writer prompt cases and model configuration")
    parser.add_argument("--cases", help="Comma-separated cases; resume cases require multifile in the same run")
    parser.add_argument("--seconds", type=int, default=600, help="Evaluation-only per-case deadline; not a production/model budget")
    parser.add_argument("--output-prefix", type=Path, default=Path("/tmp/writer-model-regression"))
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--test-binary", type=Path, help="Existing IntegrationTests binary; requires --skip-build, avoids SwiftPM locks")
    args = parser.parse_args()
    if args.test_binary and not args.skip_build:
        parser.error("--test-binary requires --skip-build")
    config = json.loads((ROOT / "Tests/AgentModelEvaluationTests/Scenarios/writer-evaluation.json").read_text())
    if args.models is None:
        args.models = [m["id"] for m in config["models"]] if args.matrix else ["qwen3.8-max"]
    requested_models = args.models[:]
    args.models = ["deepseek-v4.1-flash" if model == "deepseek4.1-flash" else model for model in args.models]
    if requested_models != args.models:
        print("Provider model ID: deepseek4.1-flash -> deepseek-v4.1-flash (verified /models identity)")
    if len(set(args.models)) != len(args.models) or args.seconds < 30:
        parser.error("Distinct models and deadline >=30 seconds required")
    known = {"diagram", "multifile", "partial-resume", "file-operations", "markdown", "javascript-repair"}
    if args.matrix:
        scenario_path = ROOT / config["scenarioFile"]
        scenario_spec = json.loads(scenario_path.read_text())
        known = {case["id"] for case in scenario_spec["cases"]}
    expected = set(args.cases.split(",")) if args.cases else known
    if not expected or not expected <= known or (not args.matrix and expected & {"partial-resume", "file-operations"} and "multifile" not in expected):
        parser.error("Unknown case or missing multifile dependency")
    for model in args.models:
        if Path(str(args.output_prefix) + "-" + model).exists() or Path(str(args.output_prefix) + "-" + model + ".log").exists():
            parser.error("Output exists; choose a fresh prefix")
    spec = spec_from_file_location("qwen_evaluation", ROOT / "scripts/evaluate-qwen.py")
    loader = module_from_spec(spec)
    spec.loader.exec_module(loader)
    credentials = {}
    for model in args.models:
        if model == "gpt-6.1-sol":
            values = loader.read_provider_env(args.env_file, {"OPENAI_API_KEY", "OPENAI_API_URL", "OPENAI_BASE_URL"})
            if not values.get("OPENAI_API_KEY"):
                raise ValueError("OpenAI credential missing")
            credentials[model] = (values["OPENAI_API_KEY"], values.get("OPENAI_API_URL") or values.get("OPENAI_BASE_URL") or "https://api.openai.com/v1")
        else:
            values = loader.read_aliyun_env(args.env_file)
            credentials[model] = (values["ALIYUN_API_KEY"], values["ALIYUN_API_URL"])
    env = {key: value for key, value in os.environ.items() if not key.startswith(("MH_WRITER_EVAL", "OPENAI_", "ALIYUN_", "DASHSCOPE_"))}
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    hashes = source_hashes()
    if not args.skip_build:
        result = subprocess.run(["swift", "test", "--filter", "writerRealModelWorkflowRegression"], cwd=ROOT, env=env)
        if result.returncode:
            return result.returncode
    developer = Path(env["DEVELOPER_DIR"])
    helper = developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    binary = args.test_binary or Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, env=env, text=True).strip()) / "IntegrationTests.xctest/Contents/MacOS/IntegrationTests"
    if not helper.is_file() or not binary.is_file():
        raise ValueError("Built IntegrationTests and full Xcode required")
    platform = developer / "Platforms/MacOSX.platform/Developer"
    env["DYLD_FRAMEWORK_PATH"] = str(platform / "Library/Frameworks")
    env["DYLD_LIBRARY_PATH"] = ":".join([str(platform / "usr/lib"), str(developer / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx")])
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    bundle = binary.parents[3] / "HarnessKit_Agents.bundle" / "Contents/Resources/Agents/Writer"
    if not bundle.is_dir():
        bundle = binary.parents[3] / "HarnessKit_Agents.bundle/Agents/Writer"
    for owner in ("Writer", "Shared"):
        source = ROOT / "MobileHarness/Resources/Agents" / owner
        packaged = bundle.parent / owner
        expected = {path.relative_to(source): path for path in source.rglob("*") if path.is_file()}
        actual = {path.relative_to(packaged): path for path in packaged.rglob("*") if path.is_file()}
        if set(expected) != set(actual) or any(
            expected[path].read_bytes() != actual[path].read_bytes() for path in expected
        ):
            raise ValueError(f"Rebuild required: bundled {owner} resources are stale")
    preflight = subprocess.run([str(helper), "--test-bundle-path", str(binary), "--filter", "writerEvaluationWebKitReloadsLocalResourcesAndChecksClick|writerPromptHostUsesProductionWindowAndRenderingOwners", str(binary), "--testing-library", "swift-testing"], cwd=ROOT, env=dict(env, MH_WRITER_RENDER_EVAL="1"), timeout=60)
    if preflight.returncode:
        return preflight.returncode

    def run(model):
        root = Path(str(args.output_prefix) + "-" + model)
        log = Path(str(root) + ".log")
        setting = next((m for m in config["models"] if m["id"] == model), {})
        thinking = args.thinking or setting.get("thinking", "enabled")
        child = dict(env, MH_WRITER_EVAL="1", MH_WRITER_EVAL_MODEL=model, MH_WRITER_EVAL_THINKING=thinking,
                     MH_WRITER_EVAL_ROOT=str(root), MH_WRITER_EVAL_SECONDS=str(args.seconds),
                     MH_WRITER_EVAL_API_KEY=credentials[model][0],
                     MH_WRITER_EVAL_API_URL=credentials[model][1], NSUnbufferedIO="YES")
        if args.matrix:
            child["MH_WRITER_EVAL_SCENARIOS"] = str(scenario_path)
            child["MH_WRITER_EVAL_REQUEST_LIMIT"] = str(config["requestLimit"])
        if args.cases:
            child["MH_WRITER_EVAL_CASES"] = args.cases
        print(f"START {model}", flush=True)
        with log.open("w") as output:
            try:
                result = subprocess.run([str(helper), "--test-bundle-path", str(binary), "--filter", "writerRealModelWorkflowRegression", str(binary), "--testing-library", "swift-testing"], cwd=ROOT, env=child, stdout=output, stderr=subprocess.STDOUT, timeout=len(expected) * (args.seconds + 60) + 120)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
        report_file = root / "report.json"
        report = json.loads(report_file.read_text()) if report_file.exists() else {"cases": []}
        result = {"model": model, "exitCode": code, "root": str(root), "log": str(log),
                  "complete": {case["id"] for case in report["cases"]} == expected,
                  "passed": sum(case["passed"] for case in report["cases"]), "cases": report["cases"]}
        print(f"DONE {model}: {result['passed']}/{len(expected)} exit={code}", flush=True)
        return result

    with ThreadPoolExecutor(max_workers=len(args.models)) as executor:
        results = list(executor.map(run, args.models))
    report = {"version": 1, "createdAt": datetime.now(timezone.utc).isoformat(), "sourceHashes": hashes,
              "sourceUnchanged": source_hashes() == hashes, "requestedModels": requested_models, "thinkingOverride": args.thinking, "matrix": args.matrix, "configuration": config if args.matrix else None, "binarySHA256": binary_hash, "binaryUnchanged": hashlib.sha256(binary.read_bytes()).hexdigest() == binary_hash, "results": results}
    path = Path(str(args.output_prefix) + ".summary.json")
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"REPORT {path}")
    return int(not report["sourceUnchanged"] or any(result["exitCode"] or not result["complete"] or result["passed"] != len(expected) for result in results))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, json.JSONDecodeError):
        print("Writer evaluation setup failed; inspect paths/configuration (credentials suppressed).", file=sys.stderr)
        sys.exit(2)
