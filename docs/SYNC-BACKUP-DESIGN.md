# 可插拔同步与备份实施设计

## 目标

把当前“CloudKit-ready 双 store”落成一套**可插拔**的同步 / 备份架构：

1. **保留现有原则**：同步读者数据，不同步书籍正文与本地 embedding。
2. **把 iCloud 降级为 provider**，而不是写死在 `AppStores` 里。
3. **先交付用户可用的第三方路径**：用户可选任意系统文件夹（iCloud Drive / Dropbox / OneDrive / Google Drive / SMB / NAS 等）保存快照。
4. **为后续自建 Empty Cloud / Passkey / Walrus 留接口**，并先落一个兼容 HTTPS snapshot API 的 server client 壳层。

---

## 当前代码基线

已存在：

- `Empty/Models/AppStores.swift`
  - synced store：`Book / Highlight / ReadingSession / VocabEntry / StudyCardEntry / Bookmark / MemoryItem`
  - local store：`Chapter / Chunk / ParagraphTranslation / MemoryEmbedding`
- `Empty/Models/Book.swift`
  - `fileRelativePath` 与 `coverThumbnailData` 在 synced store
- `Empty/Services/BookFileStore.swift`
  - 书文件落在 App Container，本身**不参与同步**

这意味着同步边界已经是对的；需要改的是**provider 选择、快照 schema、用户入口**。

---

## 不变式

1. **不同步正文**
   - 不同步：`Chapter` / `Chunk` / `ParagraphTranslation` / `MemoryEmbedding`
   - 只同步 / 备份：读者状态与衍生摘要
2. **跨 store 仍只靠 `Book.id`**
3. **第三方文件夹首发定义为“快照备份 / 手动恢复”**
   - 不承诺实时双向合并
   - 真实实时同步留给后续 Empty Cloud / 自建 server provider
4. **未来身份与存储解耦**
   - Passkey / Wallet 不与存储 provider 绑死

---

## 架构分层

### 1. 实时同步 provider

负责两件事：

1. **容器模式**：当前哪些 provider 真正接到 SwiftData live store
2. **协议状态**：其余 provider 是否已经具备进入 live sync 的 server 契约

当前容器 mode：

- `localOnly`
- `cloudKit`

当前协议 provider：

- `CloudKitLiveSyncProvider`
- `ServerLiveSyncProvider`

`ServerLiveSyncProvider` 现在只负责探测 `/v1/health.features` 里是否声明
`reader-live-sync-v1`；它还**不会**把 server 提升成可切换的 live mode。

### 2. 快照备份 provider

负责把 synced store 的中立快照写到外部目标。

首发 provider：

- `folder`
- `serverSnapshot`

后续 provider：

- `s3`
- `webdav`
- `walrus`


### 2.1 live delta 契约

客户端已经落成一套 provider-neutral 的 live sync 契约：

- `ReaderLiveSyncDelta`
- `LiveSyncCursor`
- `LiveSyncTombstone`
- `ReaderLiveSyncPullRequest / Response`
- `ReaderLiveSyncPushRequest / Response`

HTTP 端点预留为：

- `POST /v1/reader-live-sync/{namespace}/pull`
- `POST /v1/reader-live-sync/{namespace}/push`

这一步先定义 / 测试协议与状态探测；随后已在客户端补上一层**手动 live 协调器**，但仍不代表 Empty Cloud 已具备自动后台 live sync。
### 3. 身份 provider（后续）

- `anonymousDevice`
- `passkeyAccount`
- `zkLoginSui`
- `suiPasskeyWallet`

本阶段不接真实账号体系，只在设计上留位。

---

## 中立数据 schema

新增 `SyncSnapshot` 及 record DTO；它们是 provider-neutral 的交换层。

### 进入快照的模型

- `Book`
- `Highlight`
- `ReadingSession`
- `VocabEntry`
- `StudyCardEntry`
- `Bookmark`
- `MemoryItem`

### 不进入快照的模型

