# ADR 0026: Separate Action guidance from native tools

The system prompt teaches the Function Token protocol and only Actions with hidden=false. CapabilityContextBuilder must not serialize native Tool Call aliases, parameter guidance, docs or examples, even if a tool has hidden=false.

Tool configuration, visibility metadata, resolution and execution stay intact. Future native tool exposure belongs to the provider tool-schema path, which is not implemented by the current text-only ChatCapability. Do not implement it by embedding tool instructions in system text.

Regression coverage checks both tool visibility values and the actual ChatRequest system message, while existing tool-roundtrip tests verify execution remains functional. Historical model-quality evidence is unchanged; new quality claims require another real-model evaluation.
