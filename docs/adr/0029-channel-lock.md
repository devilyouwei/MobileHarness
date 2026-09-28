# 0029 — Exclusive Channel Ownership

> Scheduling update: [ADR 0059](0059-structured-wait-scheduling.md) supersedes shared cross-task Channel lanes and introduces typed nested wait groups. This document retains its historical decision context; Channel ownership/takeover remains planned.

Status: ownership value definitions implemented; runtime lock behavior is design-only.

## Decision

Channel lock means one authorized Agent runtime instance/session owns a finite lease over an atomic channel group. Owner Actions retain ordinary capability, FIFO and resource checks; other calls to the protected domain fail explicitly. Agent perception/input delivery is independent of ownership.

The scheduler defines ChannelLockOwner and ChannelLockState in Channel.swift. Current Channel.lockState is immutable unlocked. There are no acquisition/enforcement methods, no implicit lock Action/XML syntax and no active robot-control behavior.

Planned lock control enters through OutputGateway runtime APIs, with outcomes through InputGateway. Multi-channel grants are all-or-none; conflicting owners fail without waiting or implicit priority takeover. Trusted lease identity is runtime metadata, never model parameters.

## Decision ownership

- Agent B sends facts, current state and optional advice to Agent A.
- Agent A decides whether to request a lock; the runtime authorizes and performs takeover.
- Signals never grant ownership. See the [general interaction](../../MobileHarness/Agents/Core/Communication/README.md#signals-and-control-takeover).

## Takeover and physical boundaries

Immediate takeover is the sole initial mode: cancel queued work and interrupt active control before granting the lease. A wait-for-current-action mode is outside initial scope.


A successful takeover gates new conflicting calls, explicitly aborts affected input work, joins running handlers and requires adapter quiescence acknowledgement. It does not itself perform business hold. The owner must separately execute hold and await device acknowledgement.

Channel names are logical scheduling scopes. Device control requires App-defined resource domains covering every ActionPath and other route to the same hardware, including main-channel calls and side-effecting Tools. Admission and execution-time lease checks plus device generation fencing prevent bypass and stale callbacks. Existing module exclusion is insufficient for persistent ownership.

Expiry, release, owner/session termination and shutdown invalidate admission, stop/join affected work and follow resource-specific safe cleanup. Uncertain cleanup leaves the domain gated for supervisor recovery. Unlock never replays old Actions or automatically resumes motion. Hardware safety cannot rely on iOS remaining active.

The normative overview is [section 20.1](../../MobileHarness/README.md#201-channel-lock--exclusive-agent-control); full lifecycle, bounds, scenario and required tests are in [Scheduling](../../MobileHarness/Gateway/Output/Scheduling/README.md#channel-lock-design). Runtime APIs and enforcement must be delivered together before making the ownership state mutable.
