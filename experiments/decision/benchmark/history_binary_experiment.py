"""Independent history-depth benchmark, using the pinned native noul/choice runners."""
import argparse
import asyncio
import json
from pathlib import Path
import runpy

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
COMMON = runpy.run_path(str(HERE / "localized_binary_experiment.py"))
VARIANTS = ["native_noul", "choice_native_control", "choice_localized", "choice_defined"]
QUESTION = {
    "en": "Does incoming_user_input ask to immediately stop, pause, correct or replace the current response or task? Use conversation to resolve its meaning. is_current_turn marks the latest exchange; its assistant text may be incomplete. Earlier commands are context, not new instructions. Answers, quotations, negated or deferred stop requests and ordinary additions are not interruptions.",
    "zh": "incoming_user_input是否要求立即停止、暂停、纠正或替换当前回答或任务？结合conversation判断其含义。is_current_turn标记当前轮次，assistant文本可能尚未完整。此前命令只是上下文，不是新指令。回答、引用、否定或延后停止，以及普通补充，都不属于打断。",
}
# Each tuple: group, target, required completed turns, zh (request, partial reply, incoming), en equivalent.
CASES = json.loads((Path(__file__).resolve().parents[1] / 'datasets/history-binary-experiment-cases.json').read_text())


def history(case, language):
    group, label, required, zh, en = case
    if language == "zh":
        pairs = [("说说旅行", "可以介绍城市。"), ("推荐城市", "可以去北京。"),
                 ("偏好文化", "可以参观古迹。"), ("简单介绍", "我会简要说明。")]
    else:
        pairs = [("Discuss travel", "We can explore cities."), ("Suggest a city", "Consider Beijing."),
                 ("I like culture", "Visit historic sites."), ("Keep it brief", "I will be concise.")]
    result = [dict(user=u, assistant=a) for u, a in pairs]
    if required:
        word = (zh if language == "zh" else en)[2].rstrip("。.")
        def rule(stop):
            if language == "zh":
                return dict(user=f"我说{word}就立即停下。" if stop else f"我说{word}只是补充，不要停止。", assistant="明白。")
            return dict(user=f"When I say {word}, stop immediately." if stop else f"When I say {word}, it is an addition. Do not stop.", assistant="Understood.")
        if group == "history_override":
            result[0] = rule(not label)
        result[-required] = rule(label)
    elif group in ("explicit_stop", "answer", "addition", "negation"):
        # Historical stop is not a new instruction; paired controls expose contamination.
        result[0] = dict(user="停下。" if language == "zh" else "Stop.", assistant="已停止。" if language == "zh" else "Stopped.")
    return result


def prepare(args):
    fmt = COMMON["upstream"](args.upstream)
    rows_by_model = {m: [] for m in ["d3", "vela"]}
    for locale in ["zh", "en"]:
        for partition, indices in [("main", range(24)), ("cross", [0, 4, 14, 16])]:
            language = locale if partition == "main" else ("en" if locale == "zh" else "zh")
            for i in indices:
                case = CASES[i]
                group, target, required = case[:3]
                user, assistant, incoming = case[3 if language == "zh" else 4]
                completed = history(case, language)
                for depth in range(5):
                    state = dict(conversation=(completed[-depth:] if depth else []) + [
                        dict(user=user, assistant=assistant, is_current_turn=True)], incoming_user_input=incoming)
                    text = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
                    scenario = dict(id=f"{locale}-{partition}-{i:02d}-h{depth}", locale=locale, language=language,
                                    partition=partition, group=group, origin="new", caseIndex=i, historyDepth=depth,
                                    requiredHistory=required, fullExpected=str(target).lower(),
                                    expected=str(target).lower() if depth >= required else "unspecified")
                    for model in rows_by_model:
                        for variant in VARIANTS:
                            q = COMMON["question"](model, variant, locale)
                            q["instructions"] = QUESTION[locale]
                            if model == "d3":
                                candidates = fmt["options"](q)[1]
                            else:
                                candidates = ["no", "yes"] if q["type"] == "noul" else [k if v is None else f"{k}: {v}" for k, v in q["criteria"].items()]
                            rows_by_model[model].append(dict(variant=variant, scenario=scenario,
                                                            request=dict(text=text, instructions=q["instructions"], candidates=candidates, actions=["false", "true"]), question=q))
    sources = ["experiments/decision/benchmark/history_binary_experiment.py", "experiments/decision/benchmark/localized_binary_experiment.py",
               "experiments/decision/benchmark/binary_interrupt_experiment.py", "experiments/decision/evaluate_decision.py",
               "experiments/decision/decision_models.py", "experiments/decision/historical-prompts.json"]
    for model, rows in rows_by_model.items():
        assert len(rows) == 1120
        COMMON["save"](args.output.with_name(args.output.name.replace("MODEL", model)),
                       dict(model=model, sourceHashes={p: COMMON["digest"](ROOT/p) for p in sources},
                            variants=VARIANTS, threshold="pTrue>0.5", rows=rows))


