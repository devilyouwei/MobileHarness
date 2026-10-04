# Gemma 4 E2B chat adapter

Purpose: implement local ChatCapability using Gemma 4 E2B QAT CoreAI. Design goals: capability-only consumers, manager-owned lifetime, explicit failure and private reasoning channels.

✅ ModelKitGemma4 depends only on ModelKit and ModelKitCoreAI. Defaults registers one managed resource and supplies Gemma4 as the installed root. No automatic provider fallback.
✅ Each request resets the backend cache and receives caller-owned history. Admission rejects concurrent requests. Cancellation joins backend cleanup before releasing the lease; unload waits for that lease.
✅ At most 64 nonempty messages / 64 KiB, ending in user, with optional initial system instructions. Prompt plus generation fits 4096 tokens. The output queue holds at most 4096 events of 4096 bytes each; overflow fails explicitly. Usage counts consumed tokens including stop markers. Thought channels never reach Agent text.
✅ iOS uses the pinned h18p AOT graph for iPhone 17 Pro / Pro Max; other hardware fails explicitly. macOS real-model tests require the matching uncompiled b2 decoder alongside the same QAT tables. Cloud settings remain separate.
❌ Mac real inference, cancellation and unload/reload passed using the matching QAT resources. Sustained memory/latency and physical conversation acceptance remain unverified. Native local tools and vision are not implemented.

```mermaid
flowchart LR
    Defaults -->|Installed Gemma4 root| Adapter[Gemma4Chat]
    Consumer -->|ChatRequest| Adapter
    Adapter -->|Exclusive lease| Resource[Manager-owned ModelResource]
    Resource --> Backend[CoreAILanguageEngine]
    Backend -->|Filtered text / real token counts| Adapter
    Adapter -->|Bounded ChatEvent session| Consumer
```

✅ 2026-10-04: Mac CoreAI smoke returned “你好”; generation cancellation and unload/reload passed. Four Gemma tests passed. Signed iPhone 17 Pro build and bundled Agent resource verification passed. Full check.sh passed boundaries, format and provisioning checks but failed two unchanged IntegrationTests aim-follow tests (four assertions). build-ios.sh is blocked by the simulator SDK missing CoreAI. Physical model inference remains pending.
