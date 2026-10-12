# Core ML Tensor Graph Execution

## Purpose and ownership

ModelKitCoreML owns CoreMLGraph, CoreMLTensor and CoreMLGraphError with no project or third-party dependencies. CoreMLGraph owns MLModel and per-call native values; the provider owns resource lifetime, recurrent state, preprocessing and model-specific decoding.

## Interfaces and algorithms

Run exchanges immutable named tensors. Input names must match the model descriptor, shapes and value counts must match, and values must be finite. Float16 model I/O maps to the Swift Float boundary. Each output must be a multi-array with at most 1,048,576 elements; copying retains its native shape. Compute/function selection is explicit; Silero uses CPU-only.

Loading and prediction are actor-isolated. Cancellation is checked around synchronous prediction; callers join native work before releasing their resource lease. No additional inference queue or backend-selected provider exists.

YOLO's 640-pixel image layout, padding, Vision execution and fixed end-to-end output reader belong to [YOLO](../../../Vision/YOLO/README.md).

✅ Generic tensor execution is implemented. ❌ Universal image/model interchange is not implemented.

[Parent design](../README.md)
