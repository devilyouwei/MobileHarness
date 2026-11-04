# ModelKit Chat concurrency and local FIFO

Date: 2026-11-04. Scope: only the former independent Chat lease/slot mechanism. Thinking policy, output defaults/stream framing, HTTP diagnostics and network-timeout fixes remain in place.

## Implemented contract

- One ModelContainer owns model clients and execution. ChatModel is an immutable configuration/capability handle with optional modelName; it has no close/reopen or reserved inference slot. Writer retains the same selection for its run through pauses/questions and discards it at terminal cleanup.
- `language.chat(request)` snapshots the default selection; `language.chat(request, using: configuration)` and `chatModel(configuration:)` select explicitly. Explicit nil selects local. Configuring a new default does not replace active clients or mutate existing selections.
- Cloud clients are reused by immutable configuration in the existing ModelManager registry. The inherited registered-resource capacity remains, distinct from in-flight HTTP/session count. There is no fixed two-request/Writer slot pool. OpenAI resources explicitly permit multiple active lease IDs; each HTTP task/decoder/event stream/cancellation belongs to one request. Other providers remain exclusive by default.
- Local Chat calls share SerialChat per SDK root: one running and eight waiting by default. The nonnegative ModelContainer initializer parameter maximumPendingLocalChats configures waiting capacity (zero permits no waiters). Overflow throws inputBusy before returning a handle. Already finished handles consume no queue capacity.
- Accepted local sessions initially expose queued, then running and terminal phase. Cancelling a queued session immediately makes its capacity reusable. Cancelling/failing a running consumer joins native cleanup before advancing FIFO. Root suspension/stop cancels queued work and joins running work.
- InferenceSession.waitForCompletion and withCleanup join native Chat request cleanup. Both actual Chat adapters bind their worker lifetime; Writer control/content consumers and Assistant ChatDriver use the SDK scope helper on success, early return, cancellation and errors. They do not unload model clients.

## Automated evidence

New deterministic tests exercise twelve hanging URLProtocol requests on a single OpenAIChat/client/resource context; cancelling one leaves the rest running, and shutdown joins all. This is real Foundation HTTP-session plumbing with explicit URLProtocol transport, not a live provider.

Local fake-provider tests cover one-running/eight-waiting capacity, overflow, immediate cancelled-slot reuse, FIFO ordering, native cleanup barrier, success/failure advancement, cancelled queued work and retained completed handles. A consumer-error test verifies the error returns only after native cleanup and the next request cannot overlap. Root configuration tests cover selection retention, reuse and shutdown fencing without network/GPU execution.

Initial compilation caught missing worker-join forwarding and an obsolete state field reference; both were corrected. The first full check exposed two old cloud tests expecting inputBusy on overlap. Those assertions were replaced with concurrent-session and cancellation/replacement-isolation assertions; that interrupted run is not counted as passing.

Targeted post-fix evidence: `/tmp/model-chat-concurrency-final-targeted.log` and `/tmp/model-chat-concurrency-final-tests2.log`. Writer's twelve native-tool workflows passed with the new fixed selection handle. Complete check/build results follow after completion.

## Boundaries

Local scheduling tests use an explicit fake provider and controlled cleanup continuation; actual local-model GPU/phone execution has not been accepted here. No new live-provider, simulator UI or physical-device acceptance is claimed, and device SQLite is not reset. Existing Provider/Writer model experiments remain evidence for their own source versions.

## Final verification

`./scripts/check.sh` exited0: `/tmp/model-chat-concurrency-check-final.log`. Architecture boundaries, Python checks, strict Swift formatting and plist checks passed. All configured test products passed, including1014 main integration tests,225 isolated native runtime tests (206.736s), the SDK cloud/local cases and twelve Writer workflow variants. The local consumer-error cleanup barrier test passed as part of the full check.

`./scripts/build-ios.sh` exited0: `/tmp/model-chat-concurrency-ios.log`. MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero all built; packaged Skill/Core declaration and Live Activity resources verified. `git diff --check` passed. No real-model/phone/GPU-local acceptance was performed or inferred from these builds/fixtures.

## Physical-device installation (2026-11-04)

At the user's request, built the current working tree with the signed MobileHarness Debug device scheme and command-only CURRENT_PROJECT_VERSION=2026110401 override, using existing local signing settings. Build, strict/deep signature verification, all30 packaged Agent/Skill assets and Live Activity resources passed. No signing/project configuration was edited for installation.

Installed over the existing App on the paired iPhone17 Pro (installation sequence5884). Device inventory independently confirmed version0.1.0/build2026110401; launch succeeded and process inspection showed MobileHarness PID19836 and Live Activity extension processes19837/19838. No uninstall or explicit data reset was performed. This establishes installation/startup, not real-provider concurrency, local-GPU or voice/Writer interaction acceptance.

Evidence: `/tmp/mobileharness-device-2026110401-build.log`, `/tmp/mobileharness-device-2026110401-install.log`, `/tmp/mobileharness-device-2026110401-launch.log`.
