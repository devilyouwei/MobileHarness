# Apple SpeechAnalyzer Recognition

## Summary

Modern native recognition with transcriber/detector, required locale assets and request-local ordered PCM.

## Ownership and boundaries

Depends on ModelKit/system Speech frameworks. App owns permission/capture; Agent owns silence endpoint. Every request owns analyzer/transcriber/detector/conversion under an exclusive ModelResource lease.

## External relationships and data flow

Runtime arrows show data or capability calls; dashed arrows show injection.

```mermaid
flowchart LR
 Caller --> Adapter[AppleSpeechRecognition]
 Assets[AssetInventory and locale availability] --> Adapter
 Adapter --> Queue[Four native input frames]
 Queue --> Analyzer[SpeechAnalyzer and SpeechTranscriber]
 Analyzer --> Events[Revisioned transcript session]
 Events --> Caller
```

## Native processing and limits

Validate supported locale/assets/hardware explicitly; asset preparation may require network. Ordered 16 kHz mono Float32 is converted to native preferred format. Four input frames of ≤one MiB buffer; serialized producer suspends until native consumption, with cancellation waking sends and no PCM drops. Per input ≤16,000 samples; total ≤300 seconds.

Output retains 128 events of ≤65,600 estimated bytes, 2048 time-range fragments and 64 KiB aggregate text. Native revisions replace overlapping ranges in one capability segment. finishInput drains analyzer/results and emits aggregate final; a 25-second finalization watchdog fails stalls. Cancel/error/shutdown stops analyzer before releasing admission. Framework-internal buffer size is opaque.

SpeechDetector shares analyzer/input/converter with reportResults=false. Normal activity events are not exposed as VoiceActivityCapability; external VAD remains the endpoint source. There is no legacy SFSpeechRecognizer or cloud fallback.

✅ Managed native recognition, bounded input backpressure and joined finalization are implemented.

## Related design

[Parent design](../README.md)
