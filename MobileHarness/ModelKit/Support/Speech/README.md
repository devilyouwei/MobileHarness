# Shared Speech Support

## Purpose and ownership

This directory owns helpers reused by speech providers, not generic Core mechanisms or concrete speech model algorithms. Apple PCM conversion is compiled once in ModelKitAppleSpeech alongside Apple ASR/TTS. It depends on ModelKit and native audio frameworks.

## Data and lifetime

Native Speech buffers are copied to/from validated ModelKit mono Float32 values. Providers own mutable buffers, callback serialization, resource leases and session completion. The helper owns no worker, queue, capture or playback.

Shared Apple PCM conversion lives here.

[Apple conversion](#apple-pcm) · [Parent design](../README.md)

<a id="apple-pcm"></a>

## Apple PCM conversion

[`Apple/`](Apple/)

[PCMCodec.swift](Apple/PCMCodec.swift) compiles in `ModelKitAppleSpeech`. Encoding accepts 1–262,144 native Float32 or Int16 frames, averages channels from planar or interleaved storage and copies to mono Float32 at the source sample rate. Decoding copies mono Float32 into a new native buffer at that rate. Invalid frames or formats fail explicitly. Apple ASR owns its native-format converter. The caller owns buffers, callback serialization and completion.
