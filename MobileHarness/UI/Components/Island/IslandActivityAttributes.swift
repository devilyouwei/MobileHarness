import Foundation

public enum IslandError: String, Error, Sendable, LocalizedError {
    case unavailable, missing, capacity, stale, invalid, owner, interrupted, busy, systemControlled
    public var errorDescription: String? {
        switch self {
        case .systemControlled: "灵动岛布局和动画由组件管理；仅支持 compact/expanded，展开需要详情内容。"
        default: "灵动岛：" + rawValue
        }
    }
}

public enum IslandIconEffect: String, Codable, Sendable { case none, pulse, bounce, variableColor }
public enum IslandIndicator: Equatable, Hashable, Sendable, Codable {
    case symbol(name: String, effect: IslandIconEffect = .none)
    case loading, spectrum
    case progress(Double)
    case elapsed(startedAt: Date)
    public var symbolName: String? {
        if case .symbol(let name, _) = self { return name }
        return nil
    }
    public var progressValue: Double? {
        if case .progress(let value) = self { return value }
        return nil
    }
    public var isValid: Bool {
        switch self {
        case .symbol(let name, _):
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80
        case .elapsed(let start):
            return start.timeIntervalSinceReferenceDate.isFinite && start < .distantFuture && start > .distantPast
        case .progress(let value): return value.isFinite && (0...1).contains(value)
        default: return true
        }
    }
    private enum CodingKeys: String, CodingKey { case kind, symbol, effect, value, startedAt }
    private enum Kind: String, Codable { case symbol, loading, spectrum, progress, elapsed }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .symbol:
            self = .symbol(
                name: try c.decode(String.self, forKey: .symbol),
                effect: try c.decodeIfPresent(IslandIconEffect.self, forKey: .effect) ?? .none)
        case .elapsed: self = .elapsed(startedAt: try c.decode(Date.self, forKey: .startedAt))
        case .loading: self = .loading
        case .spectrum: self = .spectrum
        case .progress: self = .progress(try c.decode(Double.self, forKey: .value))
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name, let effect):
            try c.encode(Kind.symbol, forKey: .kind)
            try c.encode(name, forKey: .symbol)
            try c.encode(effect, forKey: .effect)
        case .elapsed(let start):
            try c.encode(Kind.elapsed, forKey: .kind)
            try c.encode(start, forKey: .startedAt)
        case .loading: try c.encode(Kind.loading, forKey: .kind)
        case .spectrum: try c.encode(Kind.spectrum, forKey: .kind)
        case .progress(let value):
            try c.encode(Kind.progress, forKey: .kind)
            try c.encode(value, forKey: .value)
        }
    }
    static func decodeLegacy(_ trailing: String?, progress: Double?) -> Self? {
        switch trailing {
        case "loading": .loading
        case "spectrum": .spectrum
        case "progress": .progress(progress ?? 0)
        case "recording": .symbol(name: "record.circle.fill", effect: .pulse)
        default: nil
        }
    }
}

public enum IslandTone: String, Codable, Sendable { case neutral, blue, success, warning, recording }
public typealias IslandThumbnailID = UUID
public struct IslandDetail: Equatable, Codable, Sendable {
    public var text: String?
    public var thumbnail: IslandThumbnailID?
    public init(text: String? = nil, thumbnail: IslandThumbnailID? = nil) {
        self.text = text
        self.thumbnail = thumbnail
    }
    public var normalized: Self? {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = Self(text: text?.isEmpty == false ? text : nil, thumbnail: thumbnail)
        return result.text == nil && result.thumbnail == nil ? nil : result
    }
    public func validate() throws { if let text, text.count > 320 { throw IslandError.invalid } }
}
public struct IslandContent: Equatable, Sendable, Codable {
    public var title: String
    public var subtitle: String
    public var primary: IslandIndicator
    public var secondary: IslandIndicator?
    public var tone: IslandTone
    public var rank: Int
    public var startedAt: Date?
    public var deadline: Date?
    public var liveActivity: Bool?
    public var expansionID: String?
    public var detail: IslandDetail?
    public init(
        title: String, subtitle: String = "", primary: IslandIndicator, tone: IslandTone = .neutral,
        rank: Int = 0, secondary: IslandIndicator? = nil, startedAt: Date? = nil, deadline: Date? = nil,
        liveActivity: Bool? = nil, expansionID: String? = nil, detail: IslandDetail? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primary = primary
        self.secondary = secondary
        self.tone = tone
        self.rank = rank
        self.startedAt = startedAt
        self.deadline = deadline
        self.liveActivity = liveActivity
        self.expansionID = expansionID
        self.detail = detail?.normalized
    }
    public func validate() throws {
        guard !title.isEmpty, title.count <= 80, subtitle.count <= 160, primary.isValid,
            secondary?.isValid ?? true, (0...100).contains(rank),
            expansionID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
            startedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
            deadline.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw IslandError.invalid }
        try detail?.validate()
    }
    private enum CodingKeys: String, CodingKey {
        case title, subtitle, primary, secondary, tone, rank, startedAt, deadline, liveActivity, expansionID,
            detail, symbol, trailing, progress
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        tone = try c.decodeIfPresent(IslandTone.self, forKey: .tone) ?? .neutral
        rank = try c.decodeIfPresent(Int.self, forKey: .rank) ?? 0
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        liveActivity = try c.decodeIfPresent(Bool.self, forKey: .liveActivity)
        expansionID = try c.decodeIfPresent(String.self, forKey: .expansionID)
        if let indicator = try c.decodeIfPresent(IslandIndicator.self, forKey: .primary) {
            primary = indicator
        } else {
            let legacy = try c.decode(String.self, forKey: .symbol)
            primary = .symbol(name: legacy.isEmpty ? "circle.dotted" : legacy)
        }
        secondary =
            try c.decodeIfPresent(IslandIndicator.self, forKey: .secondary)
            ?? IslandIndicator.decodeLegacy(
                c.decodeIfPresent(String.self, forKey: .trailing),
                progress: c.decodeIfPresent(Double.self, forKey: .progress))
        detail = try c.decodeIfPresent(IslandDetail.self, forKey: .detail)?.normalized
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(subtitle, forKey: .subtitle)
        try c.encode(primary, forKey: .primary)
        try c.encodeIfPresent(secondary, forKey: .secondary)
        try c.encode(tone, forKey: .tone)
        try c.encode(rank, forKey: .rank)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encodeIfPresent(liveActivity, forKey: .liveActivity)
        try c.encodeIfPresent(expansionID, forKey: .expansionID)
        try c.encodeIfPresent(detail, forKey: .detail)
    }
}

