# CoreAI Stateless Graph Execution

## Purpose and boundaries

ModelKitCoreAI owns GraphModel, TensorValue and CoreAIGraphError through public CoreAI APIs. The target has no package/product dependencies. Stateful model execution, Gemma tokenizer/cache/pipelining and the CoreAILM/Tokenizers dependencies belong to [Gemma4](../../../Language/LLM/Gemma4/README.md). No download, default selection or business policy lives here.

## Interfaces and lifecycle

GraphModel actor loads a local AIModel, validates a named stateless function and exposes named tensor input/output. TensorValue owns copied scalar values, names/shapes/type validation, and native Boolean masks. Recurrent state is rejected; callers own preprocessing and the resource lease. CoreAI types are conditionally available where the platform framework exists and require OS 27.

ComputeUnits expresses public specialization preferences; cpuOnly restricts the allowed set. Graph loading, tensor mismatches and native allocation/execution failures propagate explicitly. Native references are actor-isolated; run awaits the native API, so callers enforce operation admission through their resource lease. Cancellation is cooperative; native work is not forcibly interrupted.

[CoreAIKit notice](../../../../../docs/licenses/CoreAIKit-BSD-3-Clause.txt) · [Parent design](../README.md)

ComputeUnits.automatic uses SpecializationOptions.default without a heterogeneous placement preference. [D3](../../../Language/JEV/README.md) selects this option for its pinned artifact.

GraphModel exposes the native deviceArchitectureName for artifact selection and accepts both source .aimodel and compiled .aimodelc URLs through the same AIModel loader. Compiled assets can still require device specialization.


GraphModel accepts immutable constantInputs during construction. They are shape/dtype checked and converted to native arrays once; inputNames exposes only per-call inputs, and run combines both sets without allowing callers to overwrite constants. function(named:) creates another stateless function handle on the same AIModel, retaining model lifetime without another specialization. SafeTensorArchive maps external F32 safetensors, validates the header/tensor bounds and declared shapes, and returns typed weight values; it does not interpret model or business policy.
