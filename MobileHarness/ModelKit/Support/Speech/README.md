# Shared Speech Support

## Purpose and ownership

This directory owns helpers reused by speech providers, not generic Core mechanisms or concrete speech model algorithms. Apple PCM conversion is compiled once in ModelKitAppleSpeech alongside Apple ASR/TTS. It depends on ModelKit and native audio frameworks.

## Data and lifetime

Native Speech buffers are copied to/from validated ModelKit mono Float32 values. Providers own mutable buffers, callback serialization, resource leases and session completion. The helper owns no worker, queue, capture or playback.

✅ Shared Apple PCM conversion lives here. ❌ General resampling and multichannel output preservation are not implemented.

[Apple conversion](Apple/README.md) · [Parent design](../README.md)
