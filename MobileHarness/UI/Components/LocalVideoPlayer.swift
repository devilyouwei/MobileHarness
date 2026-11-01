#if os(iOS)
    import AVKit
    import SwiftUI

    /// Playback of an already-owned local file; never controls recording or file disposition.
    @MainActor struct LocalVideoPlayer: View {
        let file: URL
        @State private var player: AVPlayer?
        @Environment(\.scenePhase) private var scenePhase
        var body: some View {
            VideoPlayer(player: player)
                .onAppear { if file.isFileURL { player = AVPlayer(url: file) } }
                .onChange(of: file) { _, file in
                    player?.pause()
                    player = file.isFileURL ? AVPlayer(url: file) : nil
                }
                .onChange(of: scenePhase) { _, phase in if phase != .active { player?.pause() } }
                .onDisappear {
                    player?.pause()
                    player = nil
                }
        }
    }
#endif
