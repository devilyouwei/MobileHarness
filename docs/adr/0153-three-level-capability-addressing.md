# ADR 0153 — Three-level capability addressing

Date: 2026-10-06. Status: adopted target, implementation pending.

## Decision

Use Domain.Module.function for executable capabilities: directory/domain, cohesive entry file/namespace, and function. Keep six business-domain catalogs, each aggregating its modules. The single DomainActions namespace is a transitional facade, not the target addressing model. See the [module mapping](../../MobileHarness/README.md#ownership-and-compilation).

Paths do not determine invocation protocol, Channel, exclusion key or resources. Explicit domain/module/function values belong independently to AgentCore and ActionRuntime, with Gateway translation. Agent configuration requires a versioned migration; Agents resolves legacy names and Gateway only receives resolved calls. Preserve exclusion/resource policy explicitly during path changes.

## Status

✅ Directory/file/function classification and target groups are documented before implementation.
❌ Current ActionPath/ActionIdentifier remain two-field values and Tool paths remain strings. Entry splitting, schema/configuration migration, registry coverage and compatibility resolution are the next implementation stage. No runtime behavior changed in this decision.
