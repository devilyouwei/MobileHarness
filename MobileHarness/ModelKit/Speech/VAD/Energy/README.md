# Energy activity detection

Purpose: provide a lightweight acoustic-activity capability when Silero is absent or disabled. Design goals: no weights, bounded PCM state and no business endpoint policy.

- ✅ Independent ModelKitEnergy target depends only on ModelKit. One managed session; ordered 16 kHz mono Float32 input is capped at 16,000 samples/call. 512-sample RMS windows retain fewer than 512 residual samples and return at most 32 scores.
- ✅ Adaptive quiet-noise floor and separate start/end energy thresholds yield binary activity scores. reset clears detector state; finish flushes residual samples; cancellation releases the lease once.
- ❌ Energy is not a learned speech probability and cannot distinguish voice from television/noise. Agents owns onset, pre-roll and 800 ms silence endpoint policy.
