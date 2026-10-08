# ADR0179 — Typed device, navigation and environment entry points

Accepted: 2026-10-08. Design precedes code.


## Typed device, navigation and environment entry points

✅ Implemented: app.interaction/1 maps explicit device commands and navigation destinations to fixed registered functions through ResourceManagement and the shared root transport. This Agent now coordinates native resource interactions as well as model resources; it performs no native I/O. UI controls emit typed intent through a root-owned BluetoothInteractionWorkflow; native BluetoothWorkflow remains the injected connection/recovery/manual worker host. Existing arrival tolerance, timeouts, pacing and takeover algorithms stay unchanged.

✅ Implemented: System.Device.control validates bounded string arguments and invokes neutral DeviceControlCapability; successful submission reports acceptance, not physical arrival. Read-only status and selected connection commands are explicitly model-granted. UI.Navigation.open commits native route state; manual taps and model requests share that function. A bounded latest motor-intent worker sends only changed values, with reset/stop priority and explicit failure display. No queued motion replay.

✅ Implemented: app.environment/1 stores latest sequenced scene/device/capability facts in the root Agent, with finite categories and bounded data. App still performs synchronous background/native safety fencing before reporting facts; physical safety cannot wait on Agent admission or iOS background execution. Native back navigation remains platform-owned and reports a fact, rather than replaying navigation effects. Photo-library creation and physical acceptance are feature/acceptance boundaries, not implied by navigation support.

No new directory or target. Existing host recovery ownership is retained because native safety/takeover must not await UI or an Agent queue. Removing that host state machine is not required to route user operations through Agent selection and canonical functions.

✅ UI now has zero project dependencies. App explicitly copies bounded history records into independently owned UI view values. Device admission guards reject foreground/worker/device conditions before acceptance; background safety remains immediate native fencing. Manual worker failures retain producer reports and enter the root Agent as independent trusted ActionResult, with no movement replay.
