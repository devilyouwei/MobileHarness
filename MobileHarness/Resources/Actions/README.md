# Resources/Actions — Action resources

Resources owned by the [Actions](../../Actions/README.md) module. Actions code stays Swift-only; resources that Action functions need ship here as static files, copied into the Agents resource bundle as `Localization/` (the Agents SwiftPM target covers `Resources`). This directory contains no Swift; only `ActionLocalization` reads it.

## Localization

Default-language text (`doc`, parameter `description`, `constraints`) is written in each function's `@Action` declaration and is the fallback. Translations are `Localization/<Domain>/<Module>.<language>.json`, where `<Domain>` and `<Module>` are the declared domain and module names:

```json
{ "entries": { "<title>": { "description": "…", "parameters": { "<name>": { "description": "…", "constraints": "…" } } } } }
```

- A missing language file, function or parameter keeps the `@Action` text. `constraints` is optional.
- Names, value types, required flags and enum values are not translated.
- `ActionLocalization.translations(for:)` decodes every file and rejects malformed JSON, entries for functions that are not declared, and parameters a function does not declare. App passes the result to Agents with the declarations; Agents applies the table for the active prompt language.
- Adding a language adds files only. Flow teaching and examples stay in Skill `Instructions` resources.
- Agent-owned native tools (`Agent.Writer.*`) are not Action declarations; their translations are `Agents/Writer/Tools.<language>.json`.
