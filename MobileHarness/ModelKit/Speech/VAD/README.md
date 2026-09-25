# Voice activity detection

Purpose: Define voice-probability processing independently of business endpoint policy.

Design goals: explicit ownership, capability boundaries and no duplicate production sources.

- ✅ Silero streaming windows, request-local state and explicit finish/reset/cancel.
- ❌ Conversation boundary decisions belong to Gateway.
