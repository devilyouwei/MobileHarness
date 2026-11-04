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
                effect: try c.decode(IslandIconEffect.self, forKey: .effect))
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

}

public enum IslandTone: String, Codable, Sendable { case neutral, blue, purple, success, warning, recording }
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
/// Semantic importance; ordering belongs to the component, independent of business owners.
public enum IslandPriority: String, Codable, Sendable {
    case background, low, normal, high, attention, critical
    var order: Int {
        switch self {
        case .background: 0
        case .low: 1
        case .normal: 2
        case .high: 3
        case .attention: 4
        case .critical: 5
        }
    }
}
public struct IslandContent: Equatable, Sendable, Codable {
    public var title: String
    public var subtitle: String
    public var primary: IslandIndicator
    public var secondary: IslandIndicator?
    public var tone: IslandTone
    public var priority: IslandPriority
    public var startedAt: Date?
    public var deadline: Date?
    public var liveActivity: Bool?
    public var expansionID: String?
    public var detail: IslandDetail?
    public init(
        title: String, subtitle: String = "", primary: IslandIndicator, tone: IslandTone = .neutral,
        priority: IslandPriority = .background, secondary: IslandIndicator? = nil, startedAt: Date? = nil,
        deadline: Date? = nil,
        liveActivity: Bool? = nil, expansionID: String? = nil, detail: IslandDetail? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.primary = primary
        self.secondary = secondary
        self.tone = tone
        self.priority = priority
        self.startedAt = startedAt
        self.deadline = deadline
        self.liveActivity = liveActivity
        self.expansionID = expansionID
        self.detail = detail?.normalized
    }
    public func validate() throws {
        guard !title.isEmpty, title.count <= 80, subtitle.count <= 160, primary.isValid,
            secondary?.isValid ?? true,
            expansionID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
            startedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
            deadline.map({ $0.timeIntervalSince1970.isFinite }) ?? true
        else { throw IslandError.invalid }
        try detail?.validate()
    }
    private enum CodingKeys: String, CodingKey {
        case title, subtitle, primary, secondary, tone, priority, startedAt, deadline, liveActivity, expansionID,
            detail
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decode(String.self, forKey: .subtitle)
        tone = try c.decode(IslandTone.self, forKey: .tone)
        priority = try c.decode(IslandPriority.self, forKey: .priority)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        deadline = try c.decodeIfPresent(Date.self, forKey: .deadline)
        liveActivity = try c.decodeIfPresent(Bool.self, forKey: .liveActivity)
        expansionID = try c.decodeIfPresent(String.self, forKey: .expansionID)
        primary = try c.decode(IslandIndicator.self, forKey: .primary)
        secondary = try c.decodeIfPresent(IslandIndicator.self, forKey: .secondary)
        detail = try c.decodeIfPresent(IslandDetail.self, forKey: .detail)?.normalized
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(subtitle, forKey: .subtitle)
        try c.encode(primary, forKey: .primary)
        try c.encodeIfPresent(secondary, forKey: .secondary)
        try c.encode(tone, forKey: .tone)
        try c.encode(priority, forKey: .priority)
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
    // Whole-island taps resume the existing scene, without interpreting destination metadata.
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

#if os(iOS)
    import ActivityKit

    struct IslandActivityAttributes: ActivityAttributes {
        typealias ContentState = IslandSystemSnapshot
        var sessionID: UUID
    }
#endif
