# CoreAI Stateless Graph Execution

## Purpose and boundaries

ModelKitCoreAI owns GraphModel, TensorValue and CoreAIGraphError through public CoreAI APIs. The target has no package/product dependencies. Stateful model execution, Gemma tokenizer/cache/pipelining and the CoreAILM/Tokenizers dependencies belong to [Gemma4](../../../Language/LLM/Gemma4/README.md). No download, default selection or business policy lives here.

## Interfaces and lifecycle

GraphModel actor loads a local AIModel, validates a named stateless function and exposes named tensor input/output. TensorValue owns copied scalar values, names/shapes/type validation. Recurrent state is rejected; callers own preprocessing and the resource lease. CoreAI types are conditionally available where the platform framework exists and require OS 27.

ComputeUnits expresses public specialization preferences; cpuOnly restricts the allowed set. Graph loading, tensor mismatches and native allocation/execution failures propagate explicitly. Native references are actor-isolated; run awaits the native API, so callers enforce operation admission through their resource lease. Cancellation is cooperative; native work is not forcibly interrupted.

Generic graph/tensor execution is implemented.

[CoreAIKit notice](../../../../../docs/licenses/CoreAIKit-BSD-3-Clause.txt) · [Parent design](../README.md)

## 待实现

- A general stateful graph abstraction is not implemented.

ComputeUnits.automatic uses SpecializationOptions.default without a heterogeneous placement preference. D3 uses this option to match the published artifact validation path; existing graph defaults are unchanged.
