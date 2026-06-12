//
//  SyncUsageSummary.swift
//  Empty
//

import Foundation

nonisolated enum SyncUsageTone: String, Equatable, Sendable {
    case accent
    case neutral
    case caution
}

nonisolated struct SyncUsageSummary: Equatable, Sendable {
    var title: String
    var detail: String
    var recommendation: String
    var tone: SyncUsageTone
}

nonisolated enum SyncUsageSummaryBuilder {
    static func make(
        liveMode: SyncLiveMode,
        folderTarget: SyncSettings.FolderBackupTarget?,
        serverTarget: SyncSettings.ServerBackupTarget?,
        cloudStatus: LiveSyncProviderStatus?,
        serverStatus: LiveSyncProviderStatus?,
        pendingServerChanges: Int? = nil,
        pendingServerRetryAt: Date? = nil
    ) -> SyncUsageSummary {
        if let serverTarget {
            switch serverStatus?.state {
            case .contractReady:
                if serverTarget.autoSyncEnabled {
                    if let pendingServerRetryAt {
                        let detail: String
                        if let pendingServerChanges, pendingServerChanges > 0 {
                            detail = "最近一次自动同步没成功，系统会在 \(pendingServerRetryAt.formatted(date: .omitted, time: .shortened)) 再试一次；当前还有 \(pendingServerChanges) 处待同步变化。"
                        } else {
                            detail = "最近一次自动同步没成功，系统会在 \(pendingServerRetryAt.formatted(date: .omitted, time: .shortened)) 再试一次。"
                        }
                        return SyncUsageSummary(
                            title: "自建同步已排队重试",
                            detail: detail,
                            recommendation: "先不用改设置；等重试时间到了看一下。如果还失败，再点“测试连接”。",
                            tone: .caution
                        )
                    }
                    let usingPasskey = serverTarget.authMode == .passkeySession
                    let detail: String
                    if let pendingServerChanges, pendingServerChanges > 0 {
                        detail = usingPasskey
                            ? "这套 server 已支持自动同步，账号也已经用 Passkey 接好。本机现在还有 \(pendingServerChanges) 处待同步变化；前台自动同步会继续拉取并推送。"
                            : "这套 server 已支持自动同步。本机现在还有 \(pendingServerChanges) 处待同步变化；前台自动同步会继续拉取并推送。"
                    } else {
                        detail = usingPasskey
                            ? "这套 server 已支持自动同步，账号也已经用 Passkey 接好。你正常阅读即可；应用在前台时会定时拉取，内容变化时再推送。"
                            : "这套 server 已支持自动同步。你正常阅读即可；应用在前台时会定时拉取，内容变化时再推送。"
                    }
                    return SyncUsageSummary(
                        title: "自建同步已接好",
                        detail: detail,
                        recommendation: "平时只看“最近自动同步”是否有时间更新；出问题再展开高级状态。",
                        tone: .accent
                    )
                }
                return SyncUsageSummary(
                    title: "自建同步已保存",
                    detail: "这套 server 已具备同步契约，但自动同步还没打开。",
                    recommendation: "如果你希望以后基本不用管，打开“自动同步”即可。",
                    tone: .neutral
                )
            case .snapshotOnly:
                return SyncUsageSummary(
                    title: "Server 目前只有备份功能",
                    detail: "现在可以上传 / 恢复快照，但还没到自动同步那一步。",
                    recommendation: "把它当作“云端备份”使用；如果要自动同步，等 server 支持 live sync 再打开。",
                    tone: .neutral
                )
            case .setupRequired:
                return SyncUsageSummary(
                    title: "还差一步：检查 server",
                    detail: "目标地址已经填好，但还需要测试连接，确认它能正常响应。",
                    recommendation: "点一次“测试连接”；通过后再决定是否打开自动同步。",
                    tone: .caution
                )
            case .unavailable:
                return SyncUsageSummary(
                    title: "Server 目前连不上",
                    detail: "同步地址已保存，但最近的联通性探测没有成功。",
                    recommendation: "先点“测试连接”；如果仍失败，再检查地址、token 或 server 本身。",
                    tone: .caution
                )
            case .available, .active, .none:
                break
            }
        }

        if liveMode == .cloudKit {
            switch cloudStatus?.state {
            case .active, .available:
                return SyncUsageSummary(
                    title: "最省心：iCloud 正在工作",
                    detail: "你的阅读进度、高亮、卡片和 ReaderMemory 会跟着 iCloud 走；正文和 embedding 仍只留本机。",
                    recommendation: "如果你主要在 Apple 设备间使用，现在基本不用再管同步设置。",
                    tone: .accent
                )
            case .setupRequired:
                return SyncUsageSummary(
                    title: "iCloud 还没准备好",
                    detail: "你已经选了 iCloud，但当前设备没有可用账号。",
                    recommendation: "先登录 iCloud；如果暂时不想折腾，也可以切回“仅本机”。",
                    tone: .caution
                )
            case .unavailable, .snapshotOnly, .contractReady, .none:
                return SyncUsageSummary(
                    title: "iCloud 现在不可用",
                    detail: "应用已自动退回本机保存，所以不会丢数据，只是暂时不同步。",
                    recommendation: "可以先照常使用；等 iCloud 恢复后再切回来。",
                    tone: .caution
                )
            }
        }

        if let folderTarget {
            return SyncUsageSummary(
                title: "当前只保存在本机",
                detail: "你还没有开启实时同步，但已经选好了一个备份文件夹：\(folderTarget.displayName)。",
                recommendation: "需要时点一次“立即备份”即可；如果想更省心，优先考虑 iCloud。",
                tone: .neutral
            )
        }

        return SyncUsageSummary(
            title: "当前只保存在本机",
            detail: "这是最稳妥、最简单的起点：所有读者数据只在这台设备上。",
            recommendation: "如果你只在一台设备上用，保持这样就行；如果想省心跨设备，同步优先选 iCloud。",
            tone: .neutral
        )
    }
}