- `Chapter`
- `Chunk`
- `ParagraphTranslation`
- `MemoryEmbedding`

### `Book` 特别说明

快照保留：

- 标题 / 作者 / 语言
- `position`
- `progressFraction`
- `cachedHeroRecap`
- `coverThumbnailData`
- `fileRelativePath`

但 **不包含源 EPUB/PDF 文件本身**。恢复到另一台设备时，如果该设备没有对应导入文件，书仍可显示元数据与封面，但正文不可读；这与当前 CloudKit 语义一致。

---

## 用户流

### A. 实时同步

入口：`SyncSettingsView`

- 关闭同步（本机）
- iCloud 同步

切换时：

- 保存 `SyncSettings`
- 重建 `ModelContainer`
- 根视图用新的 container 重载

### B. 第三方文件夹备份

入口：`SyncSettingsView`

- 选择文件夹
- 立即备份
- 恢复最新备份
- 移除文件夹目标

选中的文件夹可以是 Files / File Provider 支持的任意位置：

- iCloud Drive
- Dropbox
- OneDrive
- Google Drive
- SMB / NAS
- 这仍是 **snapshot backup / restore**，不是 live sync mode
- token 留空 = 无鉴权 server
- token 非空 = `Authorization: Bearer …`
- 当 `/v1/health.features` 包含 `reader-live-sync-v1` 时，设置页会把 server 标成“契约就绪”，并开放手动 pull / push / sync；但还不会把 server 提升成自动后台 live mode
- 备份文件名固定：`empty-reader-backup.json`
- “恢复”是 **merge/upsert**，不删除本地缺失项
- 冲突策略：**用户主动恢复的快照优先**


### C. Empty Cloud / 自建 Server 快照

入口：`SyncSettingsView`

- 填 `Base URL`
- 填 `Namespace`
- 可选 `Bearer Token`
- 保存目标
- 测试连接（`GET /v1/health`）
- 上传快照（`PUT /v1/reader-snapshots/{namespace}/latest`）
- 恢复最新（`GET /v1/reader-snapshots/{namespace}/latest`）

当前语义：

- 这仍是 **snapshot backup / restore**，不是 live sync mode
- token 留空 = 无鉴权 server
- token 非空 = `Authorization: Bearer …`
- 当 `/v1/health.features` 包含 `reader-live-sync-v1` 时，设置页会把 server 标成“契约就绪”，但还不会允许切换成 live mode

### D. HTTP 契约（当前 client 期待）

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/v1/health` | 200 即视为可连通；可返回 `{ status, service, features }` |
| `PUT` | `/v1/reader-snapshots/{namespace}/latest` | 请求体为 `SyncSnapshot` JSON；header 含 `X-Empty-Device`、`X-Empty-Schema-Version` |
| `GET` | `/v1/reader-snapshots/{namespace}/latest` | 返回 `SyncSnapshot` JSON |

### E. future live sync HTTP 契约（当前 client 已实现 request/response）

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/v1/reader-live-sync/{namespace}/pull` | 请求体：`ReaderLiveSyncPullRequest`；响应：`ReaderLiveSyncPullResponse` |
| `POST` | `/v1/reader-live-sync/{namespace}/push` | 请求体：`ReaderLiveSyncPushRequest`；响应：`ReaderLiveSyncPushResponse` |

### F. 手动 live sync 协调器（已实现）

入口：`SyncSettingsView`

- 拉取增量
- 推送当前库（full-snapshot delta）
- 双向同步（先 pull 再 push）
- 重置 live cursor

当前语义：

- 本地没有 mutation journal，因此 `push` 总是发送 **full-snapshot delta**
- 删除依赖“当前 full snapshot 中缺席”来表达
- `pull` 会先 merge record，再应用 tombstone 删除
- cursor、上次 pull 时间、上次 push 时间持久化在 `SyncSettings.serverTarget`

---

## 本阶段落地文件

### 新增

