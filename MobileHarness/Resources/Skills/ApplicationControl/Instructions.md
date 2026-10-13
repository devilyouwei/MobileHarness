## Application and device control

### Purpose and scope
Handle conversational requests for existing UI pages, model/resource inventory, provider settings and Bluetooth operations. Use registered functions directly from Assistant. Touch navigation, expanding panels and UI filters remain local frontend interactions; do not send them through conversational delegation.

### Workflow
1. Identify whether the request is navigation, read-only status, a resource transfer or a Bluetooth command. Load this Skill for a relevant active goal; do not create applicationControl sub-conversations.
2. For navigation, use openPage with a declared destination. For status, use the appropriate native Tool: ModelResources.snapshot, Provider.readSettings or Bluetooth.readStatus. Do not infer settings from a previously requested change.
3. For a user-requested Bluetooth command, emit the Bluetooth.control Action with a supported operation. Use only actual returned device IDs when an ID is needed. Connection/discovery admission is not connected state; readStatus provides the actual state.
4. For a user-requested model download, confirm actual resource identity, source endpoint and cellular preference. If required values are unavailable, ask rather than invent them. Emit the ModelResources.download Action; read inventory for real progress after its result. Cancel an admitted transfer with the ModelResources.cancel Action using its actual ID.
5. Distinguish request accepted, transfer in progress, resource installed and available model. Do not finish a download goal claiming installation based solely on admission; avoid rapid polling or automatic retry.
6. Report real results/errors, and finish an active task when its requested effect is established. Long-lived deterministic background work uses a declared contract; never invent a generic send payload.

### Rules
- Only ModelResources.snapshot, Provider.readSettings and Bluetooth.readStatus use native Tools. Navigation, Bluetooth commands, download/cancel use XML Action tags. All attributes are strings, including "true"/"false" for allowsCellular.
- Control Actions use System; order speech or other Channels with Core wait. Query native Tools on the following request after the control result, not alongside it when the query depends on that effect.
- Provider.readSettings is read-only and exposes no key/URL. Do not request or reveal credentials, claim a provider switch or invent a settings-write function.
- Resource inventory IDs, Bluetooth IDs and download endpoints must come from trusted configuration/results or explicit user input. No guessed device selection.
- Bluetooth accepted does not mean physically connected or completed. Read status before reporting success.
- This Skill registers no robot motion. For an explicit movement goal, use robot-interaction and its connection/feedback procedure. Navigation, status and connection queries do not authorize motion.
- On permission, network or execution failure, explain the actual result without fabricated success or automatic replay.

### Examples
User: “打开设置。” Emit `<openPage destination="settings"/>`; confirm only after navigation feedback. A user tapping the Settings button needs no Agent request.

User: “现在用的什么云模型？” Call Provider.readSettings({}); describe the returned confirmed selection, and distinguish that from a live availability test.

User: “看看机械臂连接了吗。” Call Bluetooth.readStatus({}); use the actual state. Do not wave the arm as a connection test.

User: “取消刚才下载。” Read inventory if the current transfer ID is unknown, then emit `<ModelResources.cancel id="ACTUAL_TRANSFER_ID"/>` with the real value. Wait for cancellation/cleanup feedback before confirming.

User: “扫描蓝牙设备。” Emit `<Bluetooth.control operation="scan"/>`; after its result, query Bluetooth.readStatus if actual discovery state is needed.

User: “下载这个模型。” With confirmed resource ID and endpoint, emit `<ModelResources.download id="RESOURCE_ID" endpoint="SOURCE_ENDPOINT" allowsCellular="false"/>`. Replace placeholders with real values. Admission is not installed state.
