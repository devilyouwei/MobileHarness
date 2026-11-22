## BasicInteraction
### Expressions
This Skill covers eye expressions, listening control, window independence and the baseline State facts.
Use eye expressions to accompany conversation or satisfy a user's expression request. express is transient; setExpression is sustained. Select only catalog values. closed closes both eyelids smoothly; clear restores the active listening neutral pose. While listening is off, the eyes rest closed and nonclosed finite performances are unavailable. Expression changes are optional in ordinary conversation and need no Task.
Text/expression may run together; use the wait Action for requested speech-first ordering. Avoid distracting repetition. Report actual failure rather than claim success or retry automatically. This Skill does not operate camera or arm.
### Examples
“Smile.” <express emotion="happy"/>.
“Say hello, then smile.” <wait>Hello.</wait><express emotion="happy"/>.

“Close your eyes.” <setExpression emotion="closed"/>.
“Close your eyes briefly.” <express emotion="closed"/>.

### Ordering with wait
Output order does not order different Channels; Actions on one Channel run in order. wait has no Channel and no effect. Emit every known step in ONE response; result-dependent choices await feedback. At most 32 waits, nested at most 8 deep; Agent controls never go inside.
`<wait>...</wait>` scope: starts after earlier work of its parent group finished; later work starts only after everything inside, nested scopes included, finished.
`<wait time="seconds"/>` delay: holds later output while started Actions keep running; it never waits for them. Prefer whole seconds (`2`); use a decimal (`0.5`) only when a sub-second pause is needed. Above 0 up to 60 seconds, 120 per response; time is required.
“Think, then smile while saying yes, then close your eyes”:
```xml
<wait><express emotion="thinking"/><wait><express emotion="happy"/>Yes.</wait></wait>
<setExpression emotion="closed"/>
```
“Keep your eyes closed for a second” (nothing must finish, so a delay):
```xml
<setExpression emotion="closed"/><wait time="1"/><setExpression emotion="clear"/>
```
“Say ready, wait two seconds, then smile” (the scope finishes the speech before the clock starts):
```xml
<wait>Ready.</wait><wait time="2"/><express emotion="happy"/>
```

### Continuous performances
For “in order, one by one, or show them all”, use serial wait groups in one response; no new Task. Use express to await performance/restoration; setExpression only commits a base target. Follow the user's subset/order; “all” covers current express values once, excluding clear.
Serial steps, e.g. “Smile, think, and look happy in order, without speaking”:
```xml
<wait><express emotion="smile"/></wait>
<wait><express emotion="thinking"/></wait>
<wait><express emotion="happy"/></wait>
```
For “Show each expression in order and say its name”, put each expression and its speech in ONE wait, keeping default Display/Speech Channels. They may overlap; BOTH finish before the next group. Do not put all items in one wait or move speech to Display. Exact simultaneous onset is not guaranteed. Emit the requested performance without extra opening/closing narration:
```xml
<wait><express emotion="closed"/>Eyes closed.</wait>
<wait><express emotion="smile"/>Smiling.</wait>
<wait><express emotion="happy"/>Happy.</wait>
<wait><express emotion="laugh"/>Laughing.</wait>
<wait><express emotion="thinking"/>Thinking.</wait>
<wait><express emotion="surprised"/>Surprised.</wait>
<wait><express emotion="sad"/>Sad.</wait>
<wait><express emotion="love"/>Love.</wait>
<wait><express emotion="angry"/>Angry.</wait>
<wait><express emotion="scared"/>Scared.</wait>
<wait><express emotion="playful"/>Playful.</wait>
```

### Workflow boundaries
Expressions use only express and setExpression. Listening activation, halo, haptics, cues, transient notices and photo-departure feedback are application-owned effects; do not invent tags for them or replay them around expressions. Natural reply text is already spoken/displayed by the host.

ui.home.expression describes base, effective display target, overridden, transitioning and loading. Effective is the current presentation target; only the existing animation completion contract proves a transition completed. Reading or loading this Skill never changes expression.

### Listening
startListening and stopListening enable or stop listening on explicit user intent only; neither changes Tasks or Skills. Voice exit: <stopListening/> with at most one short farewell, never a restart. E.g. “Goodbye, stop listening.”: Goodbye.<stopListening/> startListening requires explicit intent. Automatic listening resumption belongs to the runtime.

### Windows and baseline State
Window lifetime is independent of Task and Skill lifetime. Opening or focusing one window does not close or replace another. Keep windows and their contents until the user explicitly requests their closure or disposal; a change of goal or Task/Skill state does not grant that permission. Apply window operations only to the intended window, identified by current State or actual feedback, using its declared operations.
CURRENT STATE holds observed facts selected by loaded Skills. Use sufficient facts directly; query only missing or stale supported facts. Read each field for the property it describes: an absent result does not mean its producer is disabled. Unknown means unobserved. State is not pixels, and paths, permissions or a loaded Skill do not prove an operation succeeded. User language overrides locale.
