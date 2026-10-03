# ADR 0007 App 使用 Nemotron ASR

> Historical model/resource scope: current synthesis selection is [ADR0058](0058-moss-tts-nano.md); current metadata-only packaging, source declarations, explicit acquisition and safe removal are [ADR0105](0105-local-model-resource-management.md). Old bundle-weight, development-profile and Kokoro-default statements below are retained decision history, not current implementation contracts.

状态：已实施，真机运行待验收。日期：2026-09-23。

用户要求将当前 App ASR 切换为 Nemotron。AppContainer 构造并通过 SpeechRecognitionCapability 注入；RequestGateway、Agent 和 ResponseGateway 不变，TTS 继续使用 AppleSpeechSynthesis。移除联网识别开关与系统 Speech 授权，仅请求麦克风权限。不支持 iOS 27 / CoreAI / h18p 时明确失败，不退到 Apple 或云端。

App 在采集前检查 capability 并加载本地权重，加载期不录音。当前保留 VAD 整句分段：PlatformKit 的 MonoPCMResampler 用 AVAudioConverter 将有界语句转为 16 kHz 单声道 Float32，再以 4,000 采样点分包，通过现有 RequestGateway 会话顺序发送。转换器跨同一句输入保持状态并刷新尾部。partial 不触发 Agent；不宣称已实现说话过程中实时字幕。

真机 App 的构建阶段将固定 revision 的 ios 制品、manifest 和许可证复制至 bundle/Models；不复制 macos 制品。Config/Nemotron-*-Inputs/Outputs.xcfilelist 按 SDK 声明每个输入输出文件并保留 Xcode 脚本沙箱；更新制品版本时同步更新文件清单和脚本固定 revision。缺少下载制品时真机构建失败，运行前校验 SHA-256。模拟器只编译不可用分支，不携带权重。权重继续忽略 Git。未来可由安装层替换 bundle 路径，无需改变 capability。

独立 ASR 模型缓存由 provider 保留，停止录音会取消会话但不卸载权重，以便下次复用。页面销毁释放 provider；内存压力自动卸载与全局资源预算仍待实现。此次不增加 macOS App target。
