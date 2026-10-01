# Robot Tool Support

Purpose: keep the aim registration out of the callable entry file. Design goals: one explicit module, an injected sender, and no device construction.

```mermaid
flowchart LR
    Host[Host aim closure] --> Module[RobotToolModule]
    Module --> Entry[RobotTools.aim]
```

✅ `RobotToolModule` registers completion-only `Robot.aim`. The host supplies the sender. This directory adds no queue.

❌ The registration does not open Wi-Fi or call the production NexArm controller. The gripper is not addressed.
