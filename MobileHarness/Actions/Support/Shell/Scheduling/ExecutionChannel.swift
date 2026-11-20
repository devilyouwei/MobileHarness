import Foundation

extension ChannelScheduler {
    struct Channel {
        var queued: [Job] = []
        var running: Running?
        var count: Int { queued.count + (running == nil ? 0 : 1) }
    }
}
