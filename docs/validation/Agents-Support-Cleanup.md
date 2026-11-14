# Agents Support consolidation validation

Date: 2026-11-14.

## Scope

The [plan and inventory](../requirements/technical/Agents-Support-Cleanup.md) covers 87 original Swift sources and 78 remaining sources. Nine adjacent-contract files were merged into their owning files. Module/target dependencies, execution routes, cancellation and result ownership remain unchanged. Two unused HarnessError handler-registration cases and six unsupported OutputKind cases were removed; Actions-owned registration errors and actual emitted output kinds remain. The forbidden-output fixture now uses an empty permission set.

## Static checks

- Repository architecture/boundary checks passed after updating the AgentID source lookup and Support file allowlist.
- Seven model-download Python tests passed.
- Strict Swift formatting passed in the required check run after correcting the merged OutputEnvelope import order.
- Changed-document relative paths and English/Chinese catalog format placeholders passed inspection.
- No remaining current-source/script/document references point to the nine deleted files. Historical records were not rewritten.
- Every remaining top-level Support type has another Swift reference in application or test sources. This is a static reference check, not a proof that every member is reachable at runtime.
- Xcode project syntax and diff whitespace were checked; only the nine obsolete project file objects/references were removed.

## Behavior coverage

ActionActivityTests covers selected-language completion/status, formatted issue counts and motor/target/observed values, unchanged canonical paths and raw return/diagnostic values. A task-log test checks Chinese titles through the injected language reader while retaining typed admission and executor identity. Existing tests retain the English-default API and Action/Tool completion semantics.

## Execution results

The initial sandboxed check could not write the external Swift module cache. An authorized run passed architecture checks, Python tests and formatting, then failed to compile the unchanged UI/Conversation/ListeningHalo.metal. Direct invocation of Xcode's metal compiler confirmed that the installed Metal Toolchain is missing. This is not a passing automated-test result.

`./scripts/build-ios.sh` exited with status 65 in the first Simulator application scheme. The explicit diagnostic again reports the missing Metal Toolchain while compiling ListeningHalo.metal; the build also lists two interrupted/failed Live Activity link steps without a separate linker diagnostic. Bundle verification and the three later ModelKit schemes were not reached.

The native Swift build system compiled the package and both new localization regressions passed. Its resource handling copies string catalogs unchanged, so the installed `xcstringstool compile` processed Localizable.xcstrings into the generated HarnessKit_UI.bundle before execution. This preparation touched generated build resources only. The native build-system option is deprecated; this result does not turn the default check into a pass.

The final incremental run uses `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --build-system native --filter 'actionActivity|taskLogUsesInjectedPresentationLanguage|capabilitiesRejectUndeclaredActions'` to cover localization, existing Action presentation and output-permission rejection against the final source state. All eight selected tests passed. Final architecture checks, changed-source strict formatting, document paths, catalog placeholders and diff whitespace also passed.

Logs: `/tmp/agents-support-check.log`, `/tmp/agents-support-ios.log`, `/tmp/agents-support-native.log`, `/tmp/agents-support-final-tests.log`, and `/tmp/agents-support-boundaries.log`.

The full default automated-test suite and iOS build remain unverified until the Metal Toolchain is available. Automated fixtures and compilation do not establish native UI, real-model or physical-device acceptance.
