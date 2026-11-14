# README images

This directory contains the conceptual diagrams and feature examples used by the [project README](../../README.md). Filenames describe the content and use lowercase words separated by hyphens.

| File | Purpose |
| --- | --- |
| [mobileharness-eyes.png](mobileharness-eyes.png) | Transparent blue open-eye / chevron-wink emblem stored at 80 pixels wide and displayed at 48 pixels wide immediately before the README title, with `style="vertical-align: 0.1em;"` to lift it relative to the text baseline in renderers that preserve inline styles. GitHub strips inline styles, so this adjustment does not guarantee alignment on GitHub. Generated with built-in ImageGen from the selected [eye concept](../../output/icon-concepts/mobile-eyes-wink-v4.png); [full prompt](../../output/icon-concepts/mobile-eyes-title-transparent-prompt.txt). |
| [perception-cognition-action.svg](perception-cognition-action.svg) | Perception, Cognition and Action loop with external and internal Signals. |
| [task-skill-capabilities.svg](task-skill-capabilities.svg) | Tasks and Skill declarations: Actions, States, Instructions and dependencies. |
| [multi-agent-communication.svg](multi-agent-communication.svg) | Assistant and Writer delegation through Gateway. |
| [start-listening-demo.gif](start-listening-demo.gif) | Pressing and holding the companion’s eyes to start listening. |
| [everyday-voice-interaction.png](everyday-voice-interaction.png) | Voice interaction, captions, expressive eyes and pose overlays. |
| [interactive-multiwindow.png](interactive-multiwindow.png) | Browser and Writer windows displayed together. |
| [interactive-minimized-windows.png](interactive-minimized-windows.png) | Browser and Writer windows minimized through voice interaction. |
| [nexarm-control-demo.gif](nexarm-control-demo.gif) | Animated NexArm demonstration. |
| [nexarm-motion-demo.gif](nexarm-motion-demo.gif) | NexArm moving the mounted phone during an Assistant interaction. |
| [photography-camera.png](photography-camera.png) | An ongoing photography task with camera controls and recent-photo thumbnails. |
| [photography-album.png](photography-album.png) | Saved photos displayed in the app album grid. |
| [writer-illustrated-article.png](writer-illustrated-article.png) | An illustrated article created by Writer. |
| [writer-visual-flowchart.png](writer-visual-flowchart.png) | A Writer-created visual processing flowchart reopened from saved work. |
| [writer-drawing-demo.gif](writer-drawing-demo.gif) | A drawing taking shape in the Writer preview. |
| [web-browsing.png](web-browsing.png) | Search results in the in-app browser. |

PNG screenshots are resized proportionally to 480 pixels wide without cropping. The title emblem is separate artwork, preserves its generated alpha channel and uses an empty alt attribute because the adjacent title supplies the name. GIFs retain their original animation at 480 pixels wide; SVG diagrams remain scalable. The project README separates its text-only feature table from a four-column example gallery. The twelve screenshots and animations have their own cells, arranged in three rows of four, beginning with the listening activation demo. Previews are 200 pixels wide, preserve their aspect ratios and are clickable. Fixed preview widths help the four-column gallery use more horizontal space; GitHub’s table styling does not guarantee a full-width table. Screenshots preserve their captured interface language and visible state; they are examples, not acceptance-test results.
