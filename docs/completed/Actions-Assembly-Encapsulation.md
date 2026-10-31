# Actions assembly encapsulation

ActionsContainer creates and retains its private business assembly and business services. App supplies foundation capabilities, deferred media/device repository access and cross-module callbacks. A root factory that starts no device operations returns the root and explicit camera/device/UI host capabilities required before runtime configuration. App registers that root in its scoped registry. Business configuration remains a separate throwing stage after foundations start; cleanup is owned from construction, including stop before configuration.

Remove App construction/access of ActionsBusinessAssembly, BluetoothWorkflow and CameraStorageFactory. Narrow App adapters to Actions-owned public host protocols. Internalize the assembly and keep callback bridges in App. Update owning READMEs, overall design, architecture checks and validation; preserve existing unrelated changes. No new directories. Run check.sh and build-ios.sh. Device installation is separate from this refactor.

## Completion — 2026-10-31

ActionsContainer.makeBusiness now creates and retains the private assembly and business services, returning the root and ActionsHostCapabilities. App registers the returned root and adapts ActionsCameraAccess/ActionsDeviceAccess to Agent ports. configureBusiness(request:) uses only the internally owned assembly. Removed obsolete external assembly construction and preparation-cleanup registration helper. Validation is recorded in [Actions assembly encapsulation](../validation/Actions-Assembly-Encapsulation.md).
