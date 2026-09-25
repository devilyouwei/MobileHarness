# ADR 0032: ModelKit management and memory policy

Status: accepted.

ModelManager.get(id, as:, load:) is the sole acquisition API. Model registration combines identity, capabilities, factory and memory policy. ModelContext lifecycle and creation are management SPI; ordinary adapters may register one resource in their injected context. Test fixtures may explicitly import that SPI. This is API encapsulation rather than a security boundary.

ModelState describes residency, including unmanaged for a provider with no managed backend. Manager availability queries inspect capability availability without loading weights. Neither a resident model nor an available snapshot guarantees the next inference succeeds.

Memory policies are retain (default) and releaseWhenIdle. App forwards memory warnings through a capacity-one coalescing stream. Manager examines a bounded registration snapshot and asks eligible resources to atomically evict only if loaded and idle. Active leases, loading and teardown prevent eviction; no inference is cancelled or queued for later eviction. Retained capability objects can reload weights. Timed eviction and measured byte budgets remain outside this policy.

MLX allocator configuration is explicit App composition before model use; the App selects a 64 MiB cache limit. Runtime initialization has no global cache-policy side effect. This cache limit does not bound live model tensors.

OperationAdmission is exclusive operation admission with busy rejection, not a general inference scheduler. No priority queue or waiting policy is implied.

✅ Acquisition, management SPI, residency/availability, memory-pressure handling and explicit MLX configuration are implemented.
❌ Physical-device memory-pressure and sustained retry acceptance require device testing.

## Validation

- ✅ Root check.sh and optional adapter package tests pass, including idle/retained/active/loading memory-pressure cases and separate availability/residency.
- ✅ An independent ordinary import ModelKit compilation rejects ModelContext construction and unload access; management imports remain functional.
- ✅ Real Mac Qwen2B generation, cancellation, unload/reload and tokenizer parity pass.
- ✅ Four simulator schemes and signed physical MobileHarness build pass. The App has not been installed for this change.
