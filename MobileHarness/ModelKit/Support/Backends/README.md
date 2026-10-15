# Generic Native Inference Backends

## Purpose and ownership

Independent ModelKitCoreAI and ModelKitCoreML targets own reusable platform graph/tensor execution. Their interfaces carry native graph names, tensor values and execution results, with no model catalog, default selection or application policy. Concrete models own preprocessing, tokenizer/cache state, prompt formats and output decoding. Sharing an SDK does not create shared ownership of distinct models.

## Interfaces and data flow

Provider → native graph actor → public platform API → validated tensor result → provider. Providers own model resource leases and recurrent/session state. Graph actors isolate native objects and return explicit validation/native errors. CoreML prediction is synchronous within its actor; CoreAI execution awaits the native API and actor isolation alone is not an inference admission policy. Providers enforce resource leases and check cancellation around native work. Running kernels finish before their caller releases its lease; no waiting inference queue is introduced.

CoreAI wraps stateless named graph functions and tensors. CoreML wraps named floating-point tensor graphs. Model-specific native image execution is owned by YOLO; language execution by Gemma; FluidAudio speech integration by Nemotron/Kokoro; the MOSS graph pipeline by MossNano. Artifact transfer is documented in [Management](../Management/README.md).

Generic execution is separated from model-specific implementations.

[CoreAI](CoreAI/README.md) · [CoreML](CoreML/README.md) · [Parent design](../README.md)

## 待实现

- Universal engine interchange and cross-model scheduling are unimplemented.
