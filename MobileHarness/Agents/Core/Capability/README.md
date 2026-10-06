# Capability declarations and runtime permissions

Purpose: validate Agent configuration and resolve model-local names without depending on concrete Agents, models or device implementations. Design goal: keep model exposure distinct from trusted runtime output permissions.

- ✅ AgentConfiguration accepts bounded JSON v6: version, id, Channel-grouped three-field actions, explicit Tool path/definition bindings and unchanged communication.
- ✅ Group keys supply Channel defaults; empty groups declare Channels. Old channels/textActions/hidden/defaultChannel fields fail validation.
- ✅ Action examples are parsed and resolved against the model-only catalog. Group traversal is sorted for deterministic prompt assembly; aliases are globally unique within an Agent.
- ✅ InternalAction and InternalTool define code-owned paths and argument names without aliases/docs. Registry permits checks include internal grants, but resolveAction/resolveTool never search them.
- ✅ CapabilityContextBuilder produces English Channel/module/wait instructions and callable Action details. The owning Agent adds its own natural-text policy outside Core. Internal metadata and Tools never enter this text.
- ✅ NativeToolDefinition preserves the OpenAI Chat Completions envelope. Current argument transport supports string properties, optional enums and required-name checks. Unsupported schemas fail explicitly.
- ❌ Full JSON Schema, provider-native Tool streaming, configuration hot reload and physical-device authorization remain outside this module.

## Validation and assembly

```mermaid
flowchart LR
    Data[At most 64 KiB JSON] --> Schema[Version 6 and strict field checks]
    Schema --> Catalog[Grouped Actions and native Tools]
    Catalog --> Examples[XML example validation]
    Examples --> Config[Immutable model configuration]
    Config --> Agent[Agent assembly]
    Internal[Code-owned internal permissions] --> Agent
    Agent --> Registry[Immutable runtime registry]
    Catalog --> Resolve[Model alias resolution and prompt]
    Registry --> Permits[Gateway resolved-call validation]
```

The configuration permits at most 128 capabilities; assembly applies the same bound including internal grants. At most 16 Channels include model groups and internal defaults; parameter sets have at most 32 entries. Paths are keys, not reflected method names. Required and optional arguments must be disjoint; calls reject unknown/missing names and oversized values. Action handlers remain responsible for value semantics. Native Tool enums are checked during resolution and Gateway permission validation.

No Channel is implicitly main or blocking. DefaultChannel remains an internal runtime property derived from the JSON group, not a redundant JSON field. Text mapping is not part of AgentConfiguration: AgentGenerator receives an optional code-owned callback, and Assistant provides synthesis/playback/caption behavior. See [Agent standard](../../README.md) for complete schema rules and [Generation](../Generation/README.md) for streaming limits.

✅ Source location: `MobileHarness/Agents/Core/Capability`; compiled by `AgentCore`. Directory relocation preserves existing behavior and public contracts. ❌ No new runtime capabilities are implied.

## Action and Tool presentation boundary

✅ CallArguments provides shared, bounded transport decoding for Action and Tool domains. Actions retains the ActionArguments compatibility name; Tools has no Actions dependency. ❌ Domain-specific defaults/meaning remain outside this decoder.

✅ Capability permissions remain Agent-owned. Execution argument readers live separately in Actions/Runtime/Contracts and Actions/Runtime/Contracts; the unused AgentCore reader was removed.

✅ CapabilityContextBuilder contains no automatic synthesis/playback assumptions. AssistantAgent.outputContext adds that Agent’s Speech-channel, wait/playback guidance and examples. Catalog metadata is still resolved solely from versioned Agent JSON.

✅ AgentConfiguration receives CommunicationContracts from its caller and validates JSON declarations against that registry. The standard registry has no speech/vision entries; business AgentConfigurations selects the application catalog explicitly.

✅ ADR0156: canonical execution addresses use domain/module/function; Agent v6 bindings resolve native names separately. Existing serialization/resource and output permissions are preserved.


✅ ADR0157: canonical executable definitions and shared outcomes replace duplicate protocol metadata; consumers import Actions/ActionRuntime. Protocol request views remain adapters, and production permission/resource boundaries are preserved.

❌ Physical acceptance and additional business capability exposure are not established by this migration.
