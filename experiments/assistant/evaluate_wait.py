#!/usr/bin/env python3
"""Opt-in, bounded evaluation of whether a model emits correct wait scope / delay function tokens.

Single-turn requests; each response is parsed with the experiment's own strict parser and replayed on a
simulated main track / channel timeline. Labels stay out of the request."""

import argparse
import asyncio
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from utils.runtime import chat_model, digest, positive, run_cases

ROOT = Path(__file__).resolve().parents[2]
CHANNELS = {"express": "Display", "setExpression": "Display", "startListening": "ListeningControl", "stopListening": "ListeningControl"}
EMOTIONS = {"closed", "smile", "happy", "laugh", "thinking", "surprised", "sad", "love", "angry", "scared", "playful", "clear"}
MAX_WAITS, MAX_DEPTH, MAX_DELAY, MAX_TOTAL_DELAY = 32, 8, 60, 120
TOKEN = re.compile(r"<[^>]*>|[^<]+")
ATTRIBUTE = re.compile(r'\s+([A-Za-z_]\w*)="([^"]*)"')
MODELS = {
    "qwen3.8-max": ("ALIYUN_API_URL", "ALIYUN_API_KEY"),
    "qwen3.8-flash": ("ALIYUN_API_URL", "ALIYUN_API_KEY"),
    "gpt-4.1": (None, "OPENAI_API_KEY"),
}


def read_env(path, keys):
    values = {}
    for line in path.read_text().splitlines():
        match = re.fullmatch(r"(?:export\s+)?([A-Za-z_]\w*)\s*=\s*(.*)", line.strip())
        if match and match[1] in keys:
            value = match[2].strip()
            values[match[1]] = value[1:-1] if len(value) > 1 and value[0] == value[-1] and value[0] in "\"'" else value
    return values


def parse(text):
    """Return events, or raise ValueError for output the production grammar would not accept as calls."""
    if "```" in text:
        raise ValueError("markdownFence")
    events = []
    for token in TOKEN.findall(text):
        if not token.startswith("<"):
            if token.strip():
                events.append(("speech", token.strip()))
            continue
        if token == "<wait>":
            events.append(("begin",))
        elif token == "</wait>":
            events.append(("end",))
        else:
            match = re.fullmatch(r"<([A-Za-z_][\w.]*)((?:\s+[A-Za-z_]\w*=\"[^\"]*\")*)\s*/>", token)
            if not match:
                raise ValueError("malformedTag")
            name, raw = match[1], match[2]
            attributes = dict(ATTRIBUTE.findall(raw))
            if name == "wait":
                if set(attributes) != {"time"}:
                    raise ValueError("waitNeedsOnlyTime")
                events.append(("delay", attributes["time"]))
            elif name in CHANNELS:
                events.append(("action", name, attributes))
            else:
                raise ValueError("unknownAction:" + name)
    return events


def validate(events):
    issues, depth, waits, total = [], 0, 0, 0.0
    for event in events:
        if event[0] == "begin":
            depth += 1; waits += 1
            if depth > MAX_DEPTH:
                issues.append("waitTooDeep")
        elif event[0] == "end":
            depth -= 1
            if depth < 0:
                issues.append("unbalancedWait"); depth = 0
        elif event[0] == "delay":
            waits += 1
            if not re.fullmatch(r"\d{1,8}(\.\d{1,8})?", event[1]) or not 0 < float(event[1]) <= MAX_DELAY:
                issues.append("invalidDelay:" + event[1])
            else:
                total += float(event[1])
        elif event[0] == "action":
            emotion = event[2].get("emotion")
            if event[1] in ("express", "setExpression") and emotion not in EMOTIONS:
                issues.append("invalidEmotion")
            if event[1] == "express" and emotion == "clear":
                issues.append("invalidEmotion")
    if depth:
        issues.append("unbalancedWait")
    if waits > MAX_WAITS:
        issues.append("tooManyWaits")
    if total > MAX_TOTAL_DELAY:
        issues.append("delayBudgetExceeded")
    return issues


def simulate(events, durations):
    """Main-track replay: scopes barrier on parent work at begin and on all inner work at end; delays only move the clock."""
    now, free, leaves = 0.0, {}, []
    groups = [0.0]
    for event in events:
        if event[0] == "begin":
            now = max(now, groups[-1]); groups.append(0.0)
        elif event[0] == "end":
            inner = groups.pop(); now = max(now, inner); groups[-1] = max(groups[-1], inner)
        elif event[0] == "delay":
            now += float(event[1])
        else:
            kind = "speech" if event[0] == "speech" else event[1]
            channel = "Speech" if kind == "speech" else CHANNELS[kind]
            start = max(now, free.get(channel, 0.0)); end = start + durations[kind]
            free[channel] = end; groups[-1] = max(groups[-1], end)
            leaves.append(dict(kind=kind, params=event[2] if kind != "speech" else {}, text=event[1] if kind == "speech" else None, start=start, end=end))
    return leaves


