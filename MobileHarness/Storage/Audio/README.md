# StorageAudio — Scoped PCM Handles

## Summary

Share bounded, single-use PCM streams between independent synthesis and playback owners.

## Ownership and boundaries

Depends only on Storage. The store owns bytes/handles and exact caller identity, without ModelKit, PlatformKit, scheduling or inference. Producer completion differs from player drain.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Producer[Speech synthesis owner] -->|register, begin, append, complete| Store[SpeechAudioStore]
 Player[App playback owner] -->|checkout, next, release| Store
 Scope[App input/session cleanup] -->|cancel or shutdown| Store
 Store --> Stream[BoundedMemoryStream]
 Store --> Lease[MemoryLeaseStore]
```

## Values and ownership

`SpeechPCMFormat` supports 8…192 kHz, 1…8 channels and Int16/Float32 encoding. Frames are nonempty, aligned, bounded to 1 MiB and sequenced. Callers convert backend/platform values into these independent types.

`SpeechAudioStore.Owner` is source/session/input, mapped to namespace `speech.pcm`. Default store capacity is 32, each stream allows 8 MiB and 2048 items. Queue/ready TTL and reader timeout default to nil: the owning input/session must retire handles. Terminal failures retain at most 128 tombstones without TTL; input/session retirement removes them.

`register` installs cancellation ownership, `begin` starts producer use, `checkout` admits one matching reader, and `release` retires it after playback. `complete` finishes the stream but does not prove hardware drain. Exact-owner checks prevent cross-turn reads. Scope cancellation/shutdown joins cancellation hooks and fails waiting reads; failure translation preserves producer errors.

## Stream behavior

Append rejects capacity overflow; it has no producer backpressure wait. One `next` waiter is allowed. Finish drains queued PCM then returns nil; failure/cancellation drops queued bytes and wakes the reader with the original error. Playback and inference deadlines belong to their owners. The standalone `SpeechAudio` initializer defaults to 1 MiB, while the shared store explicitly supplies 8 MiB.

✅ Single-checkout handles, bounded PCM, owner-scoped cleanup and error retention.

❌ Durable PCM storage and multi-reader/mixed playback.

## Related design

[Parent design](../README.md)

## Lifecycle-owned conversation and audio (2026-10-12)

✅ 已移除对话生成、ReACT、收件箱排队、结果屏障、ASR 收尾、TTS 合成及回复占用租约的计时终止。Signal 默认无过期时间，框架不再按通信契约附加 TTL。保留显式实时感知数据的新鲜度和网络传输自身超时；它们不作为对话/语音缓存生命周期。Action 自身超时通过原始执行者的 ActionResult 返回。请求/调用数及队列/PCM 容量仍有界，不以计时自动删除已接纳输入。语音句柄无读等待或错误记录 TTL，按播放完成、输入/会话正常结束、异常或显式取消清理；取消加入生成和播放工作。





✅ Storage repository refactor: Audio continues using common bounded memory/lease contracts; no SQLite, file backend or third-party package dependency is introduced.
