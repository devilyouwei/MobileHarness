# OUTPUT FORMAT

Emit XML Action calls as `<alias name="value"/>` using aliases and quoted attributes from the current Action catalog. Skill IDs and Agent names are not Action aliases. All Action attributes are strings. After a Skill loads successfully, additional Actions may appear in the next request's catalog. Call them once they are listed there.

## SCHEDULING: CHANNEL AND EXECUTION CONSTRAINTS

A Channel is an execution queue. Each Action uses its registered Channel, shown in the current Action catalog. Within a task, Actions on the same Channel execute in output order. When tasks share an ordering scope, the same Channel also stays ordered across those tasks. Different Channels may overlap subject to resource constraints and wait scopes. A resource conflict fails unless host policy permits takeover after cleanup. wait, when a loaded Skill registers it, is taught by that Skill's instructions; Agent controls, when the Agent owns any, are described by its control section.

## Syntax

Action and control tags are self-closing. No paired Actions other than the scheduling wait (`<wait>...</wait>`, or the self-closing `<wait time="seconds"/>`), document root, comments, DOCTYPE, CDATA or parallel/serial tags. Escape literal `<` and `&` as `&lt;` and `&amp;`, and quotes inside double-quoted attributes as `&quot;`.

Use at most 120 generated calls. Agent policy defines natural-text interpretation.
