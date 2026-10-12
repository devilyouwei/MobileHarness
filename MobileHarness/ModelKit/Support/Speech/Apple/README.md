# Apple PCM Conversion

## Summary

PCMCodec converts native Speech buffers to/from ModelKit mono Float32 values.

## Ownership and boundaries

Compiles into ModelKitAppleSpeech and depends on ModelKit/system audio frameworks. Caller owns mutable buffers and serial callbacks; this helper has no independent session, inference lease or worker.

## External relationships and data flow

The diagram shows runtime calls and data flow, not compilation dependencies.

```mermaid
flowchart LR
 Native[Native Float32 or Int16 buffer] -->|encode: channel average and copy| Frame[Mono Float32 AudioFrame]
 Frame -->|decode: copy at unchanged sample rate| Buffer[New mono native Float32 buffer]
 Buffer --> Converter[Apple recognition-owned native-format converter]
```

## Encoding rules

encode accepts 1–262,144 frames in native Float32 or Int16 buffers, handles interleaved or planar storage and averages input channels into mono Float32 at the original sample rate. Unsupported encoding, invalid frame count or invalid model samples fail explicitly. decode accepts mono Float32 AudioFrame and copies it into a newly allocated native buffer at the same sample rate. Caller-retained model payloads are not mutated.

✅ Explicit native/model PCM copying is implemented.

❌ Resampling and multichannel output preservation are not implemented. Recognition owns its native-format converter; consumers own playback adaptation.

## Related design

[Parent design](../README.md)
