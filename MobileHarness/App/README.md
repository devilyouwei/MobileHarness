# App — Application host and composition root

## Responsibilities and direct interfaces

App creates and retains the unique scoped roots, injects narrow public interfaces, connects scene/system callbacks, and governs startup, foreground transitions, joined shutdown, rollback and replacement. It does not interpret business intent, consume business requests, encode Signals or register individual functions.

| Neighbor | Public relationship |
| --- | --- |
| iOS / Scene | Activity changes and background URLSession callbacks. |
| Storage, ModelKit, PlatformKit, UI | One root per scope; aliases reference owning root capabilities. |
| Actions | One ActionsContainer plus Actions-owned public business assembly and execution/catalog ports. |
| Gateway | One GatewayContainer configured with neutral execution, resource mechanisms and result delivery. |
| Agents | One AgentContainer receiving Gateway ports, immutable metadata and neutral host collaboration ports. |
| AppLifecycle | Generic ManagedService graph, preparation, rollback and foreground barriers. |

## Internal structure

[Composition](Composition/README.md) owns registration, factories, public adapters and lifecycle installation. [Lifecycle](Lifecycle/README.md) owns the generic graph and preparation/system callback mechanisms. MobileHarnessApp mounts UI.ApplicationRootView and forwards Scene state. ApplicationPresentation composes existing UI/role interfaces; pages do not own module work.

ServiceFactories creates roots and thin adapters. Actions constructs domain services and business functions; Agents constructs cognitive roles and policy. App binds Task control/perception/resource collaboration without decoding business schemas or reaching into implementation state. Domains, modules and functions have no App registrations or peer containers.

## Lifecycle and failure

Construction is inert. Startup orders diagnostics → storage → model → platform → ui → executionBindings → actions → gateway → agents → homePreparation. The foundation readiness edges do not create foundation compile dependencies. executionBindings prepares metadata/services, validates Skill coverage and installs host ports before business admission; it does not operate devices.

Shutdown reverses that order. Agents closes requests and joins roles; Gateway joins scheduling, execution, transport and delivery while Actions remains available for cleanup; Actions joins native/business work; executionBindings finally unbinds. Startup failure rolls back the current node and completed stages while preserving original and cleanup failures. A failed cleanup prevents replacement.

Initial inactive waits for active. Synchronous invalidation closes admission before asynchronous pause. Rapid reactivation completes necessary suspension first. One replacement task coalesces retries and rechecks foreground state; there is no replay queue. Durable records/media remain independent from runtime work.

ForegroundPreparation is root-owned and active only for visible foreground home. It uses public readiness/preparation interfaces, independently of ordinary conversation waiting. Background artifact restoration may use the same model/storage roots before foreground startup; replacement still joins those owners. Native UI, real-model and physical-device evidence remains separate in [validation](../../docs/validation/README.md).

## System facts and context injection

App binds the existing complete classified State inspection read into Agents. It does not mirror native facts or generate model context. Passive native observation follows Platform lifecycle; Agents requests selected snapshots while its own request admission is live. See [composition](Composition/README.md#native-state-capability-binding) and the [overall State path](../README.md#container-state-read-path).

Application observations flow to the Agents-owned summary source; App does not bind a generic environment-query callback into Actions. Navigation is read from its existing UI State owner. See [composition](Composition/README.md#observation-and-query-composition).

## Reflexive composition

App binds the seven already-owned module state ports into the exact-path ApplicationStateInspection reader registry. Generic structural encoding stays in that composition adapter; modules own domain fields and state transitions. Agents receives the complete unfiltered inspection read. Assistant selects explicit Business fields in its own source bindings, while Skill useStates continues progressive disclosure. Other internal consumers choose independently. No tree tool, background sampler or automatic repair is added. See [Composition](Composition/README.md#internal-state-inspection).

Container snapshots are local; App exact-path resolution does not sample ancestors. Full diagnostic traversal is an explicit inspectTree operation, not the read callback injected into Assistant.
