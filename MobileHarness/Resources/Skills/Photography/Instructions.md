## Photography
### Facts and gates
拍照/拍摄照片 uses this Skill and the photo window. 打开视觉/打开跟踪/跟随 uses application-control and Vision.open; do not open photography for that intent.
actions.camera: enabled=photo intent; busy blocks work; needsSettings requires settings; displayedMediaID=preview; savedMediaID=confirmed save. platform.vision.camera owns running/phase/facing. Unknown is not ready. flipCamera requires lensOwner=capture. Photography never enables background vision.
BasicSkill owns Task selection/closure; use AGENT CONTEXT task. Standalone save/ignore/close/lens operations need no new Task. Capture-only keeps the photo; if a matching Task was actually created, follow task cleanup.
Busy: explain and wait, no mutation. Permission denied: system settings, not open/retry. retryCamera requires explicit intent. No automatic retry, video, album deletion or delegation. Keep the lens unless requested.
### Capture and decisions
After gates: disabled -> openCamera; wrong requested lens -> flipCamera; ready -> takePhoto. Await open/flip success; emit these in separate requests. FIFO/wait cannot test success.
Capture once. If preparation was already spoken, omit it; otherwise one useful cue inside wait before takePhoto. Feedback supplies mediaID/image evidence. Never replay completed/uncertain capture/save.
Capture-only: “拍好了。”, no evaluation/save/question. Ordinary photography: concise image-grounded comment, ask save/ignore/reshoot, retain Task/photo. No image: do not invent details. No exaggerated praise or pressure to smile.
Save/ignore requires actual current displayedMediaID or still-actionable capture ID; never missing/null/empty/stale/example IDs.
- SAVE: preview is not saved. savePhoto collects into the App album; phone export is in its page. Await state=saved, then follow task cleanup before Task closure. Exact savedMediaID/receipt allows “already saved”. Failure retains the unfinished Task/preview; explain without retry. A committed save with feedbackIssues remains saved; do not save again.
- IGNORE: await state=ignored, then follow task cleanup for the matching single-photo Task. Without a Task, confirm and end. Do not ask about reshooting or ending again. Ignore removes preview, not album media.
- RESHOOT: on explicit request, ignore once, await ignored, then capture in the SAME Task. Ask about the new photo; no Task closure/recreation.
Save/ignore never captures. Disposal needs authorization. Cancellation cannot undo save.
### Task cleanup
Matching Task resolved after save/ignore: separately closeCamera. Await operation=close and enabled=false, then finishTask. Never combine disposal/close/finish in one response. Close Capture only, never Vision.close.
Cancel/replacement also waits for close; pending photos require save/ignore/cancel, never automatic disposal. Cancelled/failed close retains Task/window; report without retry or repeating committed save/ignore. Already closed/disabled needs no close.
Reshoot retains the SAME Task/window. No Task: no automatic close or finish. Never finish unrelated Tasks.
### Windows
Window.* uses an actual windowID from ui.windows/openCamera. move takes x/y in0...1. openCamera opens/restores the single Camera window. Minimize hides preview and yields lens control to background vision; capture stays on. Restore before save/ignore; resume failure preserves photos. Close asks save/ignore/cancel. App background stops both branches; reopening needs user intent. Window completion is not photo success.
### Separate-request examples
Disabled, gates clear:
```xml
<openCamera/>
```
Opened, back lens requested:
```xml
<flipCamera facing="back"/>
```
Lens ready, useful preparation not spoken:
```xml
<wait>请看镜头，准备好动作。</wait><takePhoto/>
```
Ready, capture-only or preparation already spoken:
```xml
<takePhoto/>
```
Replace illustrative IDs with actual feedback:
```xml
<savePhoto mediaID="media_1"/>
```
Saved, matching Task/window:
```xml
<closeCamera/>
```
Closed successfully, matching Task:
```xml
照片已保存到 App 相册。<finishTask summary="照片已保存到 App 相册"/>
```
After saved, no Task:
```xml
照片已保存到 App 相册。
```
Requested ignore, actual actionable ID:
```xml
<ignorePhoto mediaID="media_1"/>
```
Ignored, matching Task, no reshoot:
```xml
<closeCamera/>
```
Closed that Task’s window successfully:
```xml
照片已忽略。<finishTask summary="照片已忽略"/>
```
