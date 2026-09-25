# ADR 0023: Function Documentation and Model Visibility

Status: accepted. Date: 2026-09-24.

JSON v3 replaces capability description/outputDescription/notes with one nonblank doc derived from the actual function. Void Actions need no invented return-value description. Parameter-specific description/constraints remain local to parameter entries.

Action examples are GhostShell/XML strings and may include natural text. Parse them with the shared parser and resolve explicit calls without executing them. A visible example cannot explicitly expose hidden Action tags. Tool examples remain native JSON call strings; Tools do not become XML Actions.

hidden defaults to false and controls model-context visibility only. It neither unregisters a capability nor revokes execution permission. Assistant sets say and print to hidden=true while preserving textActions. CapabilityContextBuilder renders visible docs/examples and removes the hardcoded smile example from generic instructions so hidden names are not introduced there.

Keep native tool execution, Action parameter conversion, semantic validation, output checks and cancellation unchanged. Configuration and docs are author-controlled and bounded. Update code and bundled configuration together; v2 metadata fields are not silently accepted.
