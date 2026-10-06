# ADR0163 — Typed history intent and feedback causality

Accepted: 2026-10-07. Agent-Driven-App.md updated before code.

Require immutable SignalCausality on scheduled results and activity events. Capture initiating envelope identity, preserve root/turn, advance one hop at runtime feedback admission and reject exhausted/invalid contexts. Fresh bounded admission does not inherit an expired execution input deadline. Preserve owner fencing, bounded result retries, cancellation joins and effects independently of feedback delivery.

Migrate history refresh/delete/cancel to typed history.intent/1 domain content using the existing AgentMessage transport and schema registry. Business enums remain outside AgentCore. Cancel retains its trusted host external-source route; generic control authority remains future work. Host-only camera activities use an explicit lease root. No new model permission or business algorithm is introduced.

✅ check.sh passed: all511 integration and37 workflow tests, boundaries, formatting and metadata. New tests cover expired initiating deadlines, non-root causal chains, turns/sequences, Action/activity hop closure, schema mismatch and legacy history rejection. ✅ Unsigned iOS device build and six packaged Agent configurations passed. ✅ All196 MobileHarness Mermaid diagrams parse. ❌ Required simulator build remains blocked by external CoreAIShared's unavailable CoreAI dependency; later schemes were not attempted. No new physical acceptance claimed.

Next: typed remaining host controls, then archive/title Agent policy, settings/device routes and bounded model continuation.
