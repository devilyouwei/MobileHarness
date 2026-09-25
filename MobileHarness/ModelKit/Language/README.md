# Language capabilities

Purpose: Group language-generation and judgment protocols with concrete model adapters.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ LLM text chat and JEV judgment contracts; Qwen35 is the current chat adapter.
- ❌ Vision, embedding and a concrete judgment provider.
