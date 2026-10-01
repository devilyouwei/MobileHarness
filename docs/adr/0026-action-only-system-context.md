# ADR 0026: Separate Action guidance from native tools

> Configuration migration: [ADR 0061](0061-agent-json-v5.md) supersedes the JSON schema, hidden/text alias and all-in-JSON registration portions of this historical decision. Its other runtime contracts remain unchanged.

The system prompt teaches the Function Token protocol and only Actions with hidden=false. CapabilityContextBuilder must not serialize native Tool Call aliases, parameter guidance, docs or examples, even if a tool has hidden=false.

Tool configuration, visibility metadata, resolution and execution stay intact. Future native tool exposure belongs to the provider tool-schema path, which is not implemented by the current text-only ChatCapability. Do not implement it by embedding tool instructions in system text.

Regression coverage checks both tool visibility values and the actual ChatRequest system message, while existing tool-roundtrip tests verify execution remains functional. Historical model-quality evidence is unchanged; new quality claims require another real-model evaluation.