def find(leaves, selector):
    for leaf in leaves:
        if "speech" in selector:
            if leaf["kind"] == "speech" and re.search(selector["speech"], leaf["text"], re.I):
                return leaf
        elif leaf["kind"] in selector["alias"] and all(leaf["params"].get(k) in v for k, v in selector.items() if k != "alias"):
            return leaf


def score(case, text, durations):
    try:
        events = parse(text)
    except ValueError as error:
        return ["parse:" + str(error)], []
    issues = validate(events)
    if issues:
        return issues, events
    leaves = simulate(events, durations)
    if case.get("validityOnly"):
        return issues, events
    if case.get("noWait") and any(e[0] in ("begin", "delay") for e in events):
        issues.append("unnecessaryWait")
    if case.get("noSpeech") and any(e[0] == "speech" for e in events):
        issues.append("unexpectedSpeech")
    if "onlyAliases" in case and any(e[0] == "action" and e[1] not in case["onlyAliases"] for e in events):
        issues.append("unexpectedAction")
    found = {}
    for name, selector in case.get("refs", {}).items():
        found[name] = find(leaves, selector)
        if not found[name]:
            issues.append("missing:" + name)
    def pair(a, b):
        return (found.get(a), found.get(b)) if found.get(a) and found.get(b) else None
    for a, b in case.get("before", []):
        if (p := pair(a, b)) and p[0]["end"] > p[1]["start"] + 1e-6:
            issues.append(f"notBefore:{a}>{b}")
    for a, b in case.get("overlap", []):
        if (p := pair(a, b)) and not (p[0]["start"] < p[1]["end"] and p[1]["start"] < p[0]["end"]):
            issues.append(f"notOverlapping:{a},{b}")
    for key, field_a, field_b in (("startGap", "start", "start"), ("endGap", "end", "start")):
        for a, b, low, high in case.get(key, []):
            if p := pair(a, b):
                gap = p[1][field_b] - p[0][field_a]
                if not low - 1e-6 <= gap <= high + 1e-6:
                    issues.append(f"{key}:{a},{b}={gap:g}")
    return issues, events


async def evaluate(item, model, system, durations):
    case = item["case"]
    answer = await model.chat([dict(role="system", content=system), dict(role="user", content=case["user"])])
    issues, events = score(case, answer["text"], durations)
    return dict(case=case["id"], category=case["category"], repeat=item["repeat"], user=case["user"], response=answer["text"],
                usage=answer.get("usage"), finishReason=answer.get("finishReason"), issues=issues, passed=not issues)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", choices=sorted(MODELS), required=True)
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env.local")
    parser.add_argument("--input", type=Path, default=Path(__file__).parent / "datasets/wait-prompt-cases.json")
    parser.add_argument("--prompt", type=Path, default=Path(__file__).parent / "wait-prompt.json")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--repeats", type=positive, default=3)
    parser.add_argument("--timeout", type=positive, default=120)
    parser.add_argument("--cases")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Output must be new")
    document = json.loads(args.input.read_text()); system = json.loads(args.prompt.read_text())["system"]
    cases = document["cases"]
    if args.cases:
        wanted = set(args.cases.split(","))
        if not wanted <= {c["id"] for c in cases}:
            parser.error("Unknown case")
        cases = [c for c in cases if c["id"] in wanted]
    url_key, secret_key = MODELS[args.model]
    env = read_env(args.env_file, {k for k in (url_key, secret_key) if k})
    if not all(env.get(k) for k in (url_key, secret_key) if k):
        parser.error("Environment file lacks provider settings")
    os.environ["EXPERIMENT_API_KEY"] = env[secret_key]
    endpoint = env[url_key] if url_key else "https://api.openai.com/v1"
    config = dict(backend="cloud", model=args.model, endpoint=endpoint, api_key_env="EXPERIMENT_API_KEY", options={"temperature": 0})
    items = [dict(id=f"{c['id']}#r{r + 1}", case=c, repeat=r + 1) for r in range(args.repeats) for c in cases]
    async def run():
        model = await chat_model(config, args.timeout)
        return await run_cases(items, lambda i: evaluate(i, model, system, document["durations"]), args.output, timeout=args.timeout,
            provenance=dict(model=args.model, repeats=args.repeats, options=config["options"], inputSHA256=digest(args.input),
                            promptSHA256=digest(args.prompt), runnerSHA256=digest(__file__)))
    return asyncio.run(run())


if __name__ == "__main__":
    raise SystemExit(main())