- `Empty/Services/SyncSettings.swift`
  - 存储 live sync provider、folder target、server target
- `Empty/Services/AppSession.swift`
  - App 级状态：`ModelContainer`、sync settings、切换 provider、folder/server target 持久化、provider 状态探测
- `Empty/Services/SyncSnapshot.swift`
  - provider-neutral snapshot schema、capture / merge
- `Empty/Services/SyncBackupProvider.swift`
  - 快照备份 provider 抽象
- `Empty/Services/FolderBackupProvider.swift`
  - folder bookmark 解析、写入 / 读取快照
- `Empty/Services/ServerSnapshotClient.swift`
  - 兼容 Empty snapshot API 的 HTTPS client
- `Empty/Services/LiveSyncContract.swift`
  - delta / cursor / tombstone / pull-push 请求响应
- `Empty/Services/LiveSyncProvider.swift`
  - provider 状态协议
- `Empty/Services/CloudKitLiveSyncProvider.swift`
  - iCloud / CloudKit 状态探测
- `Empty/Services/ServerLiveSyncProvider.swift`
  - server live feature 探测
- `Empty/Services/ServerLiveSyncClient.swift`
  - future / manual live sync pull / push client
- `Empty/Services/ServerSyncCoordinator.swift`
  - 手动 pull / push / 双向同步协调器
- `Empty/Views/SyncSettingsView.swift`
  - 同步与备份 UI + provider 状态探测 + 手动 live sync 控件

### 修改

- `Empty/Models/AppStores.swift`
  - `makeContainer(syncMode:ephemeral:)`
- `Empty/EmptyApp.swift`
  - 由固定 `let container` 改为 app session 驱动的可重建 container
- `Empty/Views/Mac/MacRootView.swift`
  - 增加“同步与备份”入口
- `Empty/Views/IOSLibraryScreen.swift`
  - 增加“同步与备份”入口

---

## 本阶段不做的事

### Empty Cloud / 自建 server **自动后台 live sync**

原因：虽然 cursor / delta / pull-push 契约和手动协调器已经在客户端成型，但还没有：
- 本地 mutation journal
- 后台调度 / 重试
- 真实冲突合并策略 UI
- Passkey 账号与设备授权

所以本阶段已经实现：
- `server snapshot client`
- `live sync contract`
- `provider status probe`
- `manual live sync coordinator`

还**没有**把 server 提升成自动后台 live sync mode。

### Passkey / 账号体系

原因：需要 session / challenge / key envelope 设计。

### Walrus / Sui wallet

原因：

- 现成官方路径以 TS 为主
- Swift 原生 passkey wallet 成本高
- MemWal 适合作为导出 / 便携层，不适合作为首个主同步后端

---

## 后续阶段

### Phase 2 — Empty Cloud / Custom Server 自动后台 live sync

- `ServerSyncProvider`
- Passkey 登录
- 本地 mutation journal
- 后台 pull / push 调度与重试
- 冲突合并与设备 tombstone
- 对象存储放快照与 blob

### Phase 3 — Passkey + Wallet

- Passkey 先做 Empty 账号登录
- 若需要 Sui 身份，优先评估 `zkLogin`
- 真正 native Sui passkey wallet 后置

### Phase 4 — Walrus

首选定位：

- 便携 ReaderMemory 导出
- 加密备份目标

不是首个主同步通道。

---

## 验收标准

本阶段完成后：

1. 应用能在 **本机 / iCloud** 间切换实时同步模式。
2. 用户能选择任意系统文件夹作为备份目标。
3. 用户能配置兼容 Empty snapshot API 的 HTTPS server，并测试连接。
4. 设置页能探测 iCloud / Empty Cloud live sync provider 状态。
5. 客户端已具备 future live sync 的 delta / cursor / tombstone / pull-push 契约。
6. contract-ready server 已可手动执行 pull / push / 双向同步，并持久化 cursor。
7. 快照恢复不会引入正文 / chunk / embedding。
8. 现有单测与平台构建继续通过。
