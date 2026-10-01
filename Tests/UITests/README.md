# UI State and Interaction Tests

Purpose: verify page state and injected-operation behavior without App, model or device implementations. Design goals: deterministic completion signals and independent module compilation.

Root Package.swift compiles this directory as UITests against the UI module. These are Swift unit tests for state and operation contracts; native UI automation remains separate.

✅ Configuration saves remain admitted across page disappearance/discovery cancellation; overlapping saves reject, failure releases the slot and retry succeeds. Repeated restoration preserves unsaved edits.

❌ Native rendering, navigation gestures and physical-device layout/animation acceptance.

✅ Composed Action history tests preserve all child issue descriptions beyond the compact summary. ❌ Real-device accessibility and long-history visual acceptance remain outstanding.

✅ Action-result translation tests moved to AppWorkflowTests, matching the App-owned mapping boundary.
