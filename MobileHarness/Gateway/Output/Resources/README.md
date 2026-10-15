# Exclusive Resource Ownership

## Summary

Actor-owned arbitration for declared function and host resources, with live permits, bounded handoff and joined cleanup.

## Ownership and boundaries

App injects concrete owner/preemption/stop policy. holdings is the sole occupancy authority; device health, physical stop and Channel ordering are separate. ResourceCoordinator owns leases/uses/cleanup, not business retry or native isolation.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Actions[Scheduled Action execution] --> Coordinator[ResourceCoordinator]
 Tools[Direct Tool execution] --> Coordinator
 Host[Authorized host lease] --> Coordinator
 Policy[Injected ResourceDefinition] --> Coordinator
 Coordinator -->|Revocable execution permit| Handler[Function or host worker]
 Handler -->|Joined return or throw| Coordinator
```

## State and authority

Public snapshots are unlocked or locked(ExecutionOwner?); nil means host use. Internally holdings carries lease/use/handoff tokens. Release/late completion removes only its matching token. There is no faulted health latch or recover API. Definition declares owners, lease requirement, executionGroup, explicit preempts and stop callback; intersecting multi-resource siblings retire together.

run reserves the actual writer before starting its task, binds owner/held IDs/ResourceExecutionPermit and removes matching transient holdings after joined return. Effects validate the inherited permit; ended/revoked/handoff uses reject. Caller cancellation remains cancellation. Lease-bound effects also check live lease/deadline.

## Handoff and cleanup

Unconfigured conflicts fail busy. Reserve all affected siblings before awaiting stop/cancel/revoke/join. Successful handoff remains reserved until the exact requester grants or retires it. A timed-out request abandons its reservation and fails; coordinator-owned cleanup continues and automatically unlocks only after all old writers end. Late cleanup cannot grant timed-out work or replay it. Stop error after joined cleanup unlocks and propagates to that request.

Release/expiry/owner closure/shutdown observing an existing handoff uses bounded cancellation-independent acknowledgment. Persistent leases end on explicit release, expiry, closure or authorized takeover; an individual lease-bound Action ending does not release them. Uncooperative work stays occupied.

| Boundary | Limit / policy |
| --- | --- |
| Resource definitions / owners each | 64 / 128 |
| Requested resource set / live leases | Eight / 32 |
| Active uses / retained cleanup attempts | 256 / 32; unfinished cleanup retained |
| Cleanup subscribers | Eight capacity-one completion streams |
| Lease duration | >0 through 60 seconds, explicit renewal |
| Cleanup acknowledgment | Actual stop/join; no elapsed-time deadline |
| Resource waiting queue | None; conflicts/capacity explicitly fail |

Production camera capture requires its persistent lease. NexArm's six motors share a writer group; concrete takeover is composed by App. Manual Settings control is an explicit host bypass. Software cleanup never proves hardware stop/arrival/clearance.

Live occupancy, revocable permits and late-cleanup-safe handoff are implemented.

## Related design

[Parent design](../README.md)

## Channel-owned Action ordering

Action metadata has no serialization key. [ChannelScheduler](../Scheduling/README.md) owns task-local FIFO/wait ordering; ResourceCoordinator rejects unconfigured conflicts without a queue and preserves explicitly configured joined takeover.

资源交接/关闭无默认五秒清理超时，等待停止与真实 join 后确认资源释放；取消不伪造清理完成。设备显式安全租约的期限保持独立，不作为对话时限。

## Handoff state flow

```mermaid
flowchart TD
    Request[Requested resource set] --> Conflict{Live conflicting owner?}
    Conflict -->|No| Grant[Grant matching live token]
    Conflict -->|No configured takeover| Busy[Reject busy]
    Conflict -->|Authorized takeover| Reserve[Reserve affected siblings]
    Reserve --> Revoke[Revoke old permits and cancel / stop]
    Revoke --> Join[Join old writers and cleanup]
    Join --> Valid{Requester and cleanup still valid?}
    Valid -->|Yes| Grant
    Valid -->|Caller cancelled / scope closed| Retire[Retire requester without granting]
    Join -->|Old work has not ended| Retained[Keep coordinator-owned occupancy]
    Retained -->|Actual old completion| Unlock[Remove only matching tokens]
```

没有默认清理确认时限。取消调用者不会将未完成 cleanup 当作完成；独立 coordinator owner 继续持有资源直到旧 writer 实际退出。显式安全租约期限与清理 join 是不同机制。

## 待实现

- Durable leases, global fairness and forced unlock of unfinished native work are not implemented.
