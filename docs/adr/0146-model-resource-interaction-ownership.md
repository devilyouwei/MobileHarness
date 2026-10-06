# ADR0146 — Model Resource Interaction Ownership

Date: 2026-10-06. Status: implemented.

## Decision

Move model-resource operation coordination from UI.ModelResourcesState into the existing independent AppSettingsWorkflow target. Root composition retains ModelResourceInteractionWorkflow; views receive its required ModelResourcesControlling protocol and passive observable state. Download/remove/cancel are typed intents rather than arbitrary strings.

The feature owns32-slot bounded pending admission, explicit overflow rejection, duplicate blocking, cancel-after-download-admission ordering, retained locks when refresh fails, source save before download and independent voice-switch rollback. Caller/page cancellation leaves admitted resource work owned by the root workflow; explicit cancel remains separate. Management retains actual download/install/remove mechanics.

Move ModelResourcesOperating, installation requirements and ModelResourceSelectionError into the feature. Publish installedGroups and operation snapshots for UI status/availability projection. UI retains presentation labels, form edits and confirmation; it imports no effects or business services.

## Consequences

✅ The UI target remains independent. Existing source/installation transactions and model bindings are preserved, and former UI operation tests follow their owner into AppWorkflowTests. No new dependency or feature target is added.

❌ Resource Agent/Gateway routing, cloud SettingsState coordination, shared source schema/catalog extraction and page polling/debounce triggers remain later stages. This change does not claim conversational resource management.

## Validation

✅ Full check.sh,12 final focused tests and unsigned iOS device build passed. ❌ Simulator CoreAI dependency and native interaction/transfer acceptance remain separate; see [dated evidence](../Validation-History.md#2026-10-06--model-resource-interaction-ownership).
