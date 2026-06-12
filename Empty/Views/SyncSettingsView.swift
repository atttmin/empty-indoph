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
    @State private var serverBaseURL = ""
    @State private var serverNamespace = "default"
    @State private var serverToken = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.line).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("provider 状态")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1.4)
                    .foregroundStyle(palette.ink3)
                Spacer()
                actionButton(appSession.isRefreshingLiveSyncStatuses ? "探测中…" : "刷新状态") {
                    refreshLiveSyncStatuses()
                }
                .disabled(isBusy || appSession.isRefreshingLiveSyncStatuses)
            }

            if appSession.liveSyncStatuses.isEmpty, appSession.isRefreshingLiveSyncStatuses {
                Text("正在探测 iCloud 与 Empty Cloud live sync 能力…")
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

            Text("Empty Cloud 真正进入 live mode 前，server 需要在 `/v1/health` 的 `features` 里声明 `reader-live-sync-v1`，并实现 pull / push 两个 delta 端点。")
                .font(.system(size: 10.5))
                .foregroundStyle(palette.ink3)
        }
    }

    private var folderBackupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("第三方云 / 文件夹")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            VStack(alignment: .leading, spacing: 10) {
                Text("选择任意 Files / File Provider 文件夹：iCloud Drive、Dropbox、OneDrive、Google Drive、SMB 或 NAS 都可以。")
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
                Text("文件夹路径当前是“可恢复快照”，不是实时双向合并。恢复时以你主动选择的快照为准，做 merge / upsert，不删除本机额外数据。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
            }
        }
    }

    private var serverBackupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Empty Cloud / 自建 Server")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            VStack(alignment: .leading, spacing: 10) {
                Text("这一层先走 snapshot API：你可以把读者快照推到兼容的 HTTPS 服务，再从同一 namespace 拉回。只有当 server 额外声明 `reader-live-sync-v1` 时，才值得进一步切成真正的 live sync mode。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink2)
                VStack(alignment: .leading, spacing: 8) {
                    labeledField("Base URL", placeholder: "https://sync.example.com", text: $serverBaseURL)
                    labeledField("Namespace", placeholder: "default", text: $serverNamespace)
                    labeledSecureField("Bearer Token（可留空）", placeholder: "token-…", text: $serverToken)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .emptyCard(palette, radius: 12)

                if let target = appSession.syncSettings.serverTarget {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("已保存目标 · \(target.displayName) / \(target.namespace)")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(palette.ink)
                        Text("鉴权 · \(target.authMode.title)")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.ink3)
                        if let lastValidatedAt = target.lastValidatedAt {
                            Text("上次联通性检查 · \(lastValidatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                        if let lastSnapshotAt = target.lastSnapshotAt {
                            Text("上次 server 备份 · \(lastSnapshotAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                        if let lastLivePullAt = target.lastLivePullAt {
                            Text("上次增量拉取 · \(lastLivePullAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                        if let lastLivePushAt = target.lastLivePushAt {
                            Text("上次增量推送 · \(lastLivePushAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                        if let lastAutoSyncAt = target.lastAutoSyncAt {
                            Text("上次自动同步 · \(lastAutoSyncAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                        if let shortCursor = target.shortCursor {
                            Text("当前 cursor · \(shortCursor)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(palette.ink3)
                        }
                        if let shortFingerprint = target.shortFingerprint {
                            Text("上次指纹 · \(shortFingerprint)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(palette.ink3)
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
                    actionButton(isBusy ? "上传中…" : "上传快照") { backupToServer() }
                        .disabled(isBusy)
                    actionButton(isBusy ? "恢复中…" : "恢复最新") { confirmServerRestore = true }
                        .disabled(isBusy)
                }

                if let status = currentServerLiveStatus {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text("live 协调器")
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(palette.ink)
                            Text(status.state.badgeTitle)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(badgeForeground(for: status.state))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(badgeBackground(for: status.state), in: Capsule())
                        }
                        Text("当前 coordinator 会把 synced store 捕获成 full-snapshot delta，再走 pull / push 契约；在没有本地 mutation journal 前，删除靠 full snapshot 缺席来表达。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.ink2)
                        if status.state == .contractReady {
                            Toggle(isOn: Binding(
                                get: { appSession.serverAutoSyncEnabled },
                                set: { appSession.setServerAutoSyncEnabled($0) }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("自动同步")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(palette.ink)
                                    Text("仅在前台运行；每 \(appSession.serverAutoSyncIntervalSeconds) 秒自动拉取并按需推送 full-snapshot delta。")
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

                            if appSession.autoSyncRuntime.isEnabled {
                                Text(appSession.autoSyncRuntime.isRunning
                                     ? "自动同步正在运行 · \(appSession.autoSyncRuntime.lastTrigger ?? "…")"
                                     : "自动同步已待命")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(appSession.autoSyncRuntime.isRunning ? palette.accent : palette.ink3)
                                if let lastError = appSession.autoSyncRuntime.lastError {
                                    Text("最近错误 · \(lastError)")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.red)
                                }
                            }

                            HStack(spacing: 8) {
                                actionButton(isBusy ? "拉取中…" : "拉取增量") { pullFromLiveServer() }
                                    .disabled(isBusy)
                                actionButton(isBusy ? "推送中…" : "推送当前库") { pushToLiveServer() }
                                    .disabled(isBusy)
                                actionButton(isBusy ? "同步中…" : "双向同步") { syncLiveServer() }
                                    .disabled(isBusy)
                                actionButton(isBusy ? "自动中…" : "立即自动同步") { runServerAutoSyncNow() }
                                    .disabled(isBusy)
                            }
                            Button(role: .destructive) {
                                appSession.resetServerLiveCursor()
                                statusMessage = "已清空 live sync cursor；下一次可改走 full pull。"
                            } label: {
                                Text("重置 live cursor")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text("只有当 server 在 `/v1/health.features` 声明 `reader-live-sync-v1` 时，才会开放 pull / push / 双向同步。")
                                .font(.system(size: 10.5))
                                .foregroundStyle(palette.ink3)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .emptyCard(palette, radius: 12)
                }

                Button(role: .destructive) {
                    appSession.clearServerTarget()
                    serverToken = ""
                    statusMessage = "已移除 server 目标。"
                } label: {
                    Text("移除 server 目标")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                Text("snapshot 协议固定为 `GET /v1/health` 与 `PUT/GET /v1/reader-snapshots/{namespace}/latest`。future live sync 协议会额外使用 `POST /v1/reader-live-sync/{namespace}/pull|push`；当前 coordinator 已可手动跑这两条路。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.ink3)
            }
        }
    }

    private var roadmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("后续 provider")
                .font(.system(size: 12, weight: .bold))
                .kerning(1.4)
                .foregroundStyle(palette.ink3)
            Text("下一步会在同一套 delta 契约上接真正的 Empty Cloud live sync coordinator；Passkey 先做账号登录与密钥封装层，Walrus 仍保持可选导出 / 备份，不把钱包与存储绑死。")
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
        }
        serverToken = appSession.serverAuthToken
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

    private func makeCurrentServerSyncCoordinator() throws -> ServerSyncCoordinator {
        try appSession.saveServerTarget(
            baseURLString: serverBaseURL,
            namespace: serverNamespace,
            authToken: serverToken
        )
        loadServerDraft()
        return try appSession.makeServerSyncCoordinator()
    }

    private func pullFromLiveServer() {
        runBusyTask {
            let summary = try await makeCurrentServerSyncCoordinator().pull(
                into: modelContext,
                cursor: appSession.serverLiveCursor
            )
            appSession.markServerLivePullCompleted(cursor: summary.cursor, at: summary.pulledAt)
            return "已拉取 \(summary.appliedRecordCount) 条记录，tombstone \(summary.tombstoneCount) 条。"
        }
    }

    private func pushToLiveServer() {
        runBusyTask {
            let summary = try await makeCurrentServerSyncCoordinator().push(
                from: modelContext,
                baseCursor: appSession.serverLiveCursor
            )
            appSession.markServerLivePushCompleted(cursor: summary.cursor, at: summary.pushedAt)
            return "已推送 \(summary.pushedRecordCount) 条记录。"
        }
    }

    private func syncLiveServer() {
        runBusyTask {
            let summary = try await makeCurrentServerSyncCoordinator().sync(
                into: modelContext,
                cursor: appSession.serverLiveCursor
            )
            appSession.markServerLivePullCompleted(cursor: summary.pull.cursor, at: summary.pull.pulledAt)
            appSession.markServerLivePushCompleted(cursor: summary.push.cursor ?? summary.pull.cursor, at: summary.push.pushedAt)
            return "双向同步完成：pull \(summary.pull.appliedRecordCount) / push \(summary.push.pushedRecordCount)。"
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
