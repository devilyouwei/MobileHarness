# ADR0100 — Camera control Tools reuse the App owner

Date: 2026-10-02. Status: accepted.

## Decision

Add Camera.open, Camera.close and Camera.flip in Tools/Camera with Support-owned registrations, CameraControlCapability and explicit failures. BehaviorAssembly requires the capability. Assistant JSON v5 declares the no-argument Tools; native model Tool event transport is still unsupported.

RuntimePresentation validates the active Assistant voice session before forwarding to the root CameraCoordinator. Controls must work while vision is off, so they do not depend on the vision presentation endpoint being bound. CameraCoordinator remains the only capture lease owner. Gateway Tool metadata does not request camera.capture again, which would conflict with the existing owner; the delegated host operation performs the lease-protected native effect.

## Completion and concurrency

The Tool layer has no queue. Coordinator rejects overlapping Tool commands; existing UI/scene latest-intent changes can supersede an admitted Tool and cause cancellation. Open/flip await capture reconciliation and validate permission/visibility; close joins capture release and vision cleanup. Open does not confirm pose model readiness. Cancellation after admission does not roll back intent; background teardown remains host-owned.

## Validation

Domain tests verify registration coverage, argument rejection before effects, completion-only feedback, cancellation and host-error propagation. Simulator builds validate App bindings. Physical lens/permission and provider-native Tool acceptance remain pending.
