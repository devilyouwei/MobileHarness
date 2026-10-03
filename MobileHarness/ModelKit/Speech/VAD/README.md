# Voice activity detection

Purpose: provide streaming activity scores independently of conversation endpoint policy. Design goals: request-local state, explicit bounds and managed ownership.

- ✅ Silero streaming probabilities with finish/reset/cancel.
- ✅ EnergyVoiceActivity provides adaptive RMS thresholds and hysteresis without downloaded weights. Defaults uses it when Silero is missing/unavailable, independently of the recognition switch.
- ❌ Energy detection cannot distinguish speech from other loud sounds. Agents/SpeechPerception owns onset, pre-roll and 800 ms silence termination; this SDK owns no conversation timing policy.
