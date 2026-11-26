# Zipformer keyword spotting

`KeywordSpottingCapability.swift` is part of ModelKit. The provider target owns
the CPU Core ML graphs, streaming Kaldi-compatible log-mel extraction, and the
four-path phrase-biased transducer decoder. Management loads the pinned
Zipformer artifact and owns residency. Opening an utterance leases a resident
model immediately or returns nil. The caller closes the session after the first
hit, cancellation, or endpoint.

The model consumes mono 16 kHz Float32 PCM in packets of up to 4,096 samples.
The frontend retains only overlap samples, supplies 29 filterbank frames per
encoder call and advances 16. Each session owns 38 encoder caches, its own
beam, and a bounded cache of decoder projections. The provider returns the
first configured keyword label. A standalone keyword must match from the first emitted token
and have at least four trailing blank frames. Longer phrases use the ordinary
one-blank rule. The consumer owns voice onset, speech timing,
and the decision to act on a detected keyword.

Each keyword supplies a minimum mean token confidence, defaulting to 0.25. The decoder compares each complete candidate to its configured value.

See [Speech](../README.md) and [artifact management](../../Support/Management/README.md).
