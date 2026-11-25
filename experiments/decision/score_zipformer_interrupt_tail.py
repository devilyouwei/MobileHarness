"""Score a causal trailing-silence gate against frozen Zipformer traces."""
import argparse
import json
from pathlib import Path
import zipfile

import numpy as np

from evaluate_zipformer_kws import RATE, audio_from, digest, metrics, pctl, write_report
from tune_zipformer_interrupt import apply_gate

TAIL_DURATIONS_MS = (0, 40, 80, 120, 160, 200)
SPEECH_RMS = .006
AT_PHRASE_END = frozenset(("plain", "polite"))


def silent_tail(audio, consumed, duration_ms):
    samples = RATE * duration_ms // 1000
    if samples > consumed:
        return False
    tail = audio[consumed - samples:consumed]
    tail = np.pad(tail, (0, samples - len(tail))).reshape(-1, RATE // 100)
    return bool(np.all(np.sqrt(np.mean(tail ** 2, axis=1)) < SPEECH_RMS))


def filter_row(row, audio, duration):
    if not duration or not row["adoptedLabel"]:
        return row
    hit_end = row["rawDetection"]["inputFedMS"]
    consumed = round(RATE * (hit_end - row["offsetMS"]) / 1000)
    if silent_tail(audio, consumed, duration):
        return row
    return dict(row, adoptedLabel=None, detectionDelayMS=None, correct=row["expected"] is None)


def replays(trace_path, dataset_sha):
    trace = json.loads(trace_path.read_text())
    if trace["status"] != "complete" or trace["inputSHA256"] != dataset_sha:
        raise ValueError(f"Trace does not match frozen dataset: {trace_path}")
    config = trace["selected"]["config"]
    run = trace["runs"][trace["selected"]["runID"]]
    return config, apply_gate(run["rows"], config["maximumKeywordStartAfterSpeechMS"])


def score_row_set(rows):
    summary = metrics(rows, [])
    end_positive = [r for r in rows if r["group"] in AT_PHRASE_END and r["expected"]]
    observed = [r["detectionDelayMS"] for r in end_positive if r["correct"]]
    summary.update(
        phraseEndP95MS=pctl(observed),
        phraseEndPositive=len(end_positive),
        phraseEndCorrect=len(observed),
        phraseEndDetectedBy100MS=sum(delay <= 100 for delay in observed))
    return summary


def rank(variant):
    score = variant["metrics"]
    recall = score["correctlyDetected"] / score["positive"]
    false_rate = score["falseInterrupts"] / score["negative"]
    latency = score["phraseEndP95MS"]
    approved = recall >= .80 and false_rate <= .05 and latency is not None and latency <= 100
    return approved, round(recall - 2 * false_rate, 9), -false_rate, recall, -(latency or float("inf"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, action="append", required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--locked", type=Path, help="Score only the duration selected in an earlier calibration")
    args = parser.parse_args()
    dataset_sha = digest(args.input.read_bytes())
    with zipfile.ZipFile(args.input) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        audio = {}
        for case in manifest["cases"]:
            raw = archive.read(case["file"])
            if digest(raw) != case["audioSHA256"]:
                raise ValueError(f"Invalid audio {case['id']}")
            audio[case["id"]] = audio_from(raw)
    locked = json.loads(args.locked.read_text())["selected"]["config"] if args.locked else None
    result = dict(inputSHA256=dataset_sha, scriptSHA256=digest(Path(__file__).read_bytes()),
                  earlierCalibrationSHA256=digest(args.locked.read_bytes()) if args.locked else None,
                  thresholds=dict(rms=SPEECH_RMS, frameMS=10), variants=[], observations=[])
    for path in args.trace:
        config, rows = replays(path, dataset_sha)
        if locked and any(config.get(k) != v for k, v in locked.items() if k != "minimumSilentTailMS"):
            raise ValueError("Trace configuration differs from locked calibration")
        durations = (locked["minimumSilentTailMS"],) if locked else TAIL_DURATIONS_MS
        for duration in durations:
            observations = [filter_row(row, audio[row["id"]], duration) for row in rows]
            settings = dict(config, minimumSilentTailMS=duration)
            summary = score_row_set(observations)
            result["variants"].append(dict(config=settings, metrics=summary,
                                           traceSHA256=digest(path.read_bytes())))
            if locked:
                result["observations"].extend(observations)
    result["selected"] = max(result["variants"], key=rank)
    write_report(args.output, result, first=True)
    print(json.dumps(result["selected"], ensure_ascii=False))


if __name__ == "__main__":
    main()
