//
//  CloudKitLiveSyncProvider.swift
//  Empty
//

import CloudKit
import Foundation
import Security

nonisolated struct CloudKitLiveSyncProvider: LiveSyncProvider {
    private static let defaultEntitlementLoader: @Sendable () -> Bool = {
        defaultHasCloudKitEntitlement()
    }

    private let isEphemeral: Bool
    private let hasEntitlement: @Sendable () -> Bool
    private let accountStatusLoader: @Sendable () async throws -> CKAccountStatus

    init(
        isEphemeral: Bool,
        hasEntitlement: @escaping @Sendable () -> Bool = Self.defaultEntitlementLoader,
        accountStatusLoader: @escaping @Sendable () async throws -> CKAccountStatus = Self.defaultAccountStatus
    ) {
        self.isEphemeral = isEphemeral
        self.hasEntitlement = hasEntitlement
        self.accountStatusLoader = accountStatusLoader
    }

    var kind: LiveSyncProviderKind { .cloudKit }
    var title: String { "iCloud" }

    func status(selectedMode: SyncLiveMode) async -> LiveSyncProviderStatus {
        if isEphemeral {
            return LiveSyncProviderStatus(
                kind: kind,
                title: title,
                state: .unavailable,
                detail: "当前是测试 / clean-room 容器，实时同步固定为仅本机。"
            )
        }

        guard hasEntitlement() else {
            return LiveSyncProviderStatus(
                kind: kind,
                title: title,
                state: .unavailable,
                detail: "当前运行的 app bundle 没有 iCloud / CloudKit entitlement；已自动退回本机模式。"
            )
        }

        do {
            let accountStatus = try await accountStatusLoader()
            switch accountStatus {
            case .available:
                return LiveSyncProviderStatus(
                    kind: kind,
                    title: title,
                    state: selectedMode == .cloudKit ? .active : .available,
                    detail: selectedMode == .cloudKit
                        ? "iCloud 账号可用，当前 synced store 正在走 CloudKit。"
                        : "iCloud 账号可用；切到 iCloud 后，synced store 会自动恢复 CloudKit。"
                )
            case .noAccount:
                return LiveSyncProviderStatus(
                    kind: kind,
                    title: title,
                    state: .setupRequired,
                    detail: "这台设备还没有可用的 iCloud 账号；登录后才能启用 CloudKit 实时同步。"
                )
            case .restricted:
                return LiveSyncProviderStatus(
                    kind: kind,
                    title: title,
                    state: .unavailable,
                    detail: "系统当前限制了 iCloud / CloudKit 访问。"
                )
            case .temporarilyUnavailable:
                return LiveSyncProviderStatus(
                    kind: kind,
                    title: title,
                    state: .unavailable,
                    detail: "CloudKit 目前暂不可用；稍后再试。"
                )
            case .couldNotDetermine:
                return LiveSyncProviderStatus(
                    kind: kind,
                    title: title,
                    state: .unavailable,
                    detail: "暂时无法判断 CloudKit 账号状态。"
                )
            @unknown default:
                return LiveSyncProviderStatus(
                    kind: kind,
                    title: title,
                    state: .unavailable,
                    detail: "收到未知的 CloudKit 状态。"
                )
            }
        } catch {
            return LiveSyncProviderStatus(
                kind: kind,
                title: title,
                state: .unavailable,
                detail: "读取 CloudKit 状态失败：\(error.localizedDescription)"
            )
        }
    }

    private static func defaultHasCloudKitEntitlement() -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let keys = [
            "com.apple.developer.icloud-services",
            "com.apple.developer.icloud-container-identifiers",
            "com.apple.developer.ubiquity-container-identifiers",
        ]
        for key in keys {
            let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
            if let array = value as? [Any], !array.isEmpty {
                return true
            }
            if value != nil {
                return true
            }
        }
        return false
        #else
        true
        #endif
    }

    private static func defaultAccountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            CKContainer.default().accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }
}
