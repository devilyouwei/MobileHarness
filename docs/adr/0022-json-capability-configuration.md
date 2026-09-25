# ADR 0022: JSON Capability Configuration v2

Status: accepted. Date: 2026-09-24.

Replace per-Agent XML plist resources with UTF-8 JSON and schemaVersion 2. Do not silently fall back to plist. Keep alias/path/defaultChannel/textActions behavior unchanged and keep real handler registration in App.

Each capability declares description, parameters, structured examples, outputDescription and notes. A parameter declares name, valueType, required, description and constraints. Derive required/optional name sets from this single list. Use the same descriptive fields for Tools while retaining their string paths and lack of Channel scheduling.

valueType describes the intended type inside a function; transport and example values remain strings. Human-readable constraints and omitted-value behavior do not execute validation or inject defaults. Functions retain cohesive conversion, validation and output handling. Example validation checks argument structure through the registry without executing side effects.

Persist metadata in CapabilityDocumentation on registrations. Defer its insertion into model prompts to a separately budgeted and escaped rendering change; the existing prompt builder remains unchanged. Configuration limits and strict field/type validation apply before Agent startup.

Agents/README.md is the authoritative format specification and complete example. Future typed schemas, resource policies or deprecation fields require actual consumers before addition. Historical v1 ADR 0019 records the superseded format.
