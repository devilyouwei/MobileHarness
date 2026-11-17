"""Compare App Swift Vela noul readout against the published Python adapter."""
import argparse
import asyncio
import importlib.util
import json
from pathlib import Path

async def run(args):
    root = Path(args.models) / "Vela3Fast"
    spec = importlib.util.spec_from_file_location("vela_coreai", root / "vela_coreai.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    rows = json.loads(Path(args.input).read_text())
    report = []
    async with module.VelaCoreAI.open(root) as model:
        for row in rows:
            if row["model"] != "vela3-fast":
                continue
            result = await model.predict(row["text"], {"type": "noul", "instructions": row["instructions"]})
            probability = result["noul"]
            report.append({"text": row["text"], "swift": row["score"], "python": probability,
                           "absolute_error": abs(probability - row["score"])})
    Path(args.output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    maximum = max(row["absolute_error"] for row in report)
    print(f"Vela native parity: {len(report)} rows, max probability error {maximum:.9g}")
    if maximum > 0.001:
        raise RuntimeError("Swift/Python Vela probability mismatch")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    asyncio.run(run(parser.parse_args()))
