# ADR 0039 — Platform Capability Domains

Status: accepted, 2026-09-26.

## Context

Top-level Audio and Camera used different classification levels. ModelKit already groups model capabilities by domain; PlatformKit should use the same organizing principle for device input/output.

## Decision

- Audio owns microphone/speaker I/O and shared audio-session setup.
- Vision replaces Camera and owns camera acquisition, preview source and frame adaptation.
- Connectivity replaces ExternalDevice and holds the existing external-device transport contract.
- Core replaces Device for cross-domain capability/permission contracts, an explicit shared-foundation exception.
- Keep existing type names and flat domain files. Do not split AppleAudioIO resource ownership or create placeholder MicrophoneDevice/SpeakerDevice wrappers for directory symmetry.
- ModelKit owns model-driven data processing; PlatformKit owns hardware/OS I/O. App bridges the layers without adding dependencies between them. Agent owns business decisions; Gateway routing remains unchanged.

## Consequences and validation

✅ Source relocation, SwiftPM README exclusions, Xcode navigation and current architecture docs follow the domains. Public APIs, scheduling, buffer lifetimes and singleton ownership are unchanged.
❌ Concrete transport implementations and physical-device behavior acceptance are outside this directory migration.

Validation: root scripts/check.sh passed (including 69 IntegrationTests); all four scripts/build-ios.sh simulator schemes passed. All PlatformKit files resolve in Xcode navigation, each domain has a README, and old paths remain only in migration-history text. No physical-device installation or acceptance was performed.
