import UI

// VisionPerception owns camera activity semantics; execution facts arrive on its existing input.
extension VisionPerceptionAgent {
    @MainActor static func cameraContent(_ camera: CameraPresentationSnapshot) -> IslandContent? {
        if let remaining = camera.countdown {
            return .init(
                title: "Photo countdown", subtitle: "\(remaining) s", primary: .symbol(name: "timer"),
                priority: .critical,
                secondary: .progress(1 / Double(max(1, remaining))),
                liveActivity: true, localizedLabels: true)
        }
        if camera.photoBusy {
            return .init(
                title: "Processing photo", primary: .symbol(name: "camera.aperture"), priority: .critical,
                secondary: .loading, localizedLabels: true)
        }
        let recording = camera.recording
        if recording.active {
            let title =
                recording.phase == .starting
                ? "Starting recording" : recording.phase == .finishing ? "Finalizing the recording" : "Recording"
            return .init(
                title: title, subtitle: "Listening paused", primary: .symbol(name: "video.fill"), tone: .recording,
                priority: .attention,
                secondary: recording.phase == .recording
                    ? .symbol(name: "record.circle.fill", effect: .pulse) : .loading,
                startedAt: recording.phase == .recording ? recording.startedAt : nil,
                liveActivity: true, localizedLabels: true)
        }
        if camera.recordedVideo != nil {
            return .init(
                title: "Recording ready", subtitle: "Open the camera to save or discard",
                primary: .symbol(name: "video"),
                priority: .high, localizedLabels: true)
        }
        #if os(iOS)
            if camera.capturedPhoto != nil {
                return .init(
                    title: "Photo ready to save", subtitle: "Open the camera to view or save",
                    primary: .symbol(name: "photo"),
                    priority: .high, localizedLabels: true)
            }
        #endif
        return nil
    }
}
