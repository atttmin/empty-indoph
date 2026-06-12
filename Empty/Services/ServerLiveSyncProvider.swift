//
//  ServerLiveSyncProvider.swift
//  Empty
//

import Foundation

nonisolated struct ServerLiveSyncProvider: LiveSyncProvider {
    let target: SyncSettings.ServerBackupTarget?
    let bearerToken: String
    let session: URLSession

    init(
        target: SyncSettings.ServerBackupTarget?,
        bearerToken: String,
        session: URLSession = .shared
    ) {
        self.target = target
        self.bearerToken = bearerToken
        self.session = session
    }

    var kind: LiveSyncProviderKind { .server }
    var title: String { "Empty Cloud" }

    func status(selectedMode: SyncLiveMode) async -> LiveSyncProviderStatus {
        guard let target else {
            return LiveSyncProviderStatus(
                kind: kind,
                title: title,
                state: .setupRequired,
                detail: "先保存一个 Empty Cloud / 自建 Server 目标，才能探测 live sync 能力。"
            )
        }

        do {
            let health = try await ServerSnapshotClient(
                configuration: .init(
                    baseURLString: target.baseURLString,
                    namespace: target.namespace,
                    authMode: target.authMode,
                    bearerToken: bearerToken
                ),
                session: session
            ).healthCheck()
            let features = health.features ?? []
            let hasLiveSync = features.contains(LiveSyncFeature.readerLiveSyncV1.rawValue)
            let hasPasskey = features.contains(ServerPasskeyFeature.authV1.rawValue)
            if hasLiveSync {
                let detail = hasPasskey
                    ? "这个 server 已声明 reader-live-sync-v1，并且支持 Passkey 登录。"
                    : "这个 server 已声明 reader-live-sync-v1。客户端 pull/push 契约已就位，下一步只差把 coordinator 接入 live mode。"
                return LiveSyncProviderStatus(
                    kind: kind,
                    title: title,
                    state: .contractReady,
                    detail: detail,
                    features: features
                )
            }
            let detail = hasPasskey
                ? "这个 server 当前还只有 snapshot backup / restore，但已经声明了 Passkey 登录。"
                : "这个 server 当前只适合 snapshot backup / restore；还没有声明 reader-live-sync-v1。"
            return LiveSyncProviderStatus(
                kind: kind,
                title: title,
                state: .snapshotOnly,
                detail: detail,
                features: features
            )
        } catch {
            return LiveSyncProviderStatus(
                kind: kind,
                title: title,
                state: .unavailable,
                detail: "探测 server live sync 能力失败：\(error.localizedDescription)"
            )
        }
    }
}
