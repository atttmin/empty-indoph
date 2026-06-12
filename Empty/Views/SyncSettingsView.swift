//
//  SyncSettingsView.swift
//  Empty
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SyncSettingsView: View {
    @EnvironmentObject private var appSession: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext

    @State private var isPickingFolder = false
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var confirmRestore = false
    @State private var confirmServerRestore = false
    @State private var showAdvancedStatus = false
    @State private var showAdvancedServer = false
    @State private var serverBaseURL = ""
    @State private var serverNamespace = "default"
    @State private var serverToken = ""
    @State private var serverDisplayName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summarySection
                    liveSyncSection
                    liveSyncStatusSection
                    folderBackupSection
                    serverBackupSection
                    roadmapSection
                    if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.accent)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .emptyCard(palette, radius: 12)
                    }
                }
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 20, trailing: 20))
            }
        }
        .background(palette.window)
        .onAppear {
            loadServerDraft()
        }
        .task {
            await appSession.refreshLiveSyncStatuses()
            appSession.refreshServerPendingMutations()
        }
        .fileImporter(
            isPresented: $isPickingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleFolderPick
        )
        .confirmationDialog(
            "从这个文件夹恢复最新 Empty 读者快照？",
            isPresented: $confirmRestore,
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                restoreFromFolder()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("恢复只会 merge / upsert 已备份的读者数据，不会导入正文、chunk 或 embedding。")
        }
        .confirmationDialog(
            "从 server 恢复这个命名空间的最新读者快照？",
            isPresented: $confirmServerRestore,
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                restoreFromServer()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("server 恢复同样只 merge / upsert 读者数据；正文、chunk、译文缓存与 embedding 仍留在本机。")
        }
        .alert(
            "出了点问题",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        #if os(iOS)
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("同步与备份")
                    .font(.system(size: 17, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text("同步读者数据，不同步书正文")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("×")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink3)
                    .frame(width: 28, height: 28)
                    .background(palette.accentSoft, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 16))
    }

    private var summarySection: some View {
        let summary = appSession.syncUsageSummary
        return VStack(alignment: .leading, spacing: 10) {
            Text("怎么用最省心")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.title)
                    .font(.system(size: 15, weight: .black, design: .serif))
                    .foregroundStyle(summaryToneColor(for: summary.tone))
                Text(summary.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink2)
                Text(summary.recommendation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
                HStack(spacing: 8) {
                    if appSession.effectiveLiveMode != .cloudKit && !appSession.isEphemeral {
                        actionButton("用 iCloud") { applyLiveMode(.cloudKit) }
                            .disabled(isBusy)
                    }
                    if appSession.syncSettings.folderTarget != nil {
                        actionButton(isBusy ? "备份中…" : "立即备份") { backupToFolder() }
                            .disabled(isBusy)
                    }
                    if currentServerLiveStatus?.state == .contractReady, !appSession.serverAutoSyncEnabled {
                        actionButton("打开自动同步") {
                            appSession.setServerAutoSyncEnabled(true)
                            statusMessage = "已打开自动同步。"
                        }
                        .disabled(isBusy)
                    }
                    if appSession.serverSupportsPasskeyAuth, appSession.currentServerPasskeySession == nil {
                        actionButton(isBusy ? "登录中…" : "登录账号") { signInPasskeyAccount() }
                            .disabled(isBusy)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .emptyCard(palette, radius: 12)
        }
    }

    private var liveSyncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实时同步")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(SyncProviderCatalog.liveProviders) { provider in
                    Button {
                        applyLiveMode(provider.mode)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(provider.title)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(palette.ink)
                                    Text(provider.badge)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(provider.mode == appSession.effectiveLiveMode ? palette.window : palette.ink3)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(
                                            provider.mode == appSession.effectiveLiveMode ? palette.accent : palette.accentSoft,
                                            in: Capsule()
                                        )
                                }
                                Text(provider.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.ink2)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: provider.mode == appSession.effectiveLiveMode ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(provider.mode == appSession.effectiveLiveMode ? palette.accent : palette.line2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .emptyCard(palette, radius: 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy || appSession.isEphemeral)
                }
            }
            Text("书库元数据、进度、高亮、卡片和 ReaderMemory 可同步；EPUB/PDF 文件、章节正文、翻译缓存、MemoryEmbedding 仍留在本机。")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink3)
            if appSession.isEphemeral {
                Text("当前是测试 / clean-room 容器，实时同步固定为仅本机。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.accent)
            }
        }
    }

    private var liveSyncStatusSection: some View {
        DisclosureGroup(isExpanded: $showAdvancedStatus) {
            VStack(alignment: .leading, spacing: 10) {
                if appSession.liveSyncStatuses.isEmpty, appSession.isRefreshingLiveSyncStatuses {
                    Text("正在探测 iCloud 与 Empty Cloud 状态…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.ink3)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .emptyCard(palette, radius: 12)
                } else {
                    ForEach(appSession.liveSyncStatuses, id: \.kind) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text(status.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(palette.ink)
                                Text(status.state.badgeTitle)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(badgeForeground(for: status.state))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(badgeBackground(for: status.state), in: Capsule())
                                Spacer()
                                Text(status.checkedAt.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(palette.ink3)
                            }
                            Text(status.detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.ink2)
                            if !status.features.isEmpty {
                                Text("features · \(status.features.joined(separator: ", "))")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(palette.ink3)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .emptyCard(palette, radius: 12)
                    }
                }
                Text("这些状态主要给排查问题用。平时能正常同步时，可以不用展开。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
            }
            .padding(.top, 10)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("高级状态与排查")
                        .font(.system(size: 12, weight: .bold))
                        .kerning(1.4)
                        .foregroundStyle(palette.ink3)
                    Text("如果只是正常使用，这部分可以忽略。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(palette.ink3)
                }
                Spacer()
                actionButton(appSession.isRefreshingLiveSyncStatuses ? "探测中…" : "刷新状态") {
                    refreshLiveSyncStatuses()
                }
                .disabled(isBusy || appSession.isRefreshingLiveSyncStatuses)
            }
        }
    }

    private var folderBackupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第三方云 / 文件夹")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            VStack(alignment: .leading, spacing: 10) {
                Text("如果你只想“自己选一个网盘或硬盘目录”，就用这个。它更像手动备份，不是实时同步。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink2)
                if let target = appSession.syncSettings.folderTarget {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(target.displayName)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(palette.ink)
                            Text(FolderBackupProvider.snapshotFilename)
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(palette.ink3)
                        }
                        if let lastSnapshotAt = target.lastSnapshotAt {
                            Text("上次备份 · \(lastSnapshotAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                        HStack(spacing: 8) {
                            actionButton("更换文件夹") { isPickingFolder = true }
                            actionButton(isBusy ? "备份中…" : "立即备份") { backupToFolder() }
                                .disabled(isBusy)
                            actionButton(isBusy ? "恢复中…" : "恢复最新备份") { confirmRestore = true }
                                .disabled(isBusy)
                        }
                        Button(role: .destructive) {
                            appSession.clearBackupFolder()
                            statusMessage = "已移除文件夹目标。"
                        } label: {
                            Text("移除目标")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .emptyCard(palette, radius: 12)
                } else {
                    actionButton("选择文件夹") { isPickingFolder = true }
                }
                Text("适合 Dropbox / OneDrive / Google Drive / SMB / NAS 等目录型存放位置。恢复时只会合并读者数据，不会导入正文与 embedding。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
            }
        }
    }

    private var serverBackupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自建同步 / Empty Cloud")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            VStack(alignment: .leading, spacing: 10) {
                Text("如果你以后想在 Apple 之外也能同步，主要看这一栏。最简单的用法：填地址 → 测试连接 → 打开自动同步。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink2)
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Base URL", placeholder: "https://sync.example.com", text: $serverBaseURL)
                    labeledField("Namespace", placeholder: "default", text: $serverNamespace)
                    labeledSecureField("Bearer Token（可留空；有 Passkey 时通常不用填）", placeholder: "token-…", text: $serverToken)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .emptyCard(palette, radius: 12)

                if let target = appSession.syncSettings.serverTarget {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已保存目标 · \(target.displayName)")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(palette.ink)
                        Text("命名空间 · \(target.namespace) · \(target.authMode.title)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.ink3)
                        if let displayName = target.accountDisplayName {
                            Text("当前账号 · \(displayName)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.accent)
                        }
                        if let nextRetryAt = target.nextAutoRetryAt {
                            Text("已安排重试 · \(nextRetryAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.red)
                        } else if let backgroundScheduledAt = appSession.autoSyncRuntime.backgroundScheduledAt {
                            Text("后台唤醒已安排 · \(backgroundScheduledAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        } else if let lastAutoSyncAt = target.lastAutoSyncAt {
                            Text("最近自动同步 · \(lastAutoSyncAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        } else if let lastSnapshotAt = target.lastSnapshotAt {
                            Text("最近 server 备份 · \(lastSnapshotAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .emptyCard(palette, radius: 12)
                }

                if appSession.serverSupportsPasskeyAuth || appSession.currentServerPasskeySession != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("账号登录")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(palette.ink)
                        if let account = appSession.currentServerPasskeySession {
                            Text("已用 Passkey 连接账号 \(account.displayName)。以后换设备时，再登录一次就能继续同步。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.ink2)
                            if let expiresAt = account.expiresAt {
                                Text("会话到期 · \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(palette.ink3)
                            }
                            HStack(spacing: 8) {
                                actionButton(isBusy ? "检查中…" : "刷新账号状态") { refreshPasskeyAccount() }
                                    .disabled(isBusy)
                                actionButton(isBusy ? "退出中…" : "退出账号") { signOutPasskeyAccount() }
                                    .disabled(isBusy)
                            }
                        } else {
                            Text("这个 server 已声明 Passkey 登录。你可以不再手动管理 token：第一次创建账号，之后直接登录。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(palette.ink2)
                            labeledField("显示名称（首次创建账号可选）", placeholder: "你的名字", text: $serverDisplayName)
                            HStack(spacing: 8) {
                                actionButton(isBusy ? "创建中…" : "创建 Passkey 账号") { registerPasskeyAccount() }
                                    .disabled(isBusy)
                                actionButton(isBusy ? "登录中…" : "已有账号登录") { signInPasskeyAccount() }
                                    .disabled(isBusy)
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .emptyCard(palette, radius: 12)
                }

                HStack(spacing: 8) {
                    actionButton("保存目标") { saveServerTarget() }
                        .disabled(isBusy)
                    actionButton(isBusy ? "检查中…" : "测试连接") { testServerConnection() }
                        .disabled(isBusy)
                    actionButton(isBusy ? "上传中…" : "上传备份") { backupToServer() }
                        .disabled(isBusy)
                    actionButton(isBusy ? "恢复中…" : "恢复备份") { confirmServerRestore = true }
                        .disabled(isBusy)
                }

                if let status = currentServerLiveStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("自动同步")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(palette.ink)
                            Text(status.state.badgeTitle)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(badgeForeground(for: status.state))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(badgeBackground(for: status.state), in: Capsule())
                        }
                        Text(simpleServerStatusMessage(
                            for: status,
                            retryAt: appSession.autoSyncRuntime.nextRetryAt,
                            backgroundScheduledAt: appSession.autoSyncRuntime.backgroundScheduledAt
                        ))
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.ink2)

                        if status.state == .contractReady {
                            Toggle(isOn: Binding(
                                get: { appSession.serverAutoSyncEnabled },
                                set: { appSession.setServerAutoSyncEnabled($0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("打开自动同步")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(palette.ink)
                                    Text("前台会定时拉取；切到后台后，系统也会尽量再补一次。如果本地有变化，再自动推送。")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(palette.ink3)
                                }
                            }
                            .toggleStyle(.switch)

                            Stepper(value: Binding(
                                get: { appSession.serverAutoSyncIntervalSeconds },
                                set: { appSession.setServerAutoSyncIntervalSeconds($0) }
                            ), in: 30...600, step: 30) {
                                Text("自动同步间隔 · \(appSession.serverAutoSyncIntervalSeconds) 秒")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.ink2)
                            }

                            if let target = appSession.syncSettings.serverTarget {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("冲突处理")
                                        .font(.system(size: 11.5, weight: .bold))
                                        .foregroundStyle(palette.ink)
                                    Picker(
                                        "冲突处理",
                                        selection: Binding(
                                            get: { target.conflictPolicy },
                                            set: { appSession.setServerConflictPolicy($0) }
                                        )
                                    ) {
                                        ForEach(ServerSyncConflictPolicy.allCases, id: \.self) { policy in
                                            Text(policy.shortLabel).tag(policy)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    Text(target.conflictPolicy.detail)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(palette.ink3)
                                    if let resolvedAt = target.lastConflictResolvedAt,
                                       let policy = target.lastConflictPolicy,
                                       target.lastConflictCount > 0 {
                                        Text("最近冲突 · \(target.lastConflictCount) 处，按\(policy.shortLabel)处理 · \(resolvedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(palette.ink3)
                                    }
                                }
                            }

                            let pendingChanges = appSession.autoSyncRuntime.pendingChangeCount
                            Text(
                                pendingChanges == 0
                                    ? "当前没有待同步变化"
                                    : "本地还有 \(pendingChanges) 处待同步变化"
                            )
                            .font(.system(size: 10.5))
                            .foregroundStyle(pendingChanges == 0 ? palette.ink3 : palette.accent)

                            if appSession.autoSyncRuntime.isEnabled {
                                Text(appSession.autoSyncRuntime.isRunning ? "自动同步正在运行" : "自动同步已待命")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(appSession.autoSyncRuntime.isRunning ? palette.accent : palette.ink3)
                                if let nextRetryAt = appSession.autoSyncRuntime.nextRetryAt {
                                    Text("上次没有成功；会在 \(nextRetryAt.formatted(date: .omitted, time: .shortened)) 自动重试。")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.red)
                                } else if let backgroundScheduledAt = appSession.autoSyncRuntime.backgroundScheduledAt {
                                    Text("后台唤醒已安排；系统会尽量在 \(backgroundScheduledAt.formatted(date: .omitted, time: .shortened)) 左右再补一次。")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(palette.ink3)
                                }
                                if let lastError = appSession.autoSyncRuntime.lastError {
                                    Text("最近错误 · \(lastError)")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .emptyCard(palette, radius: 12)

                    DisclosureGroup(isExpanded: $showAdvancedServer) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let target = appSession.syncSettings.serverTarget {
                                VStack(alignment: .leading, spacing: 6) {
                                    if let lastValidatedAt = target.lastValidatedAt {
                                        Text("上次联通性检查 · \(lastValidatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                    if let lastLivePullAt = target.lastLivePullAt {
                                        Text("上次增量拉取 · \(lastLivePullAt.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                    if let lastLivePushAt = target.lastLivePushAt {
                                        Text("上次增量推送 · \(lastLivePushAt.formatted(date: .abbreviated, time: .shortened))")
                                    }
                                    if let shortCursor = target.shortCursor {
                                        Text("当前 cursor · \(shortCursor)")
                                    }
                                    if let shortFingerprint = target.shortFingerprint {
                                        Text("上次指纹 · \(shortFingerprint)")
                                    }
                                }
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(palette.ink3)
                            }

                            if status.state == .contractReady {
                                Text("手动控制")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundStyle(palette.ink)
                                HStack(spacing: 8) {
                                    actionButton(isBusy ? "拉取中…" : "拉取增量") { pullFromLiveServer() }
                                        .disabled(isBusy)
                                    actionButton(isBusy ? "推送中…" : "推送当前库") { pushToLiveServer() }
                                        .disabled(isBusy)
                                    actionButton(isBusy ? "同步中…" : "双向同步") { syncLiveServer() }
                                        .disabled(isBusy)
                                    actionButton(isBusy ? "自动中…" : (appSession.autoSyncRuntime.isRetryQueued ? "立即重试" : "立即自动同步")) { runServerAutoSyncNow() }
                                        .disabled(isBusy)
                                }
                                Button(role: .destructive) {
                                    appSession.resetServerLiveCursor()
                                    statusMessage = "已清空 live sync cursor；下一次会重新完整拉取。"
                                } label: {
                                    Text("重置 live cursor")
                                        .font(.system(size: 11.5, weight: .bold))
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 10)
                    } label: {
                        Text("高级：查看详细状态 / 手动控制")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(palette.ink3)
                    }
                }

                Button(role: .destructive) {
                    appSession.clearServerTarget()
                    serverToken = ""
                    serverDisplayName = ""
                    statusMessage = "已移除 server 目标。"
                } label: {
                    Text("移除 server 目标")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var roadmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("后面还会继续简化")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            Text("接下来会继续补更完整的后台调度、冲突处理，以及后续的 Walrus / 便携导出层。对日常使用来说，你现在主要记住三件事就够了：单机就留在本机，多 Apple 设备就用 iCloud，跨平台 / 自建就填 server，再按需要登录账号并打开自动同步。")
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .emptyCard(palette, radius: 12)
        }
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(palette.ink3)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(palette.side)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(palette.line, lineWidth: 1)
                        )
                )
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    private func labeledSecureField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(palette.ink3)
            SecureField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(palette.side)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(palette.line, lineWidth: 1)
                        )
                )
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(palette.accent)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(palette.accent.opacity(0.35), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func summaryToneColor(for tone: SyncUsageTone) -> Color {
        switch tone {
        case .accent:
            palette.accent
        case .neutral:
            palette.ink
        case .caution:
            .red
        }
    }

    private func simpleServerStatusMessage(
        for status: LiveSyncProviderStatus,
        retryAt: Date?,
        backgroundScheduledAt: Date?
    ) -> String {
        switch status.state {
        case .contractReady:
            if let retryAt {
                return "这台 server 已具备同步契约。最近一次自动同步没成功，会在 \(retryAt.formatted(date: .omitted, time: .shortened)) 自动重试。"
            }
            if let backgroundScheduledAt {
                return "这台 server 已经具备同步契约。切到后台后，系统也会尽量在 \(backgroundScheduledAt.formatted(date: .omitted, time: .shortened)) 左右补一次同步。"
            }
            return "这台 server 已经具备同步契约。日常只要打开自动同步，后面基本不用再手动管。"
        case .snapshotOnly:
            return "这台 server 目前更适合作为云端备份；还没有到自动同步那一步。"
        case .setupRequired:
            return "先保存目标并测试连接；通过后，这里才会告诉你能不能开自动同步。"
        case .unavailable:
            return "最近一次探测没有成功。先点一次“测试连接”，看看是不是地址、token 或 server 本身的问题。"
        case .active, .available:
            return status.detail
        }
    }

    private func badgeBackground(for state: LiveSyncProviderState) -> Color {
        switch state {
        case .active:
            palette.accent
        case .available, .contractReady:
            palette.accentSoft
        case .setupRequired, .snapshotOnly, .unavailable:
            palette.side
        }
    }

    private func badgeForeground(for state: LiveSyncProviderState) -> Color {
        switch state {
        case .active:
            palette.window
        case .available, .contractReady:
            palette.accent
        case .setupRequired, .snapshotOnly, .unavailable:
            palette.ink3
        }
    }

    private var currentServerLiveStatus: LiveSyncProviderStatus? {
        appSession.liveSyncStatuses.first { $0.kind == .server }
    }

    private func applyLiveMode(_ mode: SyncLiveMode) {
        do {
            try appSession.setLiveMode(mode)
            statusMessage = "已切换到 \(mode.title)。"
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    private func loadServerDraft() {
        if let target = appSession.syncSettings.serverTarget {
            serverBaseURL = target.baseURLString
            serverNamespace = target.namespace
            serverDisplayName = target.accountDisplayName ?? ""
        } else {
            serverDisplayName = ""
        }
        serverToken = appSession.manualServerBearerToken
    }

    private func refreshLiveSyncStatuses() {
        runBusyTask {
            await appSession.refreshLiveSyncStatuses()
            return "已刷新 live sync provider 状态。"
        }
    }

    private func handleFolderPick(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            try appSession.rememberBackupFolder(url)
            statusMessage = "已把备份目标设为 \(appSession.syncSettings.folderTarget?.displayName ?? url.lastPathComponent)。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveServerTarget() {
        do {
            try appSession.saveServerTarget(
                baseURLString: serverBaseURL,
                namespace: serverNamespace,
                authToken: serverToken
            )
            loadServerDraft()
            statusMessage = "已保存 server 目标。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func backupToFolder() {
        guard let target = appSession.syncSettings.folderTarget else {
            errorMessage = FolderBackupProviderError.noFolderConfigured.localizedDescription
            return
        }
        runBusyTask {
            let snapshot = try SyncSnapshot.capture(from: modelContext)
            let receipt = try await FolderBackupProvider(target: target).export(snapshot: snapshot)
            appSession.markBackupCompleted(at: receipt.updatedAt ?? snapshot.exportedAt)
            return "已写入 \(receipt.locationDescription)。"
        }
    }

    private func restoreFromFolder() {
        guard let target = appSession.syncSettings.folderTarget else {
            errorMessage = FolderBackupProviderError.noFolderConfigured.localizedDescription
            return
        }
        runBusyTask {
            let snapshot = try await FolderBackupProvider(target: target).restoreLatest()
            try snapshot.merge(into: modelContext)
            return "已把文件夹快照合并回当前书库。"
        }
    }
    private func testServerConnection() {
        runBusyTask {
            let client = try makeCurrentServerSnapshotClient()
            let health = try await client.healthCheck()
            appSession.markServerValidated()
            await appSession.refreshLiveSyncStatuses()
            let service = health.service ?? "server"
            let status = health.status ?? "ok"
            return "连接通过：\(service)（\(status)）。"
        }
    }

    private func backupToServer() {
        runBusyTask {
            let snapshot = try SyncSnapshot.capture(from: modelContext)
            let client = try makeCurrentServerSnapshotClient()
            let receipt = try await client.export(snapshot: snapshot)
            appSession.markServerBackupCompleted(at: receipt.updatedAt ?? snapshot.exportedAt)
            return "已上传到 \(receipt.locationDescription)。"
        }
    }

    private func restoreFromServer() {
        runBusyTask {
            let snapshot = try await makeCurrentServerSnapshotClient().restoreLatest()
            try snapshot.merge(into: modelContext)
            return "已把 server 快照合并回当前书库。"
        }
    }

    private func makeCurrentServerSnapshotClient() throws -> ServerSnapshotClient {
        try appSession.saveServerTarget(
            baseURLString: serverBaseURL,
            namespace: serverNamespace,
            authToken: serverToken
        )
        loadServerDraft()
        return try appSession.makeServerSnapshotClient()
    }

    private func refreshCurrentServerTarget() throws {
        try appSession.saveServerTarget(
            baseURLString: serverBaseURL,
            namespace: serverNamespace,
            authToken: serverToken
        )
        loadServerDraft()
    }

    private func registerPasskeyAccount() {
        runBusyTask {
            try refreshCurrentServerTarget()
            let session = try await appSession.registerServerPasskeyAccount(
                displayName: serverDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : serverDisplayName
            )
            loadServerDraft()
            return "已创建并登录账号 \(session.displayName)。"
        }
    }

    private func signInPasskeyAccount() {
        runBusyTask {
            try refreshCurrentServerTarget()
            let session = try await appSession.signInServerPasskeyAccount()
            loadServerDraft()
            return "已登录账号 \(session.displayName)。"
        }
    }

    private func refreshPasskeyAccount() {
        runBusyTask {
            let session = try await appSession.refreshServerPasskeySession()
            loadServerDraft()
            if let session {
                return "账号状态正常：\(session.displayName)。"
            }
            return "当前没有有效的 Passkey 会话。"
        }
    }

    private func signOutPasskeyAccount() {
        runBusyTask {
            try await appSession.signOutServerPasskeyAccount()
            loadServerDraft()
            return "已退出当前 Passkey 账号。"
        }
    }

    private func pullFromLiveServer() {
        runBusyTask {
            try refreshCurrentServerTarget()
            let summary = try await appSession.performServerLivePull()
            return "已拉取 \(summary.appliedRecordCount) 条更新，删除 \(summary.tombstoneCount) 条。"
        }
    }

    private func pushToLiveServer() {
        runBusyTask {
            try refreshCurrentServerTarget()
            let summary = try await appSession.performServerLivePush()
            return "已推送 \(summary.pushedRecordCount) 条更新，删除 \(summary.tombstoneCount) 条。"
        }
    }

    private func syncLiveServer() {
        runBusyTask {
            try refreshCurrentServerTarget()
            let summary = try await appSession.performServerLiveSync()
            let conflictSuffix = summary.conflict.map { "；\($0.conflictCount) 处冲突按\($0.policy.shortLabel)处理" } ?? ""
            return "双向同步完成：pull \(summary.pull.appliedRecordCount) / push \(summary.push.changeCount)\(conflictSuffix)。"
        }
    }

    private func runServerAutoSyncNow() {
        runBusyTask {
            let message = try await appSession.runAutomaticServerSync(force: true, trigger: "manual-button")
            return message ?? "当前没有可执行的自动同步动作。"
        }
    }

    private func runBusyTask(_ operation: @escaping @MainActor () async throws -> String) {
        Task { @MainActor in
            isBusy = true
            defer { isBusy = false }
            do {
                statusMessage = try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    SyncSettingsView()
        .environmentObject(AppSession.preview)
        .modelContainer(try! AppStores.makeContainer(ephemeral: true))
}
