# Shared context persistence adapter

Purpose: adapt generic AgentCore Context transactions to Storage atomic documents. Compiles inside Agents; business schemas, admission/retention and context selection remain owned by roles.

✅ ADR0189 source migration implemented: AgentContextRepository.swift has moved here unchanged. It owns serialized immutable snapshots/copy-before-commit updates and SignalEvidence encoding. At most16 commit waiters; overflow rejects. Documents are bounded64MiB and compare-and-swap failures preserve the previous snapshot. Initial load validates identity/version/schema, commits interrupted work and never replays effects. Media bytes/credentials are not included in evidence.

Upstream: role preprocessing and Chat context adapters. Downstream: Foundation-only Core contracts and Storage generic document interfaces. No Chat/model dependency, shared global history, role permissions, UI or device effects. Actor/repository lifetime belongs to Agent/runtime, independent of pages.

See [Support](../README.md), [Core](../Core/README.md), [Chat](../Chat/README.md) and [ADR0189](../../../../docs/adr/0189-agent-support-hierarchy.md). Failure/integration verification remains in [Validation-History](../../../../docs/Validation-History.md).
