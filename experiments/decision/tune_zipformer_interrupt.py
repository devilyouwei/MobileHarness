"""Tune the ONNX interrupt probe on development audio, then replay a frozen candidate."""
import argparse
from itertools import product
import json
import platform
from pathlib import Path
import tempfile
import time
import zipfile

import numpy as np
import sherpa_onnx

from evaluate_zipformer_kws import RATE, audio_from, digest, estimated_speech_end, metrics, replay, write_report

ONSET_THRESHOLDS_MS = (None, 120, 200, 320)
ACOUSTIC_THRESHOLDS = (.18, .25, .35, .45, .55)
QUALITY_GATE = dict(minimumRecall=.80, maximumFalseInterruptRate=.05, maximumDetectionP95MS=100)


def speech_onset_ms(audio):
    sample_count = RATE // 100
    frames = np.pad(audio, (0, -len(audio) % sample_count)).reshape(-1, sample_count)
    peaks = np.sqrt(np.mean(frames ** 2, axis=1)) >= .006
    runs = np.flatnonzero(peaks[:-2] & peaks[1:-1] & peaks[2:])
    return int(runs[0]) * 10 if len(runs) else None


def qualifies(score):
    return (score["correctlyDetected"] >= score["positive"] * QUALITY_GATE["minimumRecall"]
            and score["falseInterrupts"] <= score["negative"] * QUALITY_GATE["maximumFalseInterruptRate"]
            and score["detectionP95MS"] is not None
            and score["detectionP95MS"] <= QUALITY_GATE["maximumDetectionP95MS"])


def rank(variant):
    score = variant["metrics"]
    positive = score["correctlyDetected"]
    false = score["falseInterrupts"]
    recall = positive / score["positive"]
    false_rate = false / score["negative"]
    # Keep the shadow detector informative even when no instantaneous policy qualifies.
    # Two points of recall are traded for one point of false-interrupt rate.
    return (
        qualifies(score), round(recall - 2 * false_rate, 9), score["detectedBy100MS"],
        -false, positive, -(score["detectionP95MS"] or float("inf")),
    )


def model_paths(root, chunk):
    variant = f"epoch-13-avg-2-chunk-{chunk}-left-64"
    return dict(tokens=root / "tokens.txt", encoder=root / f"encoder-{variant}.int8.onnx",
                decoder=root / f"decoder-{variant}.onnx", joiner=root / f"joiner-{variant}.int8.onnx")


def collect(paths, keywords, config, cases, audio, offsets, trailer):
    start = time.perf_counter_ns()
    model = sherpa_onnx.KeywordSpotter(
        **{k: str(v) for k, v in paths.items()}, keywords_file=str(keywords), provider="cpu",
        num_threads=1, max_active_paths=4, keywords_threshold=config["threshold"],
        keywords_score=config["boost"], num_trailing_blanks=0)
    load_ms = (time.perf_counter_ns() - start) / 1e6
    for _ in range(2):
        replay(model, audio[cases[0]["id"]], 0, trailer, config["feedSamples"])
    rows, timings = [], []
    for case in cases:
        pcm = audio[case["id"]]
        onset = speech_onset_ms(pcm)
        end = estimated_speech_end(pcm) * 1000 / RATE
        for offset in offsets:
            hits, times = replay(model, pcm, offset, trailer, config["feedSamples"])
            timings.extend(times)
            first = hits[0] if hits else None
            token_times = first["tokenTimesSeconds"] if first else []
            token_start = float(token_times[0]) * 1000 if token_times else None
            relative_start = token_start - offset - onset if token_start is not None and onset is not None else None
            rows.append(dict(id=case["id"], expected=case["expected"], offsetMS=offset,
                             group=case.get("group"), language=case["language"], rawDetection=first,
                             keywordStartAfterSpeechMS=round(relative_start, 3) if relative_start is not None else None,
                             estimatedSpeechEndMS=end+offset))
    return rows, timings, load_ms


def apply_gate(rows, onset_limit):
    scored = []
    for row in rows:
        hit = row["rawDetection"]
        start = row["keywordStartAfterSpeechMS"]
        adopted = hit if onset_limit is None or (start is not None and -80 <= start <= onset_limit) else None
        label = adopted["keyword"] if adopted else None
        scored.append(dict(
            row, adoptedLabel=label, correct=row["expected"] == label,
            detectionDelayMS=round(adopted["inputFedMS"] - row["estimatedSpeechEndMS"], 1) if adopted else None))
    return scored


def development_configs():
    for threshold, boost, feed_ms in product(ACOUSTIC_THRESHOLDS, (.8, 1.), (10, 32)):
        yield dict(chunk=8, threshold=threshold, boost=boost, feedSamples=16*feed_ms)
    for threshold in (.25, .35, .45, .55):
        yield dict(chunk=16, threshold=threshold, boost=1., feedSamples=160)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, help="Freeze settings from a completed development result")
    args = parser.parse_args()
    with zipfile.ZipFile(args.input) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        audio = {}
        for case in manifest["cases"]:
            raw = archive.read(case["file"])
            if digest(raw) != case["audioSHA256"] or case["id"] in audio:
                raise ValueError(f"Invalid audio {case['id']}")
            audio[case["id"]] = audio_from(raw)
    candidate = None if args.candidate is None else json.loads(args.candidate.read_text())["selected"]
    configs = development_configs() if candidate is None else (
        {k:v for k,v in candidate["config"].items() if k != "maximumKeywordStartAfterSpeechMS"},)
    gates = ONSET_THRESHOLDS_MS if candidate is None else (candidate["config"]["maximumKeywordStartAfterSpeechMS"],)
    record = dict(status="running", role="development" if candidate is None else "holdout",
                  inputSHA256=digest(args.input.read_bytes()), keywordSHA256=digest(manifest["keywords"].encode()),
                  scriptSHA256=digest(Path(__file__).read_bytes()), platform=platform.platform(),
                  sherpaVersion=sherpa_onnx.__version__, tiedTo=digest(args.candidate.read_bytes()) if args.candidate else None,
                  gates=QUALITY_GATE, variants=[], runs=[])
    write_report(args.output, record, first=True)
    try:
        with tempfile.TemporaryDirectory(prefix="zipformer-tune-") as directory:
            keywords = Path(directory) / "keywords.txt"
            keywords.write_text(manifest["keywords"])
            for config in configs:
                paths = model_paths(args.models, config["chunk"])
                rows, timings, load_ms = collect(
                    paths, keywords, config, manifest["cases"], audio, manifest["phaseOffsetsMS"],
                    manifest["trailingSilenceMS"])
                run_id = len(record["runs"])
                record["runs"].append(dict(config=config, rows=rows, loadMS=load_ms,
                                           files={k:digest(p.read_bytes()) for k,p in paths.items()}))
                for gate in gates:
                    scoped = apply_gate(rows, gate)
                    score = metrics(scoped, timings)
                    record["variants"].append(dict(runID=run_id, config=dict(config, maximumKeywordStartAfterSpeechMS=gate),
                                                   metrics=score, qualifies=qualifies(score)))
                write_report(args.output, record)
                print(config, flush=True)
    except Exception as error:
        record["status"] = "failed"
        record["error"] = repr(error)
        write_report(args.output, record)
        raise
    record["selected"] = max(record["variants"], key=rank)
    record["status"] = "complete"
    write_report(args.output, record)
    print(json.dumps(record["selected"]), flush=True)


if __name__ == "__main__":
    main()
