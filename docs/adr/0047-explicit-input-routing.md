# ADR 0047 — Explicit input routing

> Configuration migration: [ADR 0061](0061-agent-json-v5.md) supersedes the JSON schema, hidden/text alias and all-in-JSON registration portions of this historical decision. Its other runtime contracts remain unchanged.

Accepted: 2026-09-27.

## Context

Production InputGateway already uses immutable JSON v4 CommunicationPolicy. SignalRouter and LogicRouter survived only as a policy-free fallback in submit, and some tests silently sent unspecified inputs to Assistant. This duplicated routing choices and kept obsolete future-model-router assumptions in Gateway.

## Decision

Remove Input/Routing, its protocol/default router, the injected router property/parameter and the submit API. Keep two explicit external-input operations:

- publish requires CommunicationPolicy and uses exact configured subscriptions. No policy fails with unsupportedContract; no subscribers fails with noRecipients.
- send requires a target and bypasses subscription matching while retaining declared input validation when a policy is installed, descriptor support, source, identity/session and bounded admission checks.

Policy-free construction remains available for explicit directed admission in isolated compositions/tests. It provides no implicit recipient selection. Production continues to install the complete JSON policy; making policy mandatory for every isolated composition is not part of this change.

ToolDispatcher returns data ToolResult through send to the original Agent/session and preserves turn context. Void Tool behavior is unchanged. Tests needing subscription routing build actual CommunicationPolicy declarations; explicit test inputs use send.

## Unchanged contracts

Internal AgentMessaging publish/send, bound sender identities, Bus queues, latest-state replacement, deadlines and per-target admission receipts are unchanged. No dynamic routing, model inference in Gateway, retry or new transport queue is introduced. AgentInput remains the shared input type.

## Consequences and validation

This intentionally removes a public compatibility API. Callers must choose publish with a policy or send with a named target. SwiftPM exclusions and Xcode navigator references are cleaned up with the deleted directory. Historical design sources remain preserved.

Regression coverage verifies publication without a policy or matching subscriptions cannot reach Assistant, direct send works without subscriptions but respects input declarations, unavailable subscribers do not suppress successful recipients, and Tool result/session correlation remains intact. Run scripts/check.sh and scripts/build-ios.sh with full Xcode; physical-device behavior is not established by this API cleanup.
