# ADR 0025: One parameterized expression Action

All facial expressions use UI.express with a required emotion string. smile maps to 🙂 alongside happy, laugh, thinking, surprised, sad and love. Remove Smile.swift, the UI.smile App handler and Agent alias, and the /smile special input branch. Do not add a compatibility alias or a parallel per-emotion action list.

Assistant JSON remains v3: the schema is unchanged, while its capability set changes. Only express is visible in the system prompt for expression output. Missing/unknown emotions fail within the Action; no default is injected. Caption/voice mapping, Display scheduling and orb presentation are unchanged.

Parser/runtime tests use parameterized express calls and ordinary events for non-model control fixtures. Historical quality reports and raw outputs remain unchanged so past measurements stay reproducible. This change does not resolve the independently observed tokenizer template mismatch or establish model-quality improvement.
