#if os(iOS)
    import SwiftUI

    @MainActor struct AudioDetectionSection: View {
        @Bindable var state: AudioDetectionState
        let controls: any AudioDetectionControlling
        @Environment(\.scenePhase) private var scenePhase
        var body: some View {
            Section {
                Button(state.isActive ? "停止检测" : "开始检测") {
                    if state.isActive { controls.stop() } else { controls.start() }
                }
                .disabled(state.phase == .stopping)
                .accessibilityIdentifier("settings.recognition.detect")
                if state.phase != .idle {
                    LabeledContent("采集方式", value: capture)
                        .accessibilityIdentifier("settings.recognition.capture")
                    if let fallback = state.snapshot.fallback {
                        Text(reason(fallback)).font(.caption).foregroundStyle(.secondary)
                    }
                    LabeledContent("麦克风", value: input)
                    LabeledContent("空间采集", value: support)
                    HStack {
                        Text(signal)
                        Spacer()
                        ProgressView(value: state.snapshot.level)
                            .frame(width: 90)
                            .accessibilityLabel("声音强度")
                    }
                    LabeledContent("声源方向", value: direction)
                        .accessibilityIdentifier("settings.recognition.direction")
                    if let error = state.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("音频检测")
            } footer: {
                Text("检测 10 秒。方向使用采集坐标，未校准。")
            }
            .onDisappear { controls.stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { controls.stop() } }
        }
        private var capture: String {
            switch state.snapshot.capture {
            case .waiting: "等待音频"
            case .spatial: "空间采集 · 4 声道"
            case .mono: "普通录音 · 单声道"
            }
        }
        private var input: String {
            if state.snapshot.permissionGranted == false { return "未授权" }
            switch state.snapshot.input {
            case .unknown: return "等待检测"
            case .builtInMicrophone: return "内置麦克风"
            case .headset: return "耳机"
            case .external: return "外接麦克风"
            }
        }
        private var support: String {
            switch state.snapshot.support {
            case .unknown: "尚未确认"
            case .supported: "支持"
            case .unsupported: "不支持"
            case .inputUnavailable: "当前输入不支持"
            }
        }
        private var signal: String {
            switch state.snapshot.signal {
            case .waiting: "等待音频"
            case .receiving: "音频正常"
            case .noAudio: "无音频"
            }
        }
        private var direction: String {
            if !state.isActive && state.snapshot.direction != .unavailable { return "检测已结束" }
            switch state.snapshot.direction {
            case .active:
                if let azimuth = state.snapshot.azimuthDegrees, let elevation = state.snapshot.elevationDegrees {
                    return String(format: "方位 %+.0f° · 俯仰 %+.0f°", azimuth, elevation)
                }
                return "等待更新"
            case .waiting: return "等待更新"
            case .inactive: return "安静"
            case .uncertain: return "方向不确定"
            case .unavailable: return "方向不可用"
            }
        }
        private func reason(_ fallback: AudioDetectionSnapshot.Fallback) -> String {
            switch fallback {
            case .inputUnavailable: "当前麦克风不支持空间采集，使用普通录音。"
            case .unsupported: "设备不支持空间采集，使用普通录音。"
            case .startupFailed: "空间采集启动失败，改用普通录音。"
            }
        }
        private var status: String {
            switch state.phase {
            case .idle: ""
            case .preparing: "正在准备麦克风…"
            case .running: "正在检测"
            case .stopping: "正在停止…"
            case .finished: "检测完成"
            case .stopped: "已停止"
            case .failed: "检测失败"
            }
        }
    }
#endif
