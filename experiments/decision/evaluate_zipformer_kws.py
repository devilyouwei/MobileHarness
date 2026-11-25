"""Replay frozen stop phrases using native Core ML or a Sherpa-ONNX baseline."""
import argparse
import hashlib
import io
import json
import math
import platform
import sys
import tempfile
import time
import wave
import zipfile
from importlib.metadata import version
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from utils.runtime import write_report

from zipformer_coreml import CoreMLReplay, SPEC_PATH, prepare_release

RATE = 16000


def digest(data):
    return hashlib.sha256(data).hexdigest()


def audio_from(data):
    with wave.open(io.BytesIO(data), "rb") as stream:
        if (stream.getframerate(), stream.getnchannels(), stream.getsampwidth()) != (RATE, 1, 2):
            raise ValueError("Expected 16 kHz mono PCM16")
        return np.frombuffer(stream.readframes(stream.getnframes()), dtype="<i2").astype(np.float32) / 32768


def estimated_speech_end(audio):
    frames = np.pad(audio, (0, (-len(audio)) % 160)).reshape(-1, 160)
    rms = np.sqrt(np.mean(frames ** 2, axis=1))
    return min(len(audio), (1 + int(np.flatnonzero(rms >= rms.max() * .03)[-1])) * 160)


def pctl(values, proportion=.95):
    return round(sorted(values)[math.ceil(len(values) * proportion) - 1], 3) if values else None


