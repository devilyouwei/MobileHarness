# Passive Platform system State validation

Date: 2026-10-25. Checkpoint before implementation: 0fb86445 (325 files, prior container migration and documentation work). The checkpoint was committed before this feature; local signing and ignored assets were excluded.

[Completed implementation plan](../completed/Platform-System-State.md) records scope and ownership.

## Implemented scope

Eight native sources enter BasicSkill CURRENT STATE through an App-injected PlatformStateReading port: time, power, thermal, network, permissions, audio, locale and accessibility. Source selection and JSON envelope adaptation belong to Agents Support; SDK-independent Context mechanisms are preserved. Together with the existing business/UI readers there are thirteen registrations. No new directory, target, container or dependency is introduced.

Clock tests cover midnight/weekday, leap day, UTC/zone changes, repeated DST hour offsets and invalid input. Network/audio observation tests cover unknown values, latest replacement, reset and retired generations. Root tests cover pre-start/suspension/stop admission, repeated stop, changing injected clock/zone and a delayed resume superseded by newer invalidation. Context tests cover real JSON objects, fresh reads, invalid/oversized data and session closure. Existing photography/ReACT tests inspect native fields in actual model requests. Provider fixtures remain explicitly synthetic.

PlatformKit uses public system APIs and excludes route identifiers, device names, SSIDs, IPs, credentials and sensor streams. Reads do not request permission or activate hardware. Permissions do not confer cognitive/business authority; path availability is not provider reachability. Location/motion/depth/proximity and magnetic attachment remain outside this feature.

## Iteration evidence

- Initial PlatformKit compilation exposed a pure JSON helper inheriting MainActor isolation; marking that pure helper nonisolated fixed compilation.
- The first focused run exposed one missing try in the new test. After correction, all eight new focused tests passed; an existing Skill-state test failed in isolation because it lacked the explicit Action catalog trait. Both Context tests requiring canonical declarations now declare that fixture.
- Boundary checks rejected the initial Context placement of the SDK adapter. It was moved to Agents/Support without relaxing the Context import rule. The explicit Support classification was then updated for this neutral adapter.
- The first required full check stopped at a redundant initializer lint error; it was removed. The next full run passed the new behavior tests but failed only the existing instruction-byte budgets (base 23,927; photography 31,303). Native teaching was merged into the existing facts paragraph and repeated wording shortened; the original budget limits were preserved. Earlier failing results are not final pass evidence.
- A preliminary four-scheme iOS build passed before the final root-resume guard and resource refinements. Final-source builds must be recorded separately below.

## Final checks

- PASS: ./scripts/check.sh on final source and resources, including architecture boundaries, six Python tests, strict Swift formatting, all Swift package targets, 874 ordinary IntegrationTests and 221 isolated runtime tests, followed by plist validation. Log: `/tmp/mh-native-state-check-pass.log`.
- PASS: ./scripts/build-ios.sh on final source/resources, all four Simulator schemes. The main app's 25 Agent/Skill assets and Core protocol verify. Log: `/tmp/mh-native-state-ios-final.log`.
- PASS: original prompt budgets remain enforced. Final measured UTF-8 instruction sizes are base=23,120 (<23,500) and photography=30,496 (<30,500). The new fact block is independently bounded by the existing context limits; these byte counts are not a token/latency measurement.
- PASS: all 25 overall design Mermaid figures parse/render; the updated native/business read-path figure was visually inspected. Local references/anchors, unique Xcode navigation ownership for six new source/test files, source-path validity and git diff --check pass. The overall design remains English. Log: `/tmp/mh-native-state-diagrams.log`.
- Initial failed/aborted iterations remain described above. Final passing runs use the compact merged teaching and explicit test catalog traits. No failed earlier result is relabeled as a pass.

## Evidence limits

Synthetic tests and simulator builds do not validate real battery readings, live routes/mute/interruption, permission UI behavior, native timezone/accessibility changes or physical-device behavior. No new real-provider request, sensor activation trial, phone installation or physical acceptance is claimed. The earlier phone installation predates this feature. Host-local logs use /tmp/mh-native-state-*.
