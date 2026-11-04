# Writing

Delegate HTML/CSS/JS diagrams, animations, Markdown and text to startTask execution=background executor=writer. This is available in BasicSkill without a foreground Task or loading Writing. Supply a short one-line goal (1024 UTF-8 bytes maximum), optional title/entry (index.html/document.md/document.txt). Runtime adds the original user input. Never send source code, expanded specifications, projectID, skills or protocol fields.

Omit taskID for a new task, conversation and directory; use an actual delivered taskID to resume its history/files with a new runID. While running, sendMessage(taskID,text,interactionID?) forwards relevant user corrections/answers at a file checkpoint. Match the pending interactionID. cancelTask(taskID,reason) requests cleanup; only Writer confirms the terminal state. finishTask closes foreground work only.

Writer accepts one task including waiting, paused and cleanup. Check agents.writer. Ask before replacing busy work; after explicit user authorization, startTask replaceCurrent=true joins cancellation before starting. Cleanup failure refuses replacement. Never invent IDs or create another Writer for the same work.

Acceptance is not completion. Briefly acknowledge, keep chatting and preserve unrelated foreground work. Writer cannot speak directly to the user: report its actual progress, questions and results. Never poll, replay creation from a report, or reload this Skill to retry. Explain explicit failures; wait for new user input before retrying. Independent model configuration failures remain explicit.

Artifact_library command=projects lists saved works; command=open with a real projectID reopens; command=delete requires an explicit deletion request. Other workspace operations belong to Writer. Await each result before using returned IDs. Browsing belongs to web-browsing.

All calls are XML Function Tokens, never native tools. Separate operations:
```xml
<Artifact_library command="projects"/>
```
```xml
<Artifact_library command="open" projectID="actualProjectID"/>
```
```xml
<startTask execution="background" executor="writer" taskID="actualTaskID" goal="Update the title as requested"/>
```
```xml
<startTask execution="background" executor="writer" goal="Draw the new flowchart" replaceCurrent="true"/>
```

Writer windows are shared ui.windows independent of this Skill. Load web-browsing to inspect/capture by real windowID, application-control to manage any window. Independent task ownership does not hide windows or require another background task.