def replay(spotter, audio, offset_ms, trailer_ms, step):
    prefix = RATE * offset_ms // 1000
    samples = np.pad(audio, (prefix, RATE * trailer_ms // 1000))
    stream = spotter.create_stream()
    hits, compute_ms = [], []
    for start in range(0, len(samples), step):
        stop = min(start + step, len(samples))
        stream.accept_waveform(RATE, samples[start:stop])
        while spotter.is_ready(stream):
            t = time.perf_counter_ns()
            spotter.decode_stream(stream)
            compute_ms.append((time.perf_counter_ns() - t) / 1e6)
            match = spotter.keyword_spotter.get_result(stream)
            if match.keyword:
                hits.append({"keyword": match.keyword, "tokenTimesSeconds": list(match.timestamps),
                             "inputFedMS": 1000 * stop / RATE})
                spotter.reset_stream(stream)
    return hits, compute_ms


def metrics(rows, timings):
    positive = [r for r in rows if r["expected"] is not None]
    negative = [r for r in rows if r["expected"] is None]
    matched = [r["detectionDelayMS"] for r in positive if r["correct"]]
    correct = sum(r["correct"] for r in rows)
    return dict(replays=len(rows), correct=correct, accuracy=correct/len(rows), positive=len(positive),
                correctlyDetected=len(matched), missedOrWrong=len(positive)-len(matched),
                negative=len(negative), falseInterrupts=sum(not r["correct"] for r in negative),
                detectedBy100MS=sum(value <= 100 for value in matched), detectionP50MS=pctl(matched,.5),
                detectionP95MS=pctl(matched), decodeP50MS=pctl(timings,.5), decodeP95MS=pctl(timings),
                decodeCalls=len(timings))


def evaluate(args, chunk, blanks, keyword_file, manifest, samples, release=None):
    started = time.perf_counter_ns()
    settings = dict(max_active_paths=4, keywords_score=1., keywords_threshold=.25,
                    num_trailing_blanks=blanks, provider=args.provider)
    if release:
        root, spec = release
        engine = CoreMLReplay(root, spec, keyword_file, args.compute_unit, blanks)
        replay_case = engine.replay
        settings["compute_unit"] = args.compute_unit
        weights = {name: entry["sha256"] for name, entry in spec["files"].items()
                   if ".mlpackage/" in name or name == "tokens.txt"}
    else:
        import sherpa_onnx as sherpa

        suffix = f"epoch-13-avg-2-chunk-{chunk}-left-64"
        paths = dict(tokens=args.models/"tokens.txt", encoder=args.models/f"encoder-{suffix}.int8.onnx",
                     decoder=args.models/f"decoder-{suffix}.onnx", joiner=args.models/f"joiner-{suffix}.int8.onnx")
        settings["num_threads"] = 1
        provider = "coreml" if args.provider == "coreml-ep" else "cpu"
        spotter = sherpa.KeywordSpotter(**{key: str(value) for key, value in paths.items()},
                                       keywords_file=str(keyword_file), **dict(settings, provider=provider))

        def replay_case(audio, offset, trailer, step):
            return replay(spotter, audio, offset, trailer, step)

        weights = {key: digest(path.read_bytes()) for key, path in paths.items()}
    load_ms = (time.perf_counter_ns() - started) / 1e6
    stream_args = (manifest["trailingSilenceMS"], manifest["feedSamples"])
    warmup = samples[manifest["cases"][0]["id"]]
    for _ in range(2):
        replay_case(warmup, 0, *stream_args)
    rows, timings = [], []
    for case in manifest["cases"]:
        audio = samples[case["id"]]
        end = 1000 * estimated_speech_end(audio)/RATE
        for offset in manifest["phaseOffsetsMS"]:
            hits, times = replay_case(audio, offset, *stream_args)
            timings.extend(times)
            actual = hits[0]["keyword"] if hits else None
            rows.append(dict(id=case["id"], expected=case["expected"], language=case["language"],
                             offsetMS=offset, correct=actual==case["expected"], detections=hits,
                             estimatedSpeechEndMS=end+offset,
                             detectionDelayMS=round(hits[0]["inputFedMS"]-end-offset,1) if hits else None,
                             decodeCalls=len(times), decodeP95MS=pctl(times)))
    return dict(chunk=chunk, settings=settings, loadMS=load_ms, rows=rows, metrics=metrics(rows,timings),
                weightSHA256=weights)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, help="Optional pinned Core ML bundle or required ONNX directory")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--provider", choices=("cpu", "coreml", "coreml-ep"), required=True)
    parser.add_argument("--compute-unit", choices=("CPU_ONLY", "ALL"))
    parser.add_argument("--chunk", choices=(8,16), type=int, action="append", required=True)
    parser.add_argument("--blanks", choices=(0,1), type=int, action="append", required=True)
    args = parser.parse_args()
    spec = None
    if args.provider == "coreml":
        spec = json.loads(SPEC_PATH.read_text())
        if any(chunk != spec["chunk"] for chunk in args.chunk):
            parser.error(f"The published Core ML release supports only --chunk {spec['chunk']}")
        args.compute_unit = args.compute_unit or "CPU_ONLY"
    elif args.models is None or args.compute_unit is not None:
        parser.error("ONNX providers require --models and do not accept --compute-unit")
    with zipfile.ZipFile(args.input) as archive:
        manifest = json.loads(archive.read("manifest.json"))
        if manifest["sampleRate"] != RATE:
            raise ValueError("Unsupported sample rate")
        samples = {}
        for case in manifest["cases"]:
            data = archive.read(case["file"])
            if digest(data) != case["audioSHA256"] or case["id"] in samples:
                raise ValueError(f"Invalid fixture {case['id']}")
            samples[case["id"]] = audio_from(data)
    packages = ("coremltools", "kaldi-native-fbank", "numpy") if spec else (
        "sherpa-onnx", "sherpa-onnx-core", "numpy")
    result = dict(status="running", variants=[], dataSHA256=digest(args.input.read_bytes()),
                  runnerSHA256=digest(Path(__file__).read_bytes()), warmupsPerConfiguration=2,
                  keywordSHA256=digest(manifest["keywords"].encode()), python=platform.python_version(),
                  platform=platform.platform(), packages={name: version(name) for name in packages})
    if spec:
        result.update(modelSource=f"https://huggingface.co/{spec['repository']}",
                      modelRevision=spec["revision"], modelSpecSHA256=digest(SPEC_PATH.read_bytes()),
                      adapterSHA256=digest(SPEC_PATH.with_name("zipformer_coreml.py").read_bytes()),
                      timingScope="PCM packet time with at least one native encoder window")
    write_report(args.output,result,first=True)
    try:
        release = (prepare_release(spec, args.models), spec) if spec else None
        with tempfile.TemporaryDirectory(prefix="zipformer-keywords-") as directory:
            keywords=Path(directory)/"keywords.txt"
            keywords.write_text(manifest["keywords"],encoding="utf8")
            for chunk in args.chunk:
                for blanks in args.blanks:
                    variant=evaluate(args,chunk,blanks,keywords,manifest,samples,release)
                    result["variants"].append(variant)
                    write_report(args.output,result)
                    print(chunk,blanks,variant["metrics"],flush=True)
    except Exception as error:
        result["status"]="failed"
        result["error"]={"type":type(error).__name__,"detail":str(error)}
        write_report(args.output,result)
        raise
    result["status"]="complete"
    write_report(args.output,result)


if __name__=="__main__":
    main()
