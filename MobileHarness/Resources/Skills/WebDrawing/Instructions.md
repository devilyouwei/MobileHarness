## Local web graphics
### Scope and task intent
Create or revise flowcharts, diagrams, interactive displays and animations with Web.develop. Its internal developer uses the current model configuration with independent requests and edits HTML/CSS/JS files. The main Assistant sends a natural-language task, never generated source code, Markdown code fences or editor commands.
web-browsing supplies page observations and window controls; its evidence/serial-operation rules apply. BasicSkill owns Task selection. One finished drawing or small edit needs no new Task just because internal generation takes multiple requests. Use/retain a matching Task when the user wants ongoing development or later decisions; never close an unrelated goal.
### Create, continue and reopen
1. Describe the desired content, layout, language and requested interaction/animation in task; use sensible defaults for unspecified style. Ask only for missing information that changes the result materially. Optional title is a short label, not a project identity. Omit projectID to create.
2. To modify a work, pass its actual projectID and describe both the change and what must remain. Use recent confirmed feedback when unambiguous. Otherwise call Web.projects, await the list, then choose the intended project or ask if ambiguous. Never use windowID, mediaID, revision, a title or an example UUID as projectID. Do not create a new project for “改一下刚才那张图”.
3. Web.develop opens the window, edits, saves a version, renders and returns a screenshot. Await its result before any dependent call; do not immediately open/snapshot the same result again. Keep the returned projectID/revision as continuation evidence; source code stays inside the Action.
4. Use Web.open to display a saved work without regenerating it. Web.projects only lists saved metadata; it neither opens the work nor proves its appearance. Unknown ui.web State is not proof that a project is missing; local file paths are intentionally absent.
Local works support HTML/CSS/JS, SVG and canvas. They have no shell, package installation, CDN/external network or privileged native bridge. Explain an unsupported requirement rather than promise it.
### Feedback and completion
Use actual screenshot, text and diagnostics against the user's requested content and behavior. A render is not proof that every interaction works; a single frame does not verify an animation's full timing or export a video. Without image evidence, do not claim visual inspection.
If a successful result reveals a concrete defect within the requested goal, allow one focused follow-up Web.develop on the SAME projectID, preserving correct parts. Inspect that result; if still inadequate, describe the remaining issue instead of looping. This is a targeted revision, not permission to replay a failed/uncertain creation.
Confirm what was created/changed after real feedback. Leave the work visible for use; closing a window is not required to finish a drawing Task. Finish only a current matching Task with its requested result achieved. A genuine pending user choice retains the Task; standalone success needs neither finishTask nor an automatic “还要继续吗”.
### Failure, recovery and deletion
Execution failure/cancellation can leave a saved version even if rendering or screenshot failed. Report that uncertainty; never assume rollback, recreate with a new ID or automatically retry. If the user requests recovery, use the known ID or Web.projects to locate the saved work, then Web.open; continue editing only from confirmed identity.
File/project/version limits are finite. On capacity or model failure report the blocker; do not delete works, reset settings or loop requests to make room. Web.delete removes the exact project and all versions, only when the user asks to delete that work. Closing uses Window.close with the real windowID and preserves saved files. Cancelling a Task does not erase saved versions.
### Examples — each block is a separate response
Skill already loaded; user requests a Chinese three-step flowchart:
```xml
<Web.develop title="审批流程" task="画一张中文流程图：提交申请→主管审核→完成。竖向排列，箭头清楚，适合手机阅读。"/>
```
After actual success, user asks to animate the arrows while keeping the content/layout. The following projectID is hypothetical; replace it with the returned projectID:
```xml
<Web.develop projectID="22222222-3333-4444-8555-666666666666" task="保留现有节点文字、配色和布局，只让连接箭头出现柔和循环的流动动画。"/>
```
User asks to reopen a saved work but its identity is missing:
```xml
<Web.projects/>
```
Only on the next request, after the list identifies the intended work; hypothetical ID:
```xml
<Web.open projectID="22222222-3333-4444-8555-666666666666"/>
```
User explicitly asks to delete that identified work, not merely close its window:
```xml
<Web.delete projectID="22222222-3333-4444-8555-666666666666"/>
```
