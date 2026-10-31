# App responsibility cleanup

App owns Container lifetime, dependency injection, application entry and application-wide foreground/visibility coordination. Move resource context/lease interpretation and coordinated acquisition into Gateway. Narrow App resource adapters to public operations, preserving existing lease-held versus transient/handoff semantics.

SpeechPerceptionContainer exposes one complete session presentation capability with stable identity; remove redundant optional field projections and App reconstruction of readiness. ApplicationPresentation.prepare requires the application bootstrap and never independently starts Agents.

Agents declares required model capabilities. ModelKit maps those requirements to readiness/preparation operations and interprets native model status; App maps generic steps into its lifecycle-owned preparation runner and controls activation. Foundation independence is unchanged.

Remove unused healthSummary/healthProjection/diagnosticProjection, forest aggregation and their tests from ApplicationStateInspection; retain exact-path reads, bounded explicit trees and failure journal in its existing owner. Remove stale public-assembly claims and current-design references to retired projections. Historical records remain historical.

Affected owners: App/Composition, Gateway/Output/Resources, ModelKit, Agents/SpeechPerception and AgentContainer; owning READMEs, overall design, boundary checks and regression tests. No new directories. Verify with check.sh and build-ios.sh. Real-device acceptance remains separate.

Additional evidence: ApplicationContainer filters model lifecycle admission errors before business publication. Consolidate that predicate into Agents' existing NativeFailureClassification alongside platform classification; remove the unused sink predicate parameter. Preserve cleanup failures and original journal evidence, and use existing failure-channel regression coverage.

## Completion — 2026-10-31

Implemented all scoped changes. Gateway owns resource context resolution, lease acquisition coordination and atomic settlement interpretation. SpeechPerception exposes a complete stable session presentation and invalidates stale debug validation on stop. UI preparation requires App bootstrap and never starts Agents separately. Agents declares model requirements; ModelKit supplies readiness/preparation steps. Removed unused health/diagnostic projections, forest aggregation, dependent tests and stale documentation. Consolidated model lifecycle publication classification into the existing Agents failure classifier, preserving cleanup evidence. Removed obsolete App imports and duplicate module-specific preparation code.

Validation: [App responsibility cleanup](../validation/App-Responsibility-Cleanup.md). No remaining implementation items from this plan; device installation and physical acceptance were not part of this refactor.
