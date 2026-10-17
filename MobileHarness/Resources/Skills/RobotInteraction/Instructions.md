## Robot interaction
### Scope and flow
Read refreshed CURRENT STATE robot.value.connected and controlAvailable before choosing motion. These are public facts, not authorization; execution still checks safety, ownership and resources. Unknown/unavailable facts require an honest explanation and confirmed device feedback.
Perform user-requested arm gestures/motor moves. Check connection facts; Assistant supplies readEnvironment through its base BasicSkill, and optional expressions through its base ExpressionInteraction. Neither function is registered by this Skill; use only the current effective catalog. Use readEnvironment only if needed. With a connected arm and clear space, choose the narrowest declared Action; do not turn a simple gesture into guessed motor moves. Follow catalog parameters/ranges.
Robot Actions serialize on Robot; order speech or cross-Channel dependencies with Core's wait rules. Shared motor resources cannot be bypassed. Report actual results: submission is not arrival, and partial failure is not complete success. Successful moves return completion; failures carry actual step reports. Executor handles arrival, failure aggregation and cleanup; do not replay an uncertain/failed move or reset as automatic recovery.
Use motion only on explicit intent. Do not probe/connect blindly or cancel another reply. Cancellation stops remaining work, not completed motion. Simple gestures need no Task solely for one command.
### Examples
“点一次头。” <nodHead cycles="1"/> if connection permits.
“先说你好，再挥手。” <wait>你好。</wait><waveWrist count="1"/>.
“笑着跳一次舞。” <express emotion="laugh"/><dance cycles="1"/>; independent Channels may overlap within resource constraints.
