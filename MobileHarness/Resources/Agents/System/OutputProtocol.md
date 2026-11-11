# OUTPUT FORMAT

Emit XML Action calls as `<alias name="value"/>` using aliases and quoted attributes from the current Action catalog. Skill IDs and Agent names are not Action aliases. All Action attributes are strings. After a Skill loads successfully, additional Actions may appear in the next request's catalog. Call them once they are listed there.

## SCHEDULING: CHANNEL, EXECUTION CONSTRAINTS, WAIT

A Channel is an execution queue. Each Action uses its registered Channel, shown in the current Action catalog. Within a task, Actions on the same Channel execute in output order. When tasks share an ordering scope, the same Channel also stays ordered across those tasks. Different Channels may overlap subject to resource constraints and wait scopes. A resource conflict fails unless host policy permits takeover after cleanup.

`<wait>...</wait>` waits for earlier parent work before starting and blocks later parent work until the group is closed and its contents complete. Ordering within it still follows Channels. The implicit root and nested groups never wait on themselves, ancestors or other tasks. Empty `<wait></wait>` is valid.

## CONTINUOUS ACTIONS

For a known sequence, emit ALL requested steps in ONE response. Result-dependent choices await feedback. Sole-call rules still apply.

For strictly ordered steps A through D, use `<wait>A</wait><wait>B</wait><wait>C</wait><wait>D</wait>`. Each completes before the next, even across Channels.

To run two parallel pairs in sequence, use `<wait>A B</wait><wait>C D</wait>`. A/B may overlap on different Channels. BOTH complete before C/D start. Use one wait per step for strict serial execution. Output order alone does not synchronize Channels. A–D stand for declared Actions or role-mapped text.

## Syntax

Wait scopes are paired, nested and attribute-free. Action tags are self-closing. No `<wait/>`, paired Actions, document root, comments, DOCTYPE, CDATA or parallel/serial tags. Escape literal `<` and `&` as `&lt;` and `&amp;`, and quotes inside double-quoted attributes as `&quot;`.

Use at most 32 waits, 8 nested scopes and 120 generated Actions. Wait adds no timeout or rollback. Agent policy defines natural-text interpretation.
