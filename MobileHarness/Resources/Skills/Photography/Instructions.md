## Photography: photo and video
### Facts and gates
拍照/摄影/录像 uses the Camera window. 打开视觉/跟踪/跟随 uses application-control and Vision.open; photography never enables background vision.
actions.camera supplies intent, busy, permission and preview facts. platform.vision.camera supplies actual running/phase/facing. Unknown is not ready. Flip only when asked and lensOwner=capture.
BasicSkill owns Task selection/closure. use AGENT CONTEXT task. Standalone save/close/lens operations need no new Task. Only clean up if a matching Task was actually created. Explain busy or permission failures. retryCamera requires explicit user intent.
### Photo
takePhoto opens/restores the window and selects photo mode. Call it directly. For requested lens/settings only: open if needed, flip/configure, then capture; emit these in separate requests after success.
Capture once with one spoken cue inside wait. If preparation was already spoken, omit the cue. takePhoto returns the actual previewID. Capture-only: “拍好了。” Otherwise comment only on attached evidence and ask save/close/reshoot. Keep the matching Task and previews.
savePhoto uses an actual current previewID. On “save all”, call saveAllPhotos once for all pending photos, including unselected photos. Use the App album. Report committed and failed items from the receipt. alreadySaved and feedbackIssues do not justify repeating a committed save. Keep failed previews and the Task after partial failure; await user intent.
Explicit reshoot: capture directly within the SAME Task/window. Earlier photos remain cached and can be loaded again until FIFO eviction or window close. Saving never captures. Cancellation cannot undo save. If photos are unwanted, close the Camera window to clear the session.
### Video
startRecording opens/restores and selects video/flash=off, preserving lens/zoom/photo delay. Call directly; no openCamera/configureCamera. Optional durationSeconds=1...600 sets the limit directly; omission retains the current limit (initially600).
Speak preparation in wait BEFORE startRecording; emit nothing after it. Omit waitForCompletion (default true): the call returns ready only after manual/timed stop and file preparation. Never choose false here; it is UI startup-only acknowledgement. Listening pauses during recording: use stop button or time limit, not voice. Minimized recording continues; background finalizes without restart. No lens/photo/settings changes while recording. A separate stopRecording uses the actual recordingID.
Ready means ENDED, not saved. State actual duration/fileName and ask save/ignore; never say recording continues or start again. saveVideo/ignoreVideo require actual recordingID and user consent. mediaID identifies the pending video; savedMediaID is not video evidence. Save collects into App album; export there. Never send video as an image or invent contents. On failure/uncertain start inspect facts, never recapture automatically. Explicit save retry may recover a retained clip.
### Settings
configureCamera updates supplied fields only: mode/photo-video, delaySeconds0...30, flash/off-on-auto, zoom1...6 (hardware-limited), durationSeconds1...600. Omit unrelated fields; video flash=off. Unsupported settings fail explicitly. No mode change over pending media. Countdown is local to takePhoto; cancelCapture cancels/joins it, no model timer.
configureCamera and unloadPreviewImage complete without a business result on success. Read actual applied settings and current preview selections from State when a later request needs them.
### Task cleanup (photo and video)
After confirmed photo save or video save/ignore resolves a matching Task: separately closeCamera. For unwanted photos, closeCamera clears the session. Await operation=close and enabled=false, then task.end. Never combine disposal/close/finish in one response. Close Capture only, never Vision.close. Already closed needs no close.
Cancel or replacement waits for close. An authorized close clears temporary unsaved photos immediately. A pending video must be explicitly saved or ignored before closeCamera can finish. Cancelled/failed close retains Task/window: report without replaying committed operations. Reshoot retains the SAME Task/window. No matching Task: confirm, no automatic close/finish; never finish unrelated tasks.
### Windows and Island
Window.* needs real windowID from ui.windows; move uses x/y0...1. openCamera is for preview only; success does not trigger a model continuation. Minimize retains capture/recording and yields lens control to Face vision. Restore before disposition. closeCamera closes without opening a confirmation dialog. The window button still offers a choice for pending video. Background stops capture; reopening is explicit.
Island.setPresentation uses real activityID and size=compact/expanded; only detail text/thumbnail expands. New detail auto-expands; updates preserve manual collapse/content. Task detail and transient status are independent. Details/listening timers are automatic: no duplicates, periodic updates or forced expansion. Component owns animation/size. Submitted is not settled; localStatus/systemStatus are independent, iOS controls system expansion.
### Photo examples — each block is a separate response
Explicit request to open preview only, without capture:
```xml
<openCamera/>
```
Open preview with the requested back lens in one response:
```xml
<openCamera/><flipCamera facing="back"/>
```
Any window state, preparation not yet spoken:
```xml
<wait>请看镜头，准备好动作。</wait><takePhoto/>
```
Already prepared or capture-only:
```xml
<takePhoto/>
```
User authorizes save; replace illustrative ID with actual feedback:
```xml
<savePhoto previewID="preview_1"/>
```
User requests saving all unsaved photos in this Camera session:
```xml
<saveAllPhotos/>
```
Review specific cached photos using actual IDs:
```xml
<loadPreviewImage previewIDs='["preview_1","preview_2","preview_3","preview_4","preview_5"]'/>
```
User requests a reshoot; retained earlier photos remain readable:
```xml
<takePhoto/>
```
Confirmed disposal, matching Task:
```xml
<closeCamera/>
```
Close succeeded after save:
```xml
照片已保存到 App 相册。<task.end summary="照片已保存到 App 相册"/>
```
User wants to discard unsaved photos, matching Task:
```xml
<closeCamera/>
```
Close succeeded and session cleared:
```xml
相机已关闭。<task.end summary="相机已关闭，未保存照片已清空"/>
```
Saved without a Task:
```xml
照片已保存到 App 相册。
```
### Video examples — each block is a separate response
Any camera/window mode, preparation not yet spoken:
```xml
<wait>开始录像，结束时请点停止按钮。</wait><startRecording/>
```
User requests ten seconds; no configureCamera step:
```xml
<wait>开始录制十秒视频。</wait><startRecording durationSeconds="10"/>
```
Already prepared:
```xml
<startRecording/>
```
Only AFTER a ready receipt reporting10 seconds; use actual values:
```xml
录像已结束，时长十秒。要保存到 App 相册，还是忽略？
```
User authorizes save; replace illustrative UUID with actual recordingID:
```xml
<saveVideo recordingID="11111111-2222-4333-8444-555555555555"/>
```
User authorizes ignore:
```xml
<ignoreVideo recordingID="11111111-2222-4333-8444-555555555555"/>
```
Confirmed disposal, matching Task:
```xml
<closeCamera/>
```
Close succeeded after save:
```xml
视频已保存到 App 相册。<task.end summary="视频已保存到 App 相册"/>
```
Confirmed ignore, matching Task:
```xml
<closeCamera/>
```
Close succeeded after ignore:
```xml
视频已忽略。<task.end summary="视频已忽略"/>
```

### Preview images across turns
Use actual current IDs from actions.camera.preview. Only attached images are evidence; State maps IDs to attachment positions. loadPreviewImage(previewID) appends one explicit selection. Use previewIDs as a JSON array to replace the selection with 1–5 photos. The latest fills a free slot. New capture displaces the first selection if full. Compare only requested attached photos. Unload removes explicit selections.

The current window caches the latest 20 originals. Reshoots retain older entries until FIFO eviction. Save unloads a photo, and its cached original can be selected again. Hidden windows suspend delivery; close clears the cache and expires preview_N IDs. Persistent media_N belongs to the album. Missing or unsupported image evidence does not authorize recapture.
