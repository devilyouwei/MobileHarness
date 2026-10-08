# ADR0182 — ApplicationControl Service Organization

Status: implemented and automatically validated; native acceptance pending. Date: 2026-10-08.

## Decision

Consolidate the existing remaining application-operation domains in `Agents/ApplicationControl/`, using `ApplicationControlAgent.swift`, `ApplicationControl.agent.json` and identity `applicationControl`. Replace ResourceManagement without a compatibility actor or identity alias. Photographer and Memory retain their role names and business ownership.

Co-located helpers group fixed function permissions and pure resource-result policy. Keep shared transaction state in the single actor; the App's renamed ApplicationControlIntentRuntime owns transport and lifecycle only. All effects remain registered calls through both Gateways. No new first-level module or dependency is introduced.

## Preserved contracts

Resource/Provider/device/navigation/environment Signal schemas, permission scope, bounded admission, joined cancellation, native safety, error chains and Actions algorithms remain unchanged. Rename only the private terminal control pair to application.control.finished/failed together with its sole transport consumer. Credentials stay outside Signals.

## Validation

Full ./scripts/check.sh passed, including596 integration and51 workflow tests, six Python tests, source/role boundaries, Swift formatting and plist checks. All212 Mermaid diagrams parse and local Markdown targets resolve. Required ./scripts/build-ios.sh fails at external CoreAIShared/CoreAI simulator resolution for arm64/x86_64; subsequent schemes are not reached. Unsigned generic iOS device clean build passed; final App contains exactly seven byte-identical source Agent configurations, including ApplicationControl and no stale ResourceManagement configuration. Automated fixtures do not establish native UI, live-model or physical acceptance.
