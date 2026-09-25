# Language generation

Purpose: define ChatCapability and provide the Qwen3.5 adapter. Design goals: capability-only consumers, bounded output and independent backend execution.

- ✅ ChatCapability accepts caller-owned text conversation history and produces cancellable text events.
- ✅ Qwen35 implements the capability using the optional MLX backend; App selects its local model directory.
- ❌ Image inputs, native Tool Call events and additional language model adapters.

Concrete adapters are separate Swift targets; the base SDK compiles only the capability contract here.
