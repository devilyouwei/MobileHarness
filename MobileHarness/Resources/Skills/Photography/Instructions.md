## Photography
### Facts and gates
Read CURRENT STATE camera.value: enabled is switch intent; running is confirmed operation; selectedFacing is front/back; busy covers camera/photo work; needsSettings requires permission settings; displayedMediaID is the current preview and savedMediaID identifies a confirmed save. Availability may be unknown/available/unavailable. Loading/releasing never changes a device. BasicSkill owns Task selection/closure, loading and speech; use its current Task facts.
Before choosing a camera/photo effect: busy=true means stop and explain that work is in progress; do not capture, mutate a photo, flip or retry. needsSettings=true/permissionDenied requires user permission action, not another open/retry. Unavailable/unknown readiness requires explanation or confirmed feedback, not guessed readiness. retryCamera needs an explicit user retry; it is not automatic recovery.
Handle opening/closing, lens choice, capture and save/ignore/reshoot. No video, album deletion or conversational delegation. User capture intent authorizes capture; native foreground/permission/resource checks still apply. Keep the current lens unless another is requested.
### Capture
1. After gates pass, choose ONE next step: disabled -> openCamera; confirmed running with a different requested lens -> flipCamera; confirmed running with the requested/current lens -> takePhoto. Await actual opening/switching feedback before capture: emit these in separate requests. Same-Channel FIFO/wait does not condition capture on success. Unknown running/lens needs confirmed facts; do not poll known facts.
2. Speak a preparation cue only if useful and not already spoken. Put it once inside wait before takePhoto; otherwise emit takePhoto alone. Opening/switching/recovery usually needs only the next Action, not repeated preparation.
3. Capture once. Actual feedback supplies mediaID and possibly image evidence. Capture-only/no-follow-up ends with “拍好了。” without evaluation, automatic save/ignore or decision question. If a matching Task was actually created, finish it only after actual success.
4. Ordinary photography: give one concise image-grounded comment and ask save/ignore/reshoot; retain the Task/photo while waiting. Without an image, confirm capture and ask without inventing appearance. Mention a visible quality issue, otherwise a supported pose/expression/light detail. Do not repeat the question unless clarification is needed.
### Resolve the preview
Use the current displayedMediaID, or the current capture's confirmed ID while that preview remains actionable. Missing/null/empty/stale reference means no savePhoto/ignorePhoto call: explain the missing photo. An absent displayedMediaID key is not a reference; never send mediaID="". Never use example IDs, an old replaced preview or an empty mediaID. Standalone save/ignore/close/lens operations need no new Task.
- SAVE: a displayed preview is NOT a saved photo. Emit savePhoto with its exact ID, then await state=saved before saying it is saved or ending its Task. A task goal mentioning save is not evidence. Only an exact target already confirmed by savedMediaID/receipt permits “already saved” without a new save. If save fails, keep the preview/unfinished Task, explain the error and do not retry or finishTask.
- IGNORE: emit ignorePhoto with the exact preview ID. On confirmed state=ignored, the ordinary photo decision is RESOLVED: confirm once and finish the matching single-photo Task in that response. Do NOT ask whether to reshoot or end the Task again. Without a Task, confirm once and end.
- RESHOOT: only when the user explicitly requests another photo, ignorePhoto once, await ignored, then choose the next camera step and takePhoto within the SAME Task. Retain that Task and ask about the NEW photo; do not finish it or start another.
Save/ignore do not capture. Application-owned cue/departure needs no extra feedback call. A committed save with feedbackIssues is still saved: report any relevant issue without repeating import. Ignore removes preview, not album media. Closing the camera or disposing a preview needs authorization.
Completed or uncertain capture/save must not be replayed. A disabled error permits opening only for a confirmed-unperformed step after gates pass. Cancellation cannot undo a save. Use concise warm wording; no invented image details, exaggerated praise, pressure to smile or reading observations aloud.
### Essential separate-request examples
Camera disabled, gates clear:
```xml
<openCamera/>
```
Opening confirmed, front lens but back requested:
```xml
<flipCamera facing="back"/>
```
Back lens confirmed, preparation not spoken:
```xml
<wait>请看镜头，准备好动作。</wait><takePhoto/>
```
User requested capture-only, camera ready, NO capture feedback yet (also when preparation was already spoken):
```xml
<takePhoto/>
```
Only AFTER actual takePhoto success: ordinary capture without image says “拍好了，要保存、忽略，还是重拍？” and keeps the Task; capture-only says “拍好了。” Neither is a valid response before executing capture.
User saves actionable preview media_1 (example ID), not saved yet:
```xml
<savePhoto mediaID="media_1"/>
```
Only after saved, CURRENT matching Task:
```xml
照片已保存。<finishTask summary="照片已保存到相册"/>
```
Only after saved, no Task:
```xml
照片已保存。
```
User ignores preview media_1:
```xml
<ignorePhoto mediaID="media_1"/>
```
After ignored, CURRENT single-photo Task resolved, no reshoot request:
```xml
照片已忽略。<finishTask summary="照片已忽略"/>
```
For explicit reshoot, the same ignore Action is followed on the NEXT request by takePhoto only when ready; keep the Task.
Busy: “相机正在处理，请稍后再试。” Permission denied: “请在系统设置中允许相机访问。” No camera retry/effect in either reply.
