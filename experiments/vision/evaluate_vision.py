"""Core ML Python image-case inference timings; no Swift preprocessing or UI."""
import argparse
import asyncio
import json
from pathlib import Path
import sys
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from utils.runtime import digest,positive,write_report


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,required=True);p.add_argument('--input-name',required=True)
    p.add_argument('--images',type=Path,nargs='+',required=True)
    p.add_argument('--compute',choices=['CPU_ONLY','CPU_AND_NE','CPU_AND_GPU','ALL'],default='ALL')
    p.add_argument('--width',type=positive,default=640);p.add_argument('--height',type=positive,default=640)
    p.add_argument('--iterations',type=positive,default=5);p.add_argument('--warmup',type=positive,default=3)
    p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    if args.output.exists():p.error('Output must be new')
    import coremltools as ct
    import numpy as np
    from PIL import Image,ImageOps
    start=time.perf_counter();model=ct.models.MLModel(str(args.model),compute_units=getattr(ct.ComputeUnit,args.compute))
    report=dict(scope='Python Pillow letterbox and Core ML prediction; not Swift/vision/vImage parity',
                model=str(args.model),compute=args.compute,loadMS=(time.perf_counter()-start)*1000,rows=[],complete=False)
    write_report(args.output,report,first=True)
    for path in args.images:
        row=dict(image=str(path),imageSHA256=digest(path),samplesMS=[])
        try:
            start=time.perf_counter()
            with Image.open(path) as source:image=ImageOps.pad(source.convert('RGB'),(args.width,args.height),color=(114,114,114))
            row['preprocessingMS']=(time.perf_counter()-start)*1000
            for i in range(args.warmup+args.iterations):
                start=time.perf_counter();output=model.predict({args.input_name:image})
                elapsed=(time.perf_counter()-start)*1000
                if i>=args.warmup:row['samplesMS'].append(elapsed)
            arrays={k:np.asarray(v) for k,v in output.items()}
            if any(not np.isfinite(v).all() for v in arrays.values()):raise ValueError('Nonfinite model output')
            row.update(outputs={k:v.tolist() for k,v in arrays.items()},passed=True)
        except Exception as error:row.update(error=type(error).__name__,passed=False)
        report['rows'].append(row);write_report(args.output,report)
    report['complete']=True;write_report(args.output,report)
    return int(any(not r['passed'] for r in report['rows']))


if __name__=='__main__':raise SystemExit(main())
