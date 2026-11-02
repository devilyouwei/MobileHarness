## Photography: photo and video
### Facts and gates
拍照/摄影/录像 uses the Camera window. 打开视觉/跟踪/跟随 uses application-control and Vision.open; photography never enables background vision.
actions.camera: enabled=photo intent, busy blocks work, needsSettings requires system settings, displayedMediaID=photo preview, savedMediaID=confirmed PHOTO save. platform.vision.camera owns running/phase/facing. Unknown is not ready. flipCamera requires lensOwner=capture; keep the current lens unless asked.
BasicSkill owns Task selection/closure. use AGENT CONTEXT task. Standalone save/ignore/close/lens operations need no new Task. Only clean up if a matching Task was actually created. Busy or permission failure: explain, no mutation/retry. retryCamera requires explicit intent. No automatic retry, deletion or delegation.
### Photo
takePhoto opens/restores the window and selects photo mode. Call it directly. For requested lens/settings only: open if needed, flip/configure, then capture; emit these in separate requests after success.
Capture once. If preparation was already spoken, omit it; otherwise give one cue inside wait. takePhoto waits countdown and capture, returning mediaID/image evidence. Capture-only: “拍好了。”, no evaluation/save/question. Otherwise give a concise image-grounded comment and ask save/ignore/reshoot; retain Task/photo. Without image evidence invent nothing; no exaggerated praise or pressure to smile.
savePhoto/ignorePhoto require the actual actionable mediaID, never missing/null/stale/example IDs. Save collects into App album, not Photos. Await saved/ignored; feedbackIssues after committed save does not justify saving again. alreadySaved is confirmation. Failure retains unfinished Task/preview; explain without retry.
Explicit reshoot: ignore once, await ignored, then capture within the SAME Task. Save/ignore never captures. Cancellation cannot undo save; ignore cannot delete collected media.
### Video
startRecording opens/restores and selects video/flash=off, preserving lens/zoom/photo delay. Call directly; no openCamera/configureCamera. Optional durationSeconds=1...600 sets the limit directly; omission retains the current limit (initially600).
Speak preparation in wait BEFORE startRecording; emit nothing after it. Omit waitForCompletion (default true): the call returns ready only after manual/timed stop and file preparation. Never choose false here; it is UI startup-only acknowledgement. Listening pauses during recording: use stop button or time limit, not voice. Minimized recording continues; background finalizes without restart. No lens/photo/settings changes while recording. A separate stopRecording uses the actual recordingID.
Ready means ENDED, not saved. State actual duration/fileName and ask save/ignore; never say recording continues or start again. saveVideo/ignoreVideo require actual recordingID and user consent. mediaID identifies the pending video; savedMediaID is not video evidence. Save collects into App album; export there. Never send video as an image or invent contents. On failure/uncertain start inspect facts, never recapture automatically. Explicit save retry may recover a retained clip.
### Settings
configureCamera replaces full mode/photo-video, delaySeconds0...30, flash/off-on-auto, zoom1...6 (hardware-limited), durationSeconds1...600. Preserve unrelated current settings; video flash=off. Unsupported settings fail explicitly. No mode change over pending media. Countdown is local to takePhoto; cancelCapture cancels/joins it, no model timer.
### Task cleanup (photo and video)
After confirmed save/ignore resolves a matching Task: separately closeCamera. Await operation=close and enabled=false, then finishTask. Never combine disposal/close/finish in one response. Close Capture only, never Vision.close. Already closed needs no close.
Cancel/replacement waits for close; pending media require save/ignore/cancel, never automatic disposal. Cancelled/failed close retains Task/window: report without replaying committed operations. Reshoot retains the SAME Task/window. No matching Task: confirm, no automatic close/finish; never finish unrelated tasks.
### Windows and Island
Window.* needs real windowID; move uses x/y0...1. openCamera is for preview only. Minimize retains capture/recording and yields lens control to Face vision. Restore before disposition. Close asks save/ignore/cancel. Background stops capture; reopening is explicit.
Island.setPresentation uses real activityID and size=compact/expanded; only detail text/thumbnail expands. New detail auto-expands; updates preserve manual collapse/content. Task detail and transient status are independent. Details/listening timers are automatic: no duplicates, periodic updates or forced expansion. Component owns animation/size. Submitted is not settled; localStatus/systemStatus are independent, iOS controls system expansion.
### Photo examples — each block is a separate response
Explicit request to open preview only, without capture:
```xml
<openCamera/>
```
Requested back lens after open:
```xml
<flipCamera facing="back"/>
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
<savePhoto mediaID="media_1"/>
```
User authorizes ignore:
```xml
<ignorePhoto mediaID="media_1"/>
```
Confirmed disposal, matching Task:
```xml
<closeCamera/>
```
Close succeeded after save:
```xml
照片已保存到 App 相册。<finishTask summary="照片已保存到 App 相册"/>
```
Confirmed ignore, matching Task:
```xml
<closeCamera/>
```
Close succeeded after ignore:
```xml
照片已忽略。<finishTask summary="照片已忽略"/>
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
视频已保存到 App 相册。<finishTask summary="视频已保存到 App 相册"/>
```
Confirmed ignore, matching Task:
```xml
<closeCamera/>
```
Close succeeded after ignore:
```xml
视频已忽略。<finishTask summary="视频已忽略"/>
```
