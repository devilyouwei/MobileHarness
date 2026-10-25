# Execution layer cleanup validation

Date: 2026-10-25. Environment: local macOS, full Xcode / Swift 6.4.

## Scope and baseline

This audit starts from the uncommitted Actions-container implementation already present in the workspace, not Git HEAD. Existing migration changes and unrelated workspace edits are preserved. It changes source organization, unused adapters and duplicate helpers; App lifecycle, function addresses, scheduling, permissions and native completion semantics remain the existing contracts.

| Source tree | Swift files before | After |
| --- | ---: | ---: |
| Agents | 154 | 151 |
| Gateway | 13 | 13 |
| Actions (including FunctionContracts and runtime targets) | 195 | 192 |
| Total | 362 | 356 |

Nine former file paths are removed and three consolidated/renamed files own their live contents. File count alone was not a deletion criterion. Removed unused code includes CameraSessionConnections, retained execution/catalog fields in AgentObservationAccess, the unused ActionDispatcher root-shutdown forwarder and duplicate failure-report normalization.

## Structural checks

- The boundary checker now requires complete Swift/README/JSON navigation coverage in these three Xcode subtrees, unique file references, correct physical-directory membership and no retired directory groups.
- Reconciled 46 duplicate file references, five retired directory groups and twelve unreachable empty migration groups. New live files are present in their physical owning groups. The existing App resource adapter is grouped under App/Composition.
- This is a navigation/source ownership audit of the three execution layers; it does not certify unrelated Xcode subtrees.
- Existing target identities, dependency directions and explicit runtime source lists remain unchanged.
- All local path links in the 56 directory READMEs of the three audited trees resolve. No physical directory or compilation target was added.
- Project property-list validation and diff whitespace checks pass.

## Automated and build results

Both required commands completed successfully (exit 0):

- `./scripts/check.sh`: dependency/source ownership checks, six Python tests, strict Swift formatting, the complete ordinary test phase (including 865 IntegrationTests), the isolated LiveRuntime phase (221 tests), other package test targets and final project/property-list checks passed.
- `./scripts/build-ios.sh`: MobileHarnessSimulator, ModelKitRuntime, ModelKitNemotron and ModelKitSilero all report BUILD SUCCEEDED.
- The final boundary checker was rerun after project navigation cleanup and passed. All 56 audited directory README path checks and final diff whitespace checks passed.

Logs: `/tmp/mh-layer-check.log`, `/tmp/mh-layer-ios.log` and `/tmp/mh-layer-final-boundary.log`.

The added ContainerContext regression verifies preservation of already encoded JSON bytes, object-valued snapshot collection and propagation of actual source errors. Existing context generation, bounds and cancellation tests exercise the shared implementation.

The first structural attempt rejected the consolidated namespace file because the checker still assumed three former namespace file paths; the checker was updated to inspect the single canonical namespace declaration file while retaining declaration/callable-owner checks. No runtime fallback was introduced.

Compiler warnings from generated Action validation prefixes and an existing test capture are recorded in the logs; this cleanup does not remove argument validation to silence unused-local warnings.

## Evidence limits

These checks do not perform a new real-provider/model inference run, native iOS interaction acceptance or physical-device/robot-arm acceptance. Native/device behavior is retained, not newly certified by source consolidation or Simulator compilation.
