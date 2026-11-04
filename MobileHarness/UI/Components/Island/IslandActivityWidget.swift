// Layout adapted from 1998code/iOS16-Live-Activities, WidgetDemo/WidgetDemo.swift.
// DynamicIsland itself owns the shell, placement, status-bar accommodation and transitions.
import ActivityKit
import SwiftUI
import WidgetKit

@main struct MobileHarnessLiveActivityBundle: WidgetBundle {
    var body: some Widget { MobileHarnessLiveActivity() }
}

struct MobileHarnessLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IslandActivityAttributes.self) { context in
            let snapshot = context.state.presentation(stale: context.isStale)
            VStack(alignment: .leading) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(snapshot.title).font(.headline)
                        IslandActivityProgress(value: snapshot, stale: context.isStale)
                    }.padding(.trailing, 25)
                    IslandIndicatorView(value: snapshot.primary, animated: false, measuredSpectrum: false).font(
                        .title
                    ).foregroundStyle(.blue)
                }.padding(5)
                Text(snapshot.detailText ?? snapshot.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(15)
            .widgetURL(snapshot.navigationURL)
        } dynamicIsland: { context in
            let snapshot = context.state.presentation(stale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if snapshot.hasStatus {
                        IslandIndicatorView(value: snapshot.primary, animated: false, measuredSpectrum: false)
                            .font(.title3)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if snapshot.hasStatus {
                        Label {
                            IslandActivityAccessory(value: snapshot, stale: context.isStale)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 50)
                                .monospacedDigit()
                                .font(.caption2)
                        } icon: {
                            Image(
                                systemName: snapshot.startedAt != nil || snapshot.deadline != nil
                                    ? "timer" : "circle.dotted")
                        }.font(.title2)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if snapshot.detailText == nil {
                        VStack(spacing: 5) {
                            Text(snapshot.title)
                                .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let text = snapshot.detailText {
                        HStack(alignment: .center, spacing: 10) {
                            IslandIndicatorView(
                                value: snapshot.detailPrimary ?? snapshot.primary,
                                animated: false, measuredSpectrum: false
                            )
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(
                                snapshot.detailTone == "recording"
                                    ? Color.red : snapshot.detailTone == "purple" ? .purple : .cyan)
                            Text(text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.vertical, 4)
                    }
                }
            } compactLeading: {
                IslandIndicatorView(value: snapshot.primary, animated: false, measuredSpectrum: false).font(
                    .system(size: IslandCompactMetrics.symbolSize, weight: .medium)
                )
                .foregroundStyle(snapshot.tone == "recording" ? Color.red : snapshot.tone == "purple" ? .purple : .cyan)
                .accessibilityLabel(snapshot.title)
            } compactTrailing: {
                IslandActivityAccessory(value: snapshot, stale: context.isStale)
                    .multilineTextAlignment(.center).frame(
                        width: snapshot.secondary?.compactWidth ?? IslandCompactMetrics.slotWidth, height: 24
                    ).font(
                        .system(size: IslandCompactMetrics.symbolSize)
                    )
                    .foregroundStyle(
                        snapshot.tone == "recording" ? Color.red : snapshot.tone == "purple" ? .purple : .cyan)
            } minimal: {
                IslandIndicatorView(value: snapshot.primary, animated: false, measuredSpectrum: false)
            }
            .keylineTint(snapshot.tone == "recording" ? .red : snapshot.tone == "purple" ? .purple : .cyan)
            .widgetURL(snapshot.navigationURL)
        }
    }
}
private struct IslandActivityProgress: View {
    let value: IslandSystemSnapshot
    let stale: Bool
    var body: some View {
        if !value.paused, !stale, value.endedAt == nil {
            if let start = value.startedAt, let end = value.deadline, start < end {
                ProgressView(timerInterval: start...end, countsDown: false).tint(.blue).progressViewStyle(.linear)
            } else if let progress = value.secondary?.progressValue {
                ProgressView(value: progress).tint(.blue).progressViewStyle(.linear)
            }
        }
    }
}
private struct IslandActivityAccessory: View {
    let value: IslandSystemSnapshot
    let stale: Bool
    var body: some View {
        if !value.paused, !stale, value.endedAt == nil, let indicator = value.secondary {
            IslandIndicatorView(value: indicator, animated: false, measuredSpectrum: false)
        }

    }
}
#if DEBUG
    private struct IslandActivityModesPreview: PreviewProvider {
        static let attributes = IslandActivityAttributes(sessionID: UUID())
        static let content = IslandSystemSnapshot(
            generation: UUID(), activityID: UUID(), title: "拍摄照片", subtitle: "等待你的操作",
            primary: .symbol(name: "camera"), tone: "blue", updatedAt: Date())
        static var previews: some View {
            attributes.previewContext(content, viewKind: .dynamicIsland(.compact)).previewDisplayName("紧凑")
            attributes.previewContext(content, viewKind: .dynamicIsland(.minimal)).previewDisplayName("最小")
            attributes.previewContext(content, viewKind: .dynamicIsland(.expanded)).previewDisplayName("展开")
            attributes.previewContext(content, viewKind: .content).previewDisplayName("锁屏")
        }
    }
#endif
