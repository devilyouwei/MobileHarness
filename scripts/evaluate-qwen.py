#!/usr/bin/env python3
"""Opt-in, bounded Qwen / GPT-4.1 prompt regression through the production Swift Agent/Gateway."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


def read_provider_env(path, allowed):
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.fullmatch(r"(?:export\s+)?([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(.*)", line)
        if not match or match[1] not in allowed:
            continue
        value = match[2].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[match[1]] = value
    return values


def model_credentials(path, model):
    if model == "gpt-4.1":
        values = read_provider_env(path, {"OPENAI_API_KEY", "OPENAI_API_URL", "OPENAI_BASE_URL"})
        if not values.get("OPENAI_API_KEY"):
            raise ValueError("ENV must define OPENAI_API_KEY")
        return {"MH_QWEN_EVAL_API_KEY": values["OPENAI_API_KEY"],
                "MH_QWEN_EVAL_API_URL": values.get("OPENAI_API_URL") or values.get("OPENAI_BASE_URL") or "https://api.openai.com/v1"}
    values = read_aliyun_env(path)
    return {"MH_QWEN_EVAL_API_KEY": values["ALIYUN_API_KEY"],
            "MH_QWEN_EVAL_API_URL": values["ALIYUN_API_URL"]}


def read_aliyun_env(path):
    values = read_provider_env(path, {"ALIYUN_API_URL", "ALIYUN_API_KEY"})
    if not all(values.get(key) for key in ("ALIYUN_API_URL", "ALIYUN_API_KEY")):
        raise ValueError("ENV must define ALIYUN_API_URL and ALIYUN_API_KEY")
    return values


def source_hashes():
    paths = list((ROOT / "MobileHarness/Resources").rglob("*.json"))
    paths += list((ROOT / "MobileHarness/Resources").rglob("*.md"))
    paths += [ROOT / relative for relative in (
        "MobileHarness/Agents/Assistant/AssistantProcessing.swift",
        "MobileHarness/Agents/Assistant/AssistantChatWorker.swift",
        "Tests/IntegrationTests/QwenWorkflowEvaluationTests.swift",
        "Tests/AgentModelEvaluationTests/Scenarios/qwen-workflows.json",
    )]
    for directory in ("Agents", "Actions", "UI", "ModelKit/Language/LLM/OpenAI"):
        paths += list((ROOT / "MobileHarness" / directory).rglob("*.swift"))
    paths += [ROOT / "Tests/IntegrationTests/FixedTextChat.swift", Path(__file__).resolve()]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(paths)}


def selected_ids(cases, selection):
    known = {case["id"] for case in cases}
    selected = known if selection is None else set(selection.split(","))
    if not selected or not selected.issubset(known):
        raise ValueError("Unknown or empty workflow selection")
    return selected


def compact_case(case):
    result = {key: value for key, value in case.items() if key != "archive"}
    result["passed"] = not case["runtimeIssues"] and all(not t["issues"] for t in case["turns"])
    turns = case["archive"]["current"]["turns"]
    evidence = []
    for turn in turns:
        requests = []
        for request in turn.get("modelRequests", []):
            item = dict(request)
            raw = item.pop("requestJSON")
            item["requestSHA256"] = hashlib.sha256(raw.encode()).hexdigest()
            item["requestBytes"] = len(raw.encode())
            # Actual current facts and ordering remain reviewable without repeating static teaching.
            parsed = json.loads(raw)
            messages = parsed if isinstance(parsed, list) else parsed.get("messages", [])
            item["stateMessages"] = [m for m in messages if m.get("role") == "system"
                                     and "# CURRENT STATE" in m.get("content", "")]
            requests.append(item)
        evidence.append({"user": turn["user"], "state": turn["state"],
                         "error": turn.get("error"), "modelRequests": requests,
                         "generationRounds": turn.get("generationRounds", [])})
    result["evidence"] = evidence
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env.local")
    parser.add_argument("--models", nargs="+", default=["gpt-4.1", "qwen3.8-flash", "qwen3.8-max"])
    parser.add_argument("--robot-only", action="store_true", help="Run all robot-prefixed scenarios")
    parser.add_argument("--cases", help="Comma-separated workflow IDs; omitted runs the complete suite")
    parser.add_argument("--output-prefix", type=Path, default=Path("/tmp/qwen-workflow-regression"))
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--parallel", type=int, choices=(1, 2, 3, 4), default=3)
    args = parser.parse_args()
    if len(args.models) > 4 or len(set(args.models)) != len(args.models):
        parser.error("Choose at most four distinct model IDs")
    if any(m != "gpt-4.1" and not re.fullmatch(r"qwen[a-zA-Z0-9.-]+", m) for m in args.models):
        parser.error("Use exact Qwen model IDs or gpt-4.1")
    fixture_path = ROOT / "Tests/AgentModelEvaluationTests/Scenarios/qwen-workflows.json"
    cases = json.loads(fixture_path.read_text())["cases"]
    if args.robot_only:
        if args.cases:
            parser.error("Choose --robot-only or --cases")
        args.cases = ",".join(case["id"] for case in cases if case["id"].startswith("robot-"))
    expected = selected_ids(cases, args.cases)
    for model in args.models:
        raw_path = Path(str(args.output_prefix) + "-" + model + ".json")
        if raw_path.exists() or raw_path.with_suffix(".log").exists():
            raise ValueError("Output already exists; use a fresh output prefix")
    credentials = {model: model_credentials(args.env_file, model) for model in args.models}
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("MH_QWEN_EVAL", "OPENAI_", "ALIYUN_", "DASHSCOPE_"))}
    environment.pop("OPENAI_API_KEY", None)
    environment.pop("MH_QWEN_EVAL", None)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
    hashes = source_hashes()
    if not args.skip_build:
        built = subprocess.run(
            ["swift", "test", "--filter", "qwenWorkflowCasesAreBoundedAndUseRegisteredAliases"],
            cwd=ROOT, env=environment)
        if built.returncode:
            return built.returncode
    developer = Path(environment["DEVELOPER_DIR"])
    helper = developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    binary_root = subprocess.check_output(
        ["swift", "build", "--show-bin-path"], cwd=ROOT, env=environment, text=True).strip()
    bundle = Path(binary_root) / "IntegrationTests.xctest/Contents/MacOS/IntegrationTests"
    if not helper.is_file() or not bundle.is_file():
        raise ValueError("Full Xcode and a built IntegrationTests bundle are required")
    platform = developer / "Platforms/MacOSX.platform/Developer"
    environment["DYLD_FRAMEWORK_PATH"] = str(platform / "Library/Frameworks")
    environment["DYLD_LIBRARY_PATH"] = ":".join([
        str(platform / "usr/lib"),
        str(developer / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"),
    ])

    def run(model):
        raw_path = Path(str(args.output_prefix) + "-" + model + ".json")
        log_path = raw_path.with_suffix(".log")
        if raw_path.exists() or log_path.exists():
            raise ValueError("Output already exists; use a fresh output prefix")
        child_env = dict(environment, **credentials[model], MH_QWEN_EVAL="1",
                         MH_QWEN_EVAL_MODEL=model, MH_QWEN_EVAL_OUTPUT=str(raw_path))
        if args.cases:
            child_env["MH_QWEN_EVAL_CASES"] = args.cases
        print(f"START {model}", flush=True)
        with log_path.open("w") as output:
            process = subprocess.run(
                [str(helper), "--test-bundle-path", str(bundle), "--filter",
                 "qwenActionToolWorkflowRegression", str(bundle), "--testing-library", "swift-testing"],
                cwd=ROOT, env=child_env, stdout=output, stderr=subprocess.STDOUT)
        if not raw_path.exists():
            return {"model": model, "exitCode": process.returncode, "error": "No completed report",
                    "log": str(log_path)}
        raw = json.loads(raw_path.read_text())
        cases = [compact_case(case) for case in raw["cases"]]
        passed = sum(case["passed"] for case in cases)
        result = {"model": model, "exitCode": process.returncode, "passed": passed,
                  "total": len(cases), "expectedTotal": len(expected),
                  "complete": {case["id"] for case in cases} == expected,
                  "cases": cases, "rawEvidence": str(raw_path), "log": str(log_path)}
        print(f"DONE {model}: {passed}/{len(cases)}", flush=True)
        return result

    with ThreadPoolExecutor(max_workers=args.parallel) as executor:
        results = list(executor.map(run, args.models))
    report = {"version": 1, "createdAt": datetime.now(timezone.utc).isoformat(),
              "models": args.models, "filter": args.cases, "sourceHashes": hashes,
              "sourceUnchanged": source_hashes() == hashes,
              "scope": "Real Qwen / OpenAI Responses, production Agent/Gateway, synthetic device/storage executors",
              "results": results}
    path = Path(str(args.output_prefix) + ".summary.json")
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"REPORT {path}", flush=True)
    return int(not report["sourceUnchanged"] or any(r["exitCode"] or not r.get("complete") for r in results))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, json.JSONDecodeError) as error:
        # Do not include config values or exception bodies from network/key handling.
        print(f"Evaluation setup failed ({type(error).__name__}); inspect paths and safe configuration.",
              file=sys.stderr)
        sys.exit(2)
