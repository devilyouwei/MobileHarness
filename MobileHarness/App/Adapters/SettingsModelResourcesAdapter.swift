import Foundation
import ModelKitRuntime
import UI

enum SettingsModelResourcesAdapter {
    static func validate(_ draft: ModelResourceSourceDraft) throws -> ModelResourceSourceDraft {
        do {
            let source = try ModelDownloadSource(endpoint: draft.endpoint, allowsCellular: true)
            return ModelResourceSourceDraft(
                endpoint: source.endpoint, allowsCellular: source.allowsCellular,
                useCustomRecognition: draft.useCustomRecognition, useCustomSynthesis: draft.useCustomSynthesis)
        } catch { throw SourceError() }
    }
    private struct SourceError: LocalizedError {
        var errorDescription: String? { "请填写 HTTPS 域名，不包含路径、查询参数或账号密码" }
    }
    static func items(_ manager: ModelManager) async throws -> [ModelResourceItem] {
        try await manager.artifactSnapshots().map { snapshot in
            let status: String
            switch snapshot.phase {
            case .notInstalled: status = "未下载"
            case .queued: status = "等待下载"
            case .downloading: status = "正在下载"
            case .verifying: status = "校验并安装"
            case .installed: status = "已安装"
            case .deleting: status = "正在删除"
            case .failed: status = "失败，可重试或删除修复"
            }
            return ModelResourceItem(
                id: snapshot.artifact.id, name: snapshot.artifact.name, status: status,
                bytes: snapshot.artifact.downloadBytes,
                progress: min(1, Double(snapshot.completedBytes) / Double(max(1, snapshot.artifact.downloadBytes))),
                installed: snapshot.phase == .installed,
                active: [.queued, .downloading, .verifying, .deleting].contains(snapshot.phase),
                failure: snapshot.failure.map {
                    switch $0 {
                    case "incompatible": return "模型版本已变更，请删除旧资源后重新下载"
                    case "integrity": return "文件校验失败，请检查下载来源后重试"
                    case "removal": return "删除未完成，模型文件仍保留，请重试删除"
                    case "transferIndex":
                        return snapshot.phase == .installed
                            ? "模型已安装，下载任务记录未能保存；无需重新下载"
                            : "下载任务记录未能保存，请确认设备已解锁并重试"
                    default:
                        if $0.hasPrefix("network:") {
                            return "网络传输中断，已保留完成的文件；可继续下载（\($0.dropFirst(8))）"
                        }
                        return "下载未完成，可继续下载或删除修复。错误：\($0.prefix(160))"
                    }
                },
                revision: snapshot.artifact.revision,
                installedBytes: snapshot.installedBytes ?? snapshot.artifact.installedBytes,
                license: snapshot.artifact.license,
                activity: {
                    switch snapshot.phase {
                    case .queued: return .queued
                    case .downloading: return .downloading
                    case .verifying: return .installing
                    case .deleting: return .deleting
                    default: return nil
                    }
                }())
        }
    }
}
