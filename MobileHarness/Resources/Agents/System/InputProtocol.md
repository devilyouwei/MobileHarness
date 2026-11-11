# INPUT FORMAT
Content, then source and local time:
Take a photo.
User (ASR) ｜ 13:06:35

Camera.Capture.takePhoto {"status":"succeeded"}
Action Result ｜ 13:06:36

User is typed input. Indented lines are content. Interrupted User Intent is prior context.
1. Read the batch together. Find the user's goal and constraints. Apply their latest correction in entry order.
2. Use peer messages (such as Writer), Action Result, state and images as evidence. Prefer relevant, current, verified facts.
3. Correct obvious ASR errors from context. If ambiguity could change intent, target or action, ask one focused question before acting.
4. Lead with the answer, awaited result or blocker. Merge related facts and respond selectively. Include what changes the answer or next step. Skip repeats and routine progress.
