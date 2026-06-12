//
//  SyncSettings.swift
//  Empty
//

import Foundation

nonisolated enum SyncLiveMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    case cloudKit

    var title: String {
        switch self {
        case .localOnly: "仅本机"
        case .cloudKit: "iCloud"
        }
    }

    var detail: String {
        switch self {
        case .localOnly:
            "阅读进度、高亮、卡片只保存在这台设备。"
        case .cloudKit:
            "通过 iCloud 同步读者数据；书文件与本地 embedding 不入云。"
        }
    }

    var badge: String {
        switch self {
        case .localOnly: "本机"
        case .cloudKit: "自动"
        }
    }
}

nonisolated struct SyncProviderDescriptor: Identifiable, Equatable, Sendable {
    let mode: SyncLiveMode
    let title: String
    let detail: String
    let badge: String

    var id: SyncLiveMode { mode }
}

nonisolated enum BackupProviderKind: String, Codable, CaseIterable, Sendable {
    case folder
    case server

    var title: String {
        switch self {
        case .folder: "文件夹快照"
        case .server: "Empty Cloud / 自建 Server"
        }
    }

    var detail: String {
        switch self {
        case .folder:
            "选择任意 Files / File Provider 文件夹，写入可恢复的读者快照。"
        case .server:
            "通过兼容 Empty snapshot API 的 HTTPS 服务上传 / 拉取读者快照。"
        }
    }
}

nonisolated struct BackupProviderDescriptor: Identifiable, Equatable, Sendable {
    let kind: BackupProviderKind
    let title: String
    let detail: String

    var id: BackupProviderKind { kind }
}

nonisolated enum ServerAuthMode: String, Codable, CaseIterable, Sendable {
    case none
    case bearer

    var title: String {
        switch self {
        case .none: "无鉴权"
        case .bearer: "Bearer Token"
        }
    }
}

nonisolated enum SyncProviderCatalog {
    static let liveProviders: [SyncProviderDescriptor] = SyncLiveMode.allCases.map {
        SyncProviderDescriptor(mode: $0, title: $0.title, detail: $0.detail, badge: $0.badge)
    }

    static let backupProviders: [BackupProviderDescriptor] = BackupProviderKind.allCases.map {
        BackupProviderDescriptor(kind: $0, title: $0.title, detail: $0.detail)
    }
}

nonisolated struct SyncSettings: Codable, Equatable, Sendable {
    nonisolated struct FolderBackupTarget: Codable, Equatable, Sendable {
        var bookmarkData: Data
        var displayName: String
        var lastSnapshotAt: Date?
    }

    nonisolated struct ServerBackupTarget: Codable, Equatable, Sendable {
        var baseURLString: String
        var namespace: String
        var authMode: ServerAuthMode
        var lastSnapshotAt: Date?
        var lastValidatedAt: Date?
        var liveCursor: LiveSyncCursor? = nil
        var lastLivePullAt: Date? = nil
        var lastLivePushAt: Date? = nil

        var displayName: String {
            guard let url = URL(string: baseURLString), let host = url.host(), !host.isEmpty else {
                return baseURLString
            }
            return host
        }

        var shortCursor: String? {
            guard let opaqueValue = liveCursor?.opaqueValue, !opaqueValue.isEmpty else { return nil }
            return String(opaqueValue.prefix(18))
        }
    }

    static let serverTokenAccount = "sync.server.bearer-token"

    var liveMode: SyncLiveMode = .cloudKit
    var folderTarget: FolderBackupTarget?
    var serverTarget: ServerBackupTarget?

    private static let storageKey = "sync.settings.v2"
    private static let legacyStorageKey = "sync.settings.v1"

    private nonisolated struct LegacySyncSettings: Codable {
        var liveMode: SyncLiveMode = .cloudKit
        var folderTarget: FolderBackupTarget?
    }

    static func load(defaults: UserDefaults = .standard) -> SyncSettings {
        if let data = defaults.data(forKey: storageKey),
           let settings = try? JSONDecoder().decode(SyncSettings.self, from: data) {
            return settings
        }
        if let legacyData = defaults.data(forKey: legacyStorageKey),
           let legacy = try? JSONDecoder().decode(LegacySyncSettings.self, from: legacyData) {
            return SyncSettings(
                liveMode: legacy.liveMode,
                folderTarget: legacy.folderTarget,
                serverTarget: nil
            )
        }
        return SyncSettings()
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