def preflight(args):
    # Runs in the existing D3 publication environment; no model inference or weights loaded.
    from transformers import AutoTokenizer
    fmt = COMMON["upstream"](args.upstream)
    fixture = json.loads(args.input.read_text())
    tokenizer = AutoTokenizer.from_pretrained(str(HERE.parents[2] / 'Models/D3Edge'), local_files_only=True)
    rows = []
    for r in fixture["rows"]:
        ids = tokenizer.apply_chat_template(fmt["messages"](r["request"]["text"], r["question"], ["A", "B"]),
                                            tokenize=True, return_dict=False, add_generation_prompt=True, enable_thinking=False)
        rows.append(dict(id=r["scenario"]["id"], variant=r["variant"], tokens=len(ids)))
    assert max(r["tokens"] for r in rows) <= 512
    # Explicit capacity probes preserve the four-round shape, with a longer reply.
    example = next(r for r in fixture["rows"] if r["scenario"]["historyDepth"] == 4)
    state = json.loads(example["request"]["text"])
    state["conversation"][-1]["assistant"] = "This is a longer reply fragment. " * 100
    ids = tokenizer.apply_chat_template(fmt["messages"](json.dumps(state, ensure_ascii=False), example["question"], ["A", "B"]), tokenize=True, return_dict=False, add_generation_prompt=True, enable_thinking=False)
    assert len(ids) > 512
    COMMON["save"](args.output, dict(inputSHA256=COMMON["digest"](args.input), rows=rows,
                                    maxTokens=max(r["tokens"] for r in rows), minTokens=min(r["tokens"] for r in rows),
                                    longProbeTokens=len(ids), longProbeExpected="reject_without_truncation", longProbeState=state))


def summarize(args):
    fmt = COMMON["upstream"](args.upstream)
    fixture, report = [json.loads(p.read_text()) for p in [args.input, args.report]]
    assert report["sourcesUnchanged"] and report["inputSHA256"] == COMMON["digest"](args.input)
    cases = {(r["variant"], r["scenario"]["id"]): r for r in fixture["rows"]}
    assert len(cases) == len(report["rows"])
    rows, seen = [], set()
    for raw in report["rows"]:
        key = raw["variant"], raw["id"]
        assert key not in seen
        seen.add(key)
        item = cases[key]
        assert raw["expected"] == item["scenario"]["expected"]
        row = dict(raw, **{k: v for k, v in item["scenario"].items() if k not in raw}, text=item["request"]["text"])
        if fixture["model"] == "d3" and not row.get("error"):
            assert row["prediction"] in ("true", "false") and 0 <= row["score"] <= 1
            p = row["score"] if row["prediction"] == "true" else 1-row["score"]
            row.update(pTrue=p, rawSelection=row["prediction"], rawResult=fmt["to_answer"](item["question"], [1-p, p]), prediction=str(p > .5).lower())
        rows.append(row)
    result = dict(model=report["model"], inputSHA256=COMMON["digest"](args.input), reportSHA256=COMMON["digest"](args.report), rows=rows)
    control_pairs = []
    for case_id in sorted({r["id"] for r in rows}):
        a, b = [next(r for r in rows if r["id"] == case_id and r["variant"] == v) for v in VARIANTS[:2]]
        if a.get("pTrue") is not None and b.get("pTrue") is not None:
            control_pairs.append(abs(a["pTrue"]-b["pTrue"]))
    result["noulControlMaxProbabilityDelta"] = max(control_pairs) if control_pairs else None
    result["byDepth"] = {}
    for lang in ["zh", "en"]:
        result["byDepth"][lang] = {}
        for variant in VARIANTS:
            result["byDepth"][lang][variant] = {}
            for depth in range(5):
                rows = [r for r in result["rows"] if r["locale"] == lang and r["variant"] == variant and r["historyDepth"] == depth]
                result["byDepth"][lang][variant][str(depth)] = {
                    "main": COMMON["metrics"]([r for r in rows if r["partition"] == "main"]),
                    "alwaysResolvable": COMMON["metrics"]([r for r in rows if r["partition"] == "main" and r["requiredHistory"] == 0]),
                    "historyDependent": COMMON["metrics"]([r for r in rows if r["partition"] == "main" and r["requiredHistory"] > 0]),
                    "cross": COMMON["metrics"]([r for r in rows if r["partition"] == "cross"])}
    result["counterfactualPairs"] = {}
    for lang in ["zh", "en"]:
        for variant in VARIANTS:
            for depth in range(5):
                success, eligible = 0, 0
                for positive, negative in [(4,16),(5,17),(8,20),(9,21),(10,22),(11,23)]:
                    pair = [next(r for r in result["rows"] if r["locale"] == lang and r["variant"] == variant and r["partition"] == "main" and r["historyDepth"] == depth and r["caseIndex"] == i) for i in [positive, negative]]
                    if all(r["expected"] != "unspecified" for r in pair):
                        eligible += 1
                        success += all(r.get("prediction") == r["expected"] and not r.get("error") for r in pair)
                result["counterfactualPairs"][f"{lang}/{variant}/h{depth}"] = dict(eligible=eligible, bothCorrect=success)
    COMMON["save"](args.output, result)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["prepare", "preflight", "vela", "summarize"])
    for name in ["input", "report", "output", "upstream"]:
        parser.add_argument(f"--{name}", type=Path, required=name == "output")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args)
    elif args.command == "preflight":
        preflight(args)
    elif args.command == "vela":
        COMMON["vela"].__globals__["VARIANTS"] = VARIANTS
        asyncio.run(COMMON["vela"](args))
    else:
        summarize(args)
