# ModelKit Core — Data, Sessions and Model Admission

Purpose: document the implemented concurrency contracts and their limits. Design goal: explicit ownership, bounded work and observable termination.

## Queue and asynchronous processing contract

`InferenceSession` connects one adapter producer to one capability consumer using `AsyncThrowingStream.bufferingOldest`. `StreamLimits` specifies a positive event count and maximum estimated bytes/event; the product is checked for integer overflow. These are payload accounting limits, not measured total process memory. The producer must serialize emissions.

`yield` checks event size, then stream admission. Oversized events fail with `eventTooLarge`; a dropped yield fails the session with `bufferOverflow`. It never waits for a free slot. The single consumer checks terminal failure before and after awaiting each event, so failure/cancellation prevents buffered events being delivered afterwards. Normal finish permits accepted events to drain. A second iterator is rejected. Explicit cancellation, consumer cancellation or session-handle destruction terminates the session; the adapter's termination callback stops its worker. Callers breaking consumption early must cancel explicitly.

`ModelResource` is an adapter-facing handle owned by a manager-created ModelContext. It coalesces weight loading (32 waiters), reserves exactly one active inference lease per model, including system speech, and rejects busy work without a request queue. One manager shares a four-loader gate across its contexts. Cancellation of a load waiter never cancels other waiters. Explicit unload gates admission and waits for backend cleanup; shutdown also signals registered cancellation callbacks. Neither dropping a completed inference lease nor cancelling one turn unloads weights.

The active lease is one optional record containing its ID and cancellation callback. Release and callback registration require a matching ID; delayed operations from an earlier request cannot alter the current lease.

ModelState reports registered/constructing at the manager, unmanaged for providers without a resource, and unloaded/loading/ready/unloading/closed for managed resources. Residency is not capability availability; query manager.availability(id, for:) separately without loading weights. Lifecycle and composition APIs are in [ModelKitRuntime](../Management/README.md). Adapters load local files through their backend SDK. OperationAdmission independently bounds backend graph operations.
Unsupported: blocking producer admission, durable event replay, request priority/fairness and cross-model resource scheduling.

```mermaid
flowchart TD
    Producer[Adapter producer] --> Check[Check estimated event size]
    Check --> Buffer[Bounded event stream]
    Buffer --> Consumer[Single consumer]
    Check -->|oversize| Fail[Fail session]
    Buffer -->|overflow| Fail
    Cancel[Cancel] --> Fail
    Fail --> Cleanup[Adapter termination callback]
    Acquire[Acquire model lease] --> Busy{Active lease?}
    Busy -->|Yes| Reject[inputBusy]
    Busy -->|No| Load[Reserve ID and load or reuse model]
    Load --> Work[One active operation]
    Work --> CleanupLease[Finish backend cleanup]
    CleanupLease --> Release[Release only matching lease ID]
    Release --> Unload[Complete pending unload]
```

✅ The algorithm above describes the current implementation.
❌ Waiting admission, replay or additional scheduling guarantees are unsupported unless explicitly stated above.

Maintenance: update this contract when changing producers, consumers, limits, ordering, cancellation or completion semantics.

✅ OperationAdmission admits one backend operation and immediately rejects overlap; it owns no request queue. ModelContext management is restricted to ModelManagement SPI. Memory-pressure eviction is atomic and skips loading, active or closing resources; no cancellation or delayed eviction is introduced.

✅ Core owns capability/session contracts and resource admission. Model registration and lifecycle orchestration are in ../Management; native/library execution is in ../Backends. The root project package compiles these as separate targets.

## Shared media data

Core owns model-independent audio, image and video data contracts. These types describe validated payloads and metadata; they do not capture devices, read files, render UI or own inference engines. Platform adapters convert framework-specific buffers at their boundary.

- ✅ AudioFrame.swift defines AudioFormat and AudioFrame: PCM encoding, sample rate, channels, payload, sequence and timestamp, with size/alignment validation and duration calculation.
- ❌ Image and video contracts will be added here when a concrete capability needs them; no placeholder types are created. Their design must specify representation, dimensions, timing where applicable, payload bounds and ownership.

Keep shared media values separate from model-specific tensors, preprocessing and business message types.
