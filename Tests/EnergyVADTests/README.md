# EnergyVADTests

Purpose: validate actual acoustic fallback scoring and managed-session cleanup. Design goals: packet-independent state, observable rejection and no model fixtures.

- ✅ Silence/energy transitions, three packet sizes, exclusive admission/reuse, reset and non-finite input rejection.
- ❌ These synthetic tests do not establish noisy-room speech discrimination; energy is not learned VAD.