/// Small, presentation-only wire value shared by the app and its WidgetKit extension.
struct IslandSystemSnapshot: Codable, Hashable, Sendable {
    var generation: UUID
    var activityID: UUID
    var title: String
    var subtitle: String
    var primary: IslandIndicator
    var secondary: IslandIndicator?
    var tone: String
    var startedAt: Date?
    var deadline: Date?
    var updatedAt: Date
    var endedAt: Date?
    var paused: Bool = false
    var attentionID: String?
    var detailText: String?
    var detailPrimary: IslandIndicator?
    var detailTone: String?
    var hasStatus: Bool = true

    func validatedPayload() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= 3500 else { throw IslandErrorPayload.tooLarge }
        return data
    }
    enum IslandErrorPayload: Error { case tooLarge }
    static var openURL: URL? { URL(string: "mobileharness://island") }
    // Whole-island taps resume the existing scene, regardless of legacy destination metadata.
    var navigationURL: URL? { Self.openURL }

    func presentation(stale: Bool) -> Self {
        guard stale || paused || endedAt != nil else { return self }
        var value = self
        let message = endedAt != nil ? "活动已结束" : paused ? "已暂停更新" : "状态已过期"
        value.title = message
        value.subtitle = message + " · 打开 App 查看"
        value.primary = .symbol(name: endedAt != nil ? "checkmark.circle" : "pause.circle")
        value.secondary = nil
        value.startedAt = nil
        value.deadline = nil
        value.tone = "neutral"
        value.detailPrimary = value.primary
        value.detailTone = value.tone
        value.detailText = value.subtitle
        value.hasStatus = false
        return value
    }

}

// Keep ActivityKit's already-persisted snapshots readable when upgrading an installed app.
extension IslandSystemSnapshot {
    private enum CodingKeys: String, CodingKey {
        case generation, activityID, title, subtitle, primary, secondary, tone, startedAt, deadline, updatedAt, endedAt,
            paused, attentionID, detailText, detailPrimary, detailTone, hasStatus, symbol, trailing, progress
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = try c.decode(UUID.self, forKey: .generation)
        activityID = try c.decode(UUID.self, forKey: .activityID)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decode(String.self, forKey: .subtitle)
        tone = try c.decode(String.self, forKey: .tone)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        attentionID = try c.decodeIfPresent(String.self, forKey: .attentionID)
        detailText = try c.decodeIfPresent(String.self, forKey: .detailText)
        detailPrimary = try c.decodeIfPresent(IslandIndicator.self, forKey: .detailPrimary)
        detailTone = try c.decodeIfPresent(String.self, forKey: .detailTone)
        hasStatus = try c.decodeIfPresent(Bool.self, forKey: .hasStatus) ?? (detailText == nil)
        primary =
            try c.decodeIfPresent(IslandIndicator.self, forKey: .primary)
            ?? .symbol(name: c.decodeIfPresent(String.self, forKey: .symbol) ?? "circle.dotted")
        secondary =
            try c.decodeIfPresent(IslandIndicator.self, forKey: .secondary)
            ?? IslandIndicator.decodeLegacy(
                c.decodeIfPresent(String.self, forKey: .trailing),
                progress: c.decodeIfPresent(Double.self, forKey: .progress))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(generation, forKey: .generation)
        try c.encode(activityID, forKey: .activityID)
        try c.encode(title, forKey: .title)
        try c.encode(subtitle, forKey: .subtitle)
        try c.encode(primary, forKey: .primary)
        try c.encodeIfPresent(secondary, forKey: .secondary)
        try c.encode(tone, forKey: .tone)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(deadline, forKey: .deadline)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(paused, forKey: .paused)
        try c.encodeIfPresent(attentionID, forKey: .attentionID)
        try c.encodeIfPresent(detailText, forKey: .detailText)
        try c.encodeIfPresent(detailPrimary, forKey: .detailPrimary)
        try c.encodeIfPresent(detailTone, forKey: .detailTone)
        try c.encode(hasStatus, forKey: .hasStatus)
    }
}

#if os(iOS)
    import ActivityKit

    struct IslandActivityAttributes: ActivityAttributes {
        typealias ContentState = IslandSystemSnapshot
        var sessionID: UUID
    }
#endif
