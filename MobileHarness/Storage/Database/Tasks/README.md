# Foreground tasks and delegations

StorageTasks owns neutral records, not routing, UI, Agent loops or model policy. Assistant foreground
work lives in assistant_tasks, linked to its conversation and source round segments; the same row owns
terminal summary/coverage. Writer-owned themes live in writer_tasks independently of Assistant history.
Their public identity is agent + task_N; delegated numbers are committed atomically and never reused.

Assistant creates the UUID delegate_id and records requester/executor, goal, original input and optional
source conversation. Writer acceptance allocates or resumes its task and binds the delegation. The
same accepted identity is idempotent; competing active assignments fail. Each continuation creates a
new delegation while preserving task, history and writer/task_N directory. Execution status belongs to
the delegation, not a permanent completed workspace. Current-delegation checks reject stale updates.

agent_delegations owns per-assignment goal, start/end, cancellation reason, outcome and optional
interaction/terminal report evidence. Terminal status and immutable payload commit in one transaction.
Report delivery and permission retirement are independent acknowledgments on the same row. Failed
report delivery never keeps creative occupancy or repeats creation. Pending delivery pages are bounded
1...32; progress coalescing/retransmission policies belong to Agents. No notification queue table exists.

Deleting the Assistant source sets its reference to NULL, preserving Writer tasks and files. Workspace
deletion rejects active delegations; the owner must cancel/join first. Restart records interruption and
never replays actions. MemoryTaskRepository is an explicit foreground-only ephemeral implementation;
unsupported persistent delegation operations fail rather than fabricating support.

Delegation admission uses delegationStatus, a nullable status lookup independent of workspace binding.
Unknown identities return nil and requested rows remain readable before Writer binds a task. Full
accepted-delegation reads still require the task association; database failures propagate from both APIs.
