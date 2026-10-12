# ModelKit Shared Support

## Purpose and boundaries

Support groups shared SDK code while preserving independent compilation and ownership. Core owns neutral data/concurrency mechanisms; Backends owns reusable native graph/tensor execution; Management owns lifecycle/artifacts and default assembly in separate targets; Speech owns helpers shared within its capability domain. Concrete providers remain in Language, Speech and Vision.

## Dependencies and ownership

| Directory | Compiled owner and relationships |
| --- | --- |
| Core | Base ModelKit; neutral mechanisms do not require capability-domain contracts, management or providers |
| Backends/CoreAI, CoreML | Independent ModelKitCoreAI/ModelKitCoreML; native frameworks only |
| Management | ModelKitRuntime → ModelKit; ModelKitDefaults → Runtime, ModelKit and registered concrete providers |
| Management/HuggingFace | ModelKitHub → Runtime and HuggingFace; implements Runtime's downloader protocol |
| Speech/Apple | PCMCodec in ModelKitAppleSpeech together with Apple ASR/TTS; ModelKit and native audio frameworks |

Directory grouping permits no reverse dependency. ModelKitRuntime does not select concrete providers; Defaults owns registration/selection. Provider algorithms own model-specific state and preprocessing. Sharing a native SDK alone does not make those algorithms shared infrastructure.

## Runtime flow

The diagram shows lifecycle/data relationships, not compilation dependencies. Solid arrows are calls/results; dashed arrows inject limits, implementations or factories.

```mermaid
flowchart LR
 Assembly[Default assembly] -.->|Registrations and factories| Runtime[Generic management]
 Runtime -.->|Load gate and waiter limits| Core[Core contexts and resources]
 Provider[Concrete provider] -->|Acquire and release lease| Core
 Provider -->|Named tensor execution where required| Backend[Generic native graph runtime]
 Core -->|InferenceSession events| Consumer[Capability consumer]
 Runtime -->|Artifact operations| Contracts[SDK-owned storage and downloader contracts]
 Host[Host implementations] -.-> Contracts
```

✅ Independent source ownership, neutral Core mechanisms, generic native execution, lifecycle/assembly boundaries and shared Apple PCM conversion are implemented.

❌ General engine interchange and cross-model scheduling are not implemented. Capability and platform-specific limits are documented by the owning directory.

[Core](Core/README.md) · [Backends](Backends/README.md) · [Management](Management/README.md) · [Speech](Speech/README.md) · [Parent design](../README.md)
