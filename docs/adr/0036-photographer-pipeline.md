# ADR 0036: Changed camera frames → Photographer → skeleton Action

> Historical scope: Historical camera/Agent stage. [ADR 0040](0040-shared-perception-and-event-routing.md) moved inference to VisionPerception, [ADR 0041](0041-vision-perception-skeleton-action.md) removed the display-only Photographer, and [ADR 0042](0042-show-pose-completion-tool.md) made skeleton display a Tool.

Accepted 2026-09-26. Camera input is no longer preview-only. External images enter through InputGateway; YOLO inference belongs to the new Photographer Agent, not Gateway. ModelKit supplies the shared .pose capability via the process-wide ModelManager. AgentCore remains independent of ModelKit and platform adapters; App maps platform RGB values to ImageInput and Photographer maps that to ModelKit ImageFrame.

Gateway compares 64×64 grayscale grids to the previous examined frame. Default admission is normalized mean absolute difference ≥3%; exact duplicates never pass, and first/geometry-changed frames pass. Threshold and optional minimum sampling interval are validated configuration. This explicitly favors per-frame changes over accumulated drift from the last admitted frame.

Camera native delivery and RGB transport may replace stale video frames. Photographer has one active inference and one latest pending image; it has no periodic inference loop. Increasing sequence/session checks prevent replay. Pose provider identity and weights survive camera restarts; only Agent/filter incarnations change. Camera stop hides the overlay, stops hardware, cancels/join analysis and fences old presentation callbacks.

Photographer v3 JSON declares showPose. Deterministic pose data enters shared Function Token parsing and alias resolution, then OutputGateway validates/schedules UI.showPose. Bounded string JSON preserves the existing ActionCall protocol. UI.showPose validates ≤6 COCO-17 skeletons and replaces all displayed points atomically. Empty results clear old poses. Generic runtime agent.finished/error controls reuse existing finish/cancel barriers; they do not carry UI side effects.

Camera pipeline output uses capacity eight with explicit failure rather than dropped Actions. A separate camera composition is independent of existing voice model readiness; both use the same ModelManager. Future shared cross-Agent channel ownership remains outside this stage.

✅ Gray-change sampling, latest-only perception and protocol-based visualization.
❌ Mechanical-arm commands, autonomous composition, persistent person tracking, physical safety policy and device performance/accuracy acceptance. The 摄像师 name describes its intended future role, not completed robot functionality.
