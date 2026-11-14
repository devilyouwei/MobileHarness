## Photography: photo and video
### Facts and gates
Taking photos and recording video uses the Camera window. Enabling vision or tracking uses application-control and Vision.open; photography never enables background vision.
actions.camera supplies intent, busy, permission and preview facts. platform.vision.camera supplies actual running/phase/facing. Unknown is not ready. Flip only when asked and lensOwner=capture.
BasicSkill owns Task selection/closure. use AGENT CONTEXT task. Standalone save/close/lens operations need no new Task. Only clean up if a matching Task was actually created. Explain busy or permission failures. retryCamera requires explicit user intent.
### Photo
openCamera opens/restores a ready preview without taking a photo. takePhoto requires the visible camera and selects photo mode; it never opens/restores it. Emit known open, requested flip/settings, speech and capture steps in ONE response. Await feedback only for result-dependent choices.
For a new photo, give one brief cue BETWEEN open and takePhoto. Separate wait groups order Camera and Speech Channels: `<wait><openCamera/></wait><wait>Look at the camera for the photo.</wait><takePhoto/>`. Omit open when already visible; if preparation was already spoken, omit the cue.
takePhoto delaySeconds=0...30 overrides this shot only: 0 is immediate, omission uses current settings. Countdown needs no configureCamera or model timer. Capture once; await the actual previewID before “Photo taken.” or evidence-based review/save/close/reshoot. Keep matching Task/previews.
savePhoto needs actual current previewID. “Save all” uses saveAllPhotos once, including unselected photos. Report App album successes/failures from receipts. alreadySaved/feedbackIssues never justify replaying committed saves. Partial failure retains failed previews/Task; await user intent.
Explicit reshoot stays in the SAME Task/window; earlier photos remain reloadable until eviction/close. Saving never captures; cancellation cannot undo save. Close clears unwanted photos.
### Video
startRecording opens/restores, selects video/flash=off and preserves lens/zoom/photo delay. No openCamera/configureCamera. durationSeconds=1...600 overrides the limit; omission retains it (initially600).
Speak in wait BEFORE startRecording; emit nothing after it. Omit waitForCompletion (true): ready follows stop and file preparation. false is UI-only startup acknowledgement. Listening pauses: use stop button/time limit, not voice. Minimized recording continues; background finalizes without restart. No lens/photo/settings changes during recording. stopRecording needs actual recordingID.
Ready means ended, not saved. Report actual duration/fileName and ask save/ignore; never restart or claim ongoing recording. saveVideo/ignoreVideo need actual recordingID and consent. mediaID is the pending clip; savedMediaID is not video evidence. Save/export uses App album. Never send video as image or invent contents. Inspect failures/uncertainty without automatic recapture; explicit save retry may recover retained clips.
### Settings
configureCamera updates supplied fields: mode/photo-video, delaySeconds0...30, flash/off-on-auto, zoom1...6 (hardware-limited), durationSeconds1...600. Omit unrelated fields; video flash=off. Unsupported settings fail; pending media blocks mode changes. cancelCapture cancels/joins the local photo countdown.
configureCamera and unloadPreviewImage complete without a business result on success. Read actual applied settings and current preview selections from State when a later request needs them.
### Task cleanup (photo and video)
After confirmed photo save or video save/ignore resolves a matching Task, finish that Task while retaining the Camera window. Explicit discard of unwanted photos uses closeCamera to clear the temporary session.
For an explicitly requested close: Await operation=close and enabled=false before confirming closure or finishing a matching close goal. Never combine disposal/close/finish in one response. Close Capture only, never Vision.close. Already closed needs no close. A pending video must be explicitly saved or ignored before closeCamera can finish. Cancelled/failed close retains Task/window: report without replaying committed operations. Reshoot retains the SAME Task/window. No matching Task: confirm, no automatic close/finish; never finish unrelated tasks.
### Windows and Island
Window.* needs real windowID from ui.windows; move uses x/y0...1. openCamera success has no model continuation: include requested capture in that response. Minimize retains capture/recording and yields lens control to Face vision. Restore before disposition. closeCamera closes without opening a confirmation dialog. The window button still offers a choice for pending video. Background stops capture; reopening is explicit.
Island.setPresentation needs real activityID and size=compact/expanded. Only detail text/thumbnail expands; new detail auto-expands, updates preserve manual collapse. Task detail and transient status are independent. Do not duplicate automatic timers, periodically update, or force expansion. UI owns animation/size; submitted is not settled. localStatus/systemStatus differ; iOS controls system expansion.
### Photo examples — each block is a separate response
Preview only:
```xml
<openCamera/>
```
Open with requested back lens:
```xml
<openCamera/><flipCamera facing="back"/>
```
Open → cue → photo, ONE response:
```xml
<wait><openCamera/></wait><wait>Look at the camera for the photo.</wait><takePhoto/>
```
Already open; give a cue:
```xml
<wait>Look at the camera for the photo.</wait><takePhoto/>
```
Already open/prepared:
```xml
<takePhoto/>
```
Open + three-second countdown; cue already spoken:
```xml
<openCamera/><takePhoto delaySeconds="3"/>
```
Open → cue → three-second countdown, ONE response:
```xml
<wait><openCamera/></wait><wait>Look at the camera for a photo in three seconds.</wait><takePhoto delaySeconds="3"/>
```
Already open; explicitly requested immediate photo:
```xml
<takePhoto delaySeconds="0"/>
```
Authorized save; use actual previewID:
```xml
<savePhoto previewID="preview_1"/>
```
Save all, when requested:
```xml
<saveAllPhotos/>
```
Review actual cached IDs:
```xml
<loadPreviewImage previewIDs='["preview_1","preview_2","preview_3","preview_4","preview_5"]'/>
```
Requested reshoot; keep earlier photos:
```xml
<takePhoto/>
```
Saved, matching Task; keep Camera:
```xml
The photo is saved in the app album.<task.end summary="Photo saved in the app album"/>
```
Discard requested:
```xml
<closeCamera/>
```
Close succeeded and session cleared:
```xml
The camera is closed.<task.end summary="Camera closed and unsaved photos cleared"/>
```
Saved without a Task:
```xml
The photo is saved in the app album.
```
### Video examples — each block is a separate response
New recording with cue:
```xml
<wait>Tap Stop when you are done recording.</wait><startRecording/>
```
Ten seconds requested; no configureCamera:
```xml
<wait>Recording for ten seconds.</wait><startRecording durationSeconds="10"/>
```
Already prepared:
```xml
<startRecording/>
```
After ready receipt; use actual duration:
```xml
The ten-second recording is ready. Save it in the app album or discard it?
```
Authorized save; use actual recordingID:
```xml
<saveVideo recordingID="11111111-2222-4333-8444-555555555555"/>
```
User authorizes ignore:
```xml
<ignoreVideo recordingID="11111111-2222-4333-8444-555555555555"/>
```
Saved, matching Task; keep Camera:
```xml
The video is saved in the app album.<task.end summary="Video saved in the app album"/>
```
Ignored, matching Task; keep Camera:
```xml
The video was discarded.<task.end summary="Video discarded"/>
```

### Preview images across turns
Use actual current IDs from actions.camera.preview. Only attached images are evidence; State maps IDs to attachment positions. loadPreviewImage(previewID) appends one explicit selection. Use previewIDs as a JSON array to replace the selection with 1–5 photos. The latest fills a free slot. New capture displaces the first selection if full. Compare only requested attached photos. Unload removes explicit selections.

Cache: 20 originals per window, FIFO eviction; reshoots retain earlier photos. Saved originals can reload. Hidden windows suspend image delivery; close expires preview_N. Album media_N is independent. Missing/unsupported evidence never authorizes recapture.
