# ReaderMemory 与阅读 Agent 演进方案

本文档定义 Empty「读者记忆（ReaderMemory）」的产品目标、架构、分阶段落地计划，以及第三方 Memory 技术选型结论。供实现者（含 Claude）按任务拆解执行。

相关文档：[ARCHITECTURE.md](./ARCHITECTURE.md)

---

## 1. 背景与目标

### 1.1 为什么要做 Memory + Agent

Empty 已有：

- **书内 RAG**：`ChunkRetriever` + 防剧透（`Chunk.fullyReadPredicate`）
- **思维链接**：`ThoughtLinkFinder` — 选中文本后，词法匹配跨书高亮，可选 AI 解释
- **阅读 Agent v1**：`ReadingAgent` + `ReadingToolbox`（6 个工具，写操作待确认）

这些能力分散、被动，无法支撑「越读越懂你」：

| 场景 | 今天 | 有了 ReaderMemory 之后 |
|------|------|------------------------|
| 伴读问「这和我之前读过的什么有关？」 | 只能查当前书已读 Chunk | 先召回跨书高亮/链接卡/历史 Q&A，再解释 |
| 思维链接 | UI 选中文本才触发；词法阈值粗 | 语义召回 + Agent 多步编排；伴读内可主动查 |
| 长期偏好 | 无 | 「读者关注：减法、自然、词汇 X」可检索、可同步 |
| 跨设备 | 高亮可 CloudKit；记忆语义未成体系 | 记忆元数据同步；正文仍本地 |

**Agent 不是目的，是编排层**：在防剧透边界内，串联「书内检索 → 读者记忆 → 思维链接 → 解释 → 建议存卡」。

### 1.2 设计原则（继承 ARCHITECTURE）

1. **防剧透仍是结构性的** — Memory 不得包含未读章节原文；写入时校验来源。
2. **同步读者数据，不同步书籍正文** — Memory 摘要/元数据可同步；Chunk/embedding 仍本地。
3. **记忆源以读者行为为准** — 高亮、链接卡、词汇、确认的伴读 Q&A 是 ground truth；LLM 提炼的是派生索引。
4. **写操作一律待确认** — 与 `CompanionAction` 一致；Agent 只能 `propose_memory`，不能静默改写长期记忆。
5. **不引入通用 coding agent 框架** — 保持 `ReadingAgent` 薄循环；扩展 `ReadingToolbox`。

### 1.3 非目标（本方案阶段）

- 不接 Claude Agent SDK（Python/TS，面向写代码）
- 不把书正文上传第三方 Memory 服务
- Phase 1 不做 Passkey / 账号体系（Phase 2 再作为同步壳层）

---

## 2. 目标架构

```
┌─────────────────────────────────────────────────────────────┐
│  UI：阅读器 / MacCompanionPanel / IOSCompanionSheet         │
│       思维链接 chip · 朱批 steps · 确认按钮                  │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  ReadingAgent（保持现有薄循环，maxSteps 3–4）              │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  ReadingToolbox（扩展工具）                                  │
│   已有：search_passages, recap, explain, find_link, ...     │
│   新增：recall_reader_memory, search_highlights,            │
│         propose_memory（待确认）                             │
└───────┬─────────────────────────────┬───────────────────────┘
        │                             │
        ▼                             ▼
┌───────────────┐           ┌─────────────────────────────┐
│ Chunk RAG     │           │ ReaderMemory（新建）         │
│ 书内已读段落   │           │  ingest · index · recall     │
└───────────────┘           └───────────┬─────────────────┘
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              Highlight          StudyCardEntry         VocabEntry
              （高亮快照）        （问答卡/链接卡）       （生词）
                    │                   │
                    └─────────┬─────────┘
                              ▼
                    MemoryItem（新建，Synced Store）
                    MemoryEmbedding（新建，Local Store，可选）
```

### 2.1 ReaderMemory 职责

| 职责 | 说明 |
|------|------|
| **Ingest** | 从高亮、链接卡、问答卡、词汇、（可选）伴读轮次派生 `MemoryItem` |
| **Index** | 结构化过滤 + 本地语义索引（复用 `NLEmbedding` / 现有 `SemanticScorer` 模式） |
| **Recall** | 给 Toolbox 返回 top-K 片段，带 provenance（书名、章节、类型、时间） |
| **Propose** | 生成 `CompanionAction` 建议写入/更新记忆（读者确认后落库） |

### 2.2 与思维链接的关系

`ThoughtLinkFinder` 升级为 **ReaderMemory 的子能力**，而非孤立 UI 服务：

```
ThoughtLinkFinder.findLink()
  → 内部调用 ReaderMemory.recall(.semantic, query: passage, excludeUnread: true)
  → 词法 + 语义双路打分（保留 LexicalScorer 作 fast path）
  → explainLink() 不变
```

阅读器 chip 与伴读 `find_link` / `recall_reader_memory` **共用同一召回管线**。

---

## 3. 数据模型

### 3.1 `MemoryItem`（Synced Store — 与 Highlight 同级）

```swift
enum MemoryKind: String, Codable {
    case highlightNote    // 高亮 + 读者笔记
    case thoughtLink      // 链接卡（StudyCardKind.link）
    case companionQA      // 保存的问答卡
    case theme            // 派生主题（LLM 提炼，可选手动确认）
    case vocabPattern     // 派生：常查词/主题词
}

@Model
final class MemoryItem {
    var id: UUID
    var kindRawValue: String
    var title: String              // 短标题，UI / 检索用
    var body: String               // 摘要正文（≤ 2KB），禁止未读原文
    var bookID: UUID?              // 来源书，可空（跨书主题）
    var chapterIndex: Int?
    var sourceLabel: String?       // "Walden · Ch.2"
    var tags: [String]             // 主题标签，可空
    var sourceRefID: UUID?         // Highlight.id / StudyCardEntry.id
    var sourceRefKind: String?     // "highlight" | "studyCard" | ...
    var createdAt: Date
    var updatedAt: Date
    var isUserConfirmed: Bool      // 派生记忆需 true 才参与 recall
}
```

**CloudKit 约束**：与现有模型一致，无 unique 约束；`tags` 用可序列化形式存储。

### 3.2 `MemoryEmbedding`（Local Store — 可选 Phase 1b）

与 `Chunk` 类似，仅存本地：

```swift
@Model
final class MemoryEmbedding {
    var memoryItemID: UUID
    var embedding: Data?           // Float 向量，复用 Chunk+Embedding 编解码
    var indexedAt: Date
}
```

正文不上云；换设备可对 `MemoryItem.body` 本地重建 embedding。

### 3.3 与现有模型的映射

| 来源 | 触发 ingest | MemoryKind |
|------|-------------|------------|
| `Highlight` 创建/更新 note | 自动 | `highlightNote` |
| `StudyCardEntry` kind=`.link` | 保存链接卡时 | `thoughtLink` |
| `StudyCardEntry` kind=`.qa` | 存为卡片时 | `companionQA` |
| `VocabEntry` 复习多次 | Phase 2 | `vocabPattern` |
| 伴读多轮后提炼 | Phase 2，`propose_memory` 确认后 | `theme` |

---

## 4. ReaderMemory API（实现接口）

```swift
@MainActor
struct ReaderMemory {
    let modelContext: ModelContext

    /// 从已有读者数据增量同步（幂等，按 sourceRefID 去重）
    func syncFromReaderData() throws -> Int

    /// 召回：结构化 + 语义，不返回未确认派生项
    func recall(
        query: String,
        kinds: Set<MemoryKind>? = nil,
        bookID: UUID? = nil,
        limit: Int = 8
    ) throws -> [MemoryRecall]

    /// 供 Toolbox：格式化为 observation 字符串
    func recallObservation(query: String, limit: Int = 5) throws -> String
}

struct MemoryRecall: Sendable {
    var itemID: UUID
    var kind: MemoryKind
    var title: String
    var body: String
    var sourceLabel: String?
    var score: Double
}
```

**打分**：`finalScore = 0.4 * lexical + 0.6 * semantic`（与 `ChunkRetriever` 一致）；无 embedding 时退化为词法。

---

## 5. ReadingToolbox 扩展

| 工具名 | 参数 | 行为 | traceLabel 示例 |
|--------|------|------|-----------------|
| `recall_reader_memory` | 主题/问题 | `ReaderMemory.recall` | `忆「减法」` |
| `search_highlights` | 关键词 | 只搜 `Highlight.textSnapshot` + note | `搜高亮「自然」` |
| `find_link`（升级） | 段落 | ThoughtLinkFinder + Memory 语义路 | `找关联` |
| `propose_memory` | 一句摘要 | 返回 `CompanionAction` 待确认 | `建议记住(待确认)` |

`CompanionAction.Kind` 新增：

```swift
case saveMemory(title: String, body: String, tags: [String])
```

`CompanionModel.perform()` 确认后写入 `MemoryItem(isUserConfirmed: true)`。

---

## 6. 分阶段实施

### Phase 1 — 本地 ReaderMemory（已实现）

**状态**：`MemoryItem`、`ReaderMemory.syncFromReaderData()`、`recall_reader_memory`、`search_highlights`、`propose_memory`、旧问答压缩为 `theme`、`ThoughtLinkFinder` 记忆召回路、本地 `MemoryEmbedding` 持久语义路均已落地；后续只剩自动结束时提炼主题与同步阶段。

| 任务 ID | 内容 | 验收 |
|---------|------|------|
| P1-1 | 新增 `MemoryItem` 模型 + `AppStores` 注册（Synced） | 迁移测试通过 |
| P1-2 | 实现 `ReaderMemory.syncFromReaderData()` | 导入后从高亮/链接卡/问答卡生成 item |
| P1-3 | 实现 `recall()` 词法路 | 单元测试：按 query 命中链接卡 |
| P1-4 | Toolbox 加 `recall_reader_memory`、`search_highlights` | `ReadingAgentTests` 扩展 |
| P1-5 | 升级 `ThoughtLinkFinder` 走 `ReaderMemory` | 同一 fixture 召回率 ≥ 词法基线 |
| P1-6 | UI：伴读朱批展示 memory 步骤 | 已有 steps 管道，无新屏 |

**预估改动文件**：

- 新建：`Empty/Models/MemoryItem.swift`、`Empty/Models/MemoryEmbedding.swift`、`Empty/Services/MemoryIndexer.swift`
- 修改：`AppStores.swift`、`ReaderMemory.swift`、`ReadingToolbox.swift`、`ThoughtLinkFinder.swift`、`CompanionModel.swift`
- 测试：`EmptyTests/ReaderMemoryTests.swift`

### Phase 1b — 本地语义索引（已实现基础版）

| 任务 ID | 内容 | 状态 |
|---------|------|------|
| P1b-1 | `MemoryEmbedding` 本地 store | 已实现：按 `itemID` 保存 `MemoryItem` 语义向量 |
| P1b-2 | `recall()` 语义路 | 已实现：`ReaderMemory.recall()` 优先复用持久向量；无向量时退词法 |

### Phase 2 — 派生记忆 + 确认写入（部分实现）

| 任务 ID | 内容 | 状态 |
|---------|------|------|
| P2-1 | `propose_memory` + `CompanionAction.saveMemory` | 已实现：不确认不入库，确认后写 `theme` |
| P2-2 | 伴读结束时可选提炼主题（仅 cloud / 本机 FM） | 已实现基础版：Mac / iOS 伴读可手动「提炼本轮主题」；自动结束时触发仍待做 |
| P2-3 | 记忆压缩：旧 `companionQA` 合并为 `theme` | 已实现：手动压缩入口 + 旧问答退出 recall，仅保留派生 `theme` |

### Phase 3 — 跨设备同步与账号

| 任务 ID | 内容 | 验收 |
|---------|------|------|
| P3-1 | 启用 CloudKit on Synced Store | `MemoryItem` 跨设备可见 |
| P3-2 | Passkey 或 Sign in with Apple 作为「记忆容器」账号 | 与 CloudKit 或自建 relay 二选一 |
| P3-3 | 加密导出/备份（可选） | 用户持密钥 |

### Phase 3+ — Walrus Memory 可选便携层（见 §7.5，非默认）

| 任务 ID | 内容 | 验收 |
|---------|------|------|
| P3+-1 | 自建 relay 持有 delegate key；App 只调自家 API | 私钥不进客户端 |
| P3+-2 | 仅同步 `isUserConfirmed` 的 `theme` / 链接摘要（≤2KB，无书摘全文） | ingest 审计通过 |
| P3+-3 | 设置项「导出到 Walrus 便携记忆」默认关；本地 recall 优先 | Walrus 失败不影响伴读 |

---

## 7. 第三方 Memory 技术调研

### 7.1 调研结论（一句话）

**Phase 1–2 用自研 `ReaderMemory`（SwiftData + 本地检索）作为主存储；第三方仅作可选「派生层」或云端 Claude 路径的参考实现，不替代高亮/链接卡源数据。**

### 7.2 方案对比

| 方案 | 类型 | Swift / iOS | 与 Empty 匹配度 | 主要问题 |
|------|------|-------------|-----------------|----------|
| **自研 ReaderMemory** | 应用内 SwiftData | 原生 | ★★★★★ | 需自己写 ingest/recall（可控） |
| **Mem0 Platform** | 托管 SaaS | REST；社区 [Mem0Swift](https://github.com/brightdigit/Mem0Swift) | ★★★☆☆ | 记忆主体是 chat 提炼，非高亮结构化数据；数据出境；BYOK 场景重复 |
| **Mem0 OSS** | 自托管 Python | REST API，无官方 Swift SDK | ★★☆☆☆ | 需另跑服务 + 向量库；移动端架构重 |
| **Zep / Graphiti** | 时序知识图谱 | Python，Neo4j/FalkorDB 等 | ★★★☆☆ | 擅关系与事实三元组；运维重；适合「实体关系网」产品形态 |
| **Claude Memory Tool** | API client-side tool | 需在 Swift 实现 handler | ★★★☆☆ | 仅适用于 Anthropic 云端；模型管文件式记忆，难与 Highlight 源数据一致 |
| **Claude claude.ai Memory** | 消费产品功能 | 无 API | ☆☆☆☆☆ | 无法嵌入 Empty |
| **Letta (MemGPT)** | Agent 平台 | [letta-swift](https://github.com/azamuray/letta-swift) 非官方；服务端 Docker | ★★☆☆☆ | 完整 agent 运行时，与现有 ReadingAgent 重叠 |
| **Cognee** | 知识图谱记忆 | Python | ★★☆☆☆ | 同类 GraphRAG；阅读 App 过重 |
| **Walrus Memory (MemWal)** | 可携带 agent 记忆层 | TS/Python；[MemWal](https://github.com/MystenLabs/MemWal)；无 Swift SDK | ★★☆☆☆ | Beta；需联网；结构化阅读记忆弱；默认 relayer 见明文；Sui+Walrus 栈重 |
| **Apple Foundation Models** | 本机模型 | 原生 | ★★★★☆ | 有 Tool/Session，**无**跨会话用户 Memory 产品化 API |

### 7.3 分项说明

#### Mem0

- **是什么**：从对话中自动抽取、去重、检索「用户事实」的托管/自托管记忆层。
- **优点**：add/search/update API 成熟；MCP 集成；适合「聊越多越懂你」的 chatbot。
- **缺点**：
  - 官方 SDK 仅 Python / JavaScript；iOS 需 REST 或社区 Mem0Swift。
  - Empty 的核心记忆是 **高亮快照、链接卡、阅读轨迹** — 若全走 Mem0，要做双向 ETL，且书摘原文隐私叙事变复杂。
  - 与「不同步书正文」原则冲突风险：若把段落塞进 Mem0，等同把读者库上传第三方。
- **若要用**：仅作 **Companion 派生层** — 只同步 `theme` 级摘要（读者确认后），`MemoryItem` 仍为 source of truth。

#### Zep / Graphiti

- **是什么**：时序知识图谱（实体–关系–事实），Graphiti 开源，Zep 为企业托管版。
- **优点**：跨书 **关系**（「梭罗–减法–瓦尔登湖」）表达力强；混合检索延迟低（官方标 ~150ms）。
- **缺点**：需图数据库后端；Swift 端只有 HTTP；对单人阅读 App Phase 1 过重。
- **若要用**：Phase 3+ 若产品重心变成「个人知识图谱」，可评估 Graphiti 自托管；短期不推荐。

#### Claude Memory Tool（`memory_20250818`）

- **是什么**：Anthropic Messages API 的 client-side tool；模型发 `view/create/edit` 等命令，**应用实现** `/memories` 目录读写。
- **优点**：与 Claude 云端伴读路径天然契合；可 ZDR；你控制存储（SwiftData 可实现同一协议）。
- **缺点**：
  - 无官方 Swift SDK 示例（需按 Python/TS 示例移植 handler）。
  - 本机 Foundation Models 路径不适用。
  - 记忆形态是「模型管理的文件」，与结构化 `MemoryItem` 需做映射层。
- **若要用**：作为 **AnthropicAIService 云端可选后端** — `AnthropicMemoryBackend` 读写 `MemoryItem`，而不是单独一套文件系统。

#### Letta

- **是什么**：带 core/archival/recall 内存分层的 agent 服务器。
- **缺点**：部署导向；Empty 已有 Agent loop，引入则双运行时。
- **结论**：不采用。

#### Walrus Memory（MemWal）

- **是什么**：[Walrus Memory](https://walrus.xyz/products/walrus-memory/) — Mysten/Walrus 出品的 **可携带 Agent 记忆层**（开源 [MemWal](https://github.com/MystenLabs/MemWal)）。记忆经 relayer 做 embedding → Seal 加密 → 存 [Walrus](https://walrus.xyz/) 去中心化存储；所有权与 delegate 权限由 **Sui 链上合约** 约束。文档：[What is Walrus Memory?](https://docs.wal.app/walrus-memory/getting-started/what-is-memwal)
- **核心 API**：`remember`（异步 job 写入）、`recall`（语义检索）、`analyze`（LLM 抽事实）、`ask`（召回 + 回答）。SDK：`@mysten-incubation/memwal`（TypeScript）、`memwal`（Python）；**无官方 Swift SDK**，需按 [Relayer API](https://docs.wal.app/walrus-memory/relayer/api-reference) 自实现 Ed25519 签名 HTTP 客户端。
- **优点**：
  - **跨 App / 跨 Agent 便携** — 记忆不锁死在单一 LLM 或单一应用（Claude Code、Cursor、自建 agent 可共用 namespace）。
  - **可验证 + 用户主权叙事** — 链上 owner/delegate；加密 blob 在 Walrus；支持 `restore` 从链上重建索引。
  - **与「记忆跟我走」长期愿景部分重合** — 若读者希望把「朱」提炼的主题带到其他 AI 工具，Walrus 比 Mem0 更强调 portability 与 verifiability。
- **缺点（对 Empty 致命项）**：
  - **无 Swift / iOS 一等支持** — 移动端需自写签名协议或经自建 relay 转发。
  - **必须联网** — recall/remember 依赖 relayer；与离线阅读、无网伴读冲突。
  - **记忆形态是文本 blob + 向量** — 高亮锚点、链接卡结构、防剧透章节边界需自建 ETL；非阅读域一等公民。
  - **默认信任边界** — 托管 relayer 在 remember/recall 时 **能看到明文**（见 [Trust and Security Model](https://docs.wal.app/walrus-memory/fundamentals/architecture/data-flow-security-model)）；与 Empty「本机优先、私密阅读」叙事冲突，除非自托管 relayer 或 `MemWalManual` 客户端加密。
  - **客户端不宜持钥** — `MemWal.create` 需 Ed25519 delegate private key + Sui `accountId`；**不能把 delegate key 打进 iOS App**（可提取、可滥用配额）。生产应走 **自建 relay**，与 BYOK 同类约束。
  - **不能把书摘原文同步上去** — 违反「不同步书正文」；仅适合读者确认后的摘要/主题。
  - **产品成熟度** — 文档标明 **beta、actively evolving**；依赖 Sui + Walrus + PostgreSQL(pgvector) relayer，运维与限流（如托管 relayer 账号约 1GB 存储配额）需单独评估。
  - **身份与 Passkey 不直接等价** — Walrus 用 Sui 地址 + Ed25519 delegate；WebAuthn Passkey 需额外映射层（Passkey → 你的账号 → Walrus accountId）。
- **接入路径评估**：

  | 路径 | 可行性 | 说明 |
  |------|--------|------|
  | A. iOS 直连 `relayer.memory.walrus.xyz` | ❌ 不推荐 | 私钥进 App；明文经第三方 relayer；无 Swift SDK |
  | B. 自建 relay + 只同步确认后摘要 | ⚠️ Phase 3+ | `MemoryItem` 仍为 source of truth；relay 持 delegate key |
  | C. 伴读 recall 插件（本地优先 + Walrus 增强） | ⚠️ 可选 | `ReaderMemory.recall` 先本地，登录且开启便携层再合并 Walrus 结果 |
  | D. `MemWalManual` 客户端加密 | ⚠️ 高成本 | relayer 不见明文，但 Seal/Sui 集成重，仍无 Swift 官方包 |

- **与 Mem0 / 自研对比（Walrus 差异化）**：

  | 维度 | 自研 ReaderMemory | Mem0 | Walrus Memory |
  |------|-------------------|------|---------------|
  | Swift / 离线 | 原生 / ✅ | REST / ❌ | 自写 HTTP / ❌ |
  | 结构化高亮/链接 | ✅ | ⚠️ | ⚠️ |
  | 跨 App 便携 | ❌ | ⚠️ | ✅ **核心卖点** |
  | 可验证 / 去中心化 | ❌ | ❌ | ✅ |
  | 实现复杂度 | 中 | 中 | **高** |

- **结论**：**技术上可做，不适合作为 Empty 主 Memory 层**；与 Mem0 同属「对话/摘要型」外挂，但更重、更偏 Web3 agent 基础设施。**仅建议在 Phase 3+ 作为「可选便携备份层」** — 且必须满足：只同步 `isUserConfirmed` 摘要、自建 relay、设置默认关闭、本地 recall 优先。详见 §7.5。

### 7.4 推荐选型

```
Phase 1–2（现在）     → 自研 ReaderMemory（本方案主路径）
Phase 2 云端 Claude   → 可选：Claude Memory Tool handler 读写 MemoryItem
Phase 3 跨设备        → CloudKit 同步 MemoryItem；Passkey 作账号壳
实验性/不作为主路径   → Mem0 只同步 confirmed theme 摘要；Graphiti 仅当做知识图谱产品
Phase 3+（可选）      → Walrus Memory：仅派生摘要便携副本；自建 relay；默认关闭
```

**不要让第三方成为唯一记忆源** — 否则读者导出、离线、防剧透审计都会失控。

### 7.5 Walrus Memory 与 Passkey / 云同步的关系

- **Passkey（Phase 3）** 解决的是「谁是这个读者」— 账号壳、设备授权、CloudKit 或自建后端身份。
- **Walrus Memory（Phase 3+ 可选）** 解决的是「记忆能否带到别的 Agent/App」— 与 Empty 主路径正交，不是 Passkey 的替代品。
- 推荐组合：
  1. **主同步**：CloudKit（或自建 API）同步 `MemoryItem` 元数据 — 与现有双 store 原则一致。
  2. **可选导出**：用户显式开启后，自建 relay 将 confirmed 摘要 push 到 Walrus namespace。
  3. **身份绑定**：Passkey 登录你的 relay → relay 映射到 Walrus `accountId`；不在 App 内管理 Sui 私钥。
- **伴读合并策略**（若启用路径 C）：

  ```
  recall_reader_memory(query)
    1. ReaderMemory.recall (local, 必跑)
    2. if 便携层已开启 && 网络可用 → relay.recall → 合并去重
    3. 格式化 observation 进 Agent transcript
  ```

---

## 8. 给实现者（Claude）的执行清单

按顺序 PR，每个 PR 可独立 review：

### PR-1：模型与存储

- [ ] `MemoryItem` + `MemoryKind`
- [ ] `AppStores` synced store 注册
- [ ] `ReaderMemoryTests`: 插入与 fetch

### PR-2：Ingest 管道

- [ ] `syncFromReaderData()` 从 Highlight / StudyCardEntry 幂等写入
- [ ] 在 `HighlightStore` 保存、链接卡保存处 hook（或首次 recall 前 lazy sync）

### PR-3：Recall + Toolbox

- [ ] `recall()` 词法实现
- [ ] `recall_reader_memory`、`search_highlights` 工具
- [ ] `ReadingAgentTests` 覆盖多步 recall → finish

### PR-4：思维链接统一

- [ ] `ThoughtLinkFinder` 改用 `ReaderMemory`
- [ ] 保持 UI API 不变（`MacReaderScreen` / `ReadingView`）

### PR-5：确认写入（Phase 2）

- [ ] `propose_memory` + `CompanionAction.saveMemory`
- [ ] `CompanionModel.perform()` 持久化

### PR-6（可选）：语义索引

- [ ] `MemoryEmbedding` + `SemanticIndexer` 扩展

### PR-7（可选）：Anthropic Memory Tool 适配

- [ ] 仅当 `AnthropicAIService` + 云端路由时，实现 memory tool handler → `MemoryItem`

### PR-8（可选，Phase 3+）：Walrus 便携层

- [ ] 自建 relay API（remember/recall）；delegate key 仅服务端
- [ ] 仅 export `isUserConfirmed` 且 `body.count ≤ 2048` 的 `MemoryItem`
- [ ] 设置项 + `ReaderMemory` 合并 recall；失败降级为纯本地

---

## 9. 测试策略

| 层级 | 用例 |
|------|------|
| 单元 | ingest 幂等；recall 排序；未确认 theme 不可召回 |
| 集成 | Agent：`recall_reader_memory` → `find_link` → `finish` |
| 防剧透 | ingest 拒绝含未读章节原文的 body（校验 `chapterIndex` ≤ 当前进度） |
| 隐私 | 无网络下 recall 仅本地 store |

---

## 10. 开放问题（实现前可默认）

| 问题 | 建议默认 |
|------|----------|
| 中文语义召回 | Phase 1 词法为主；Phase 1b 英文 embedding；长期可接多语 embedder |
| 记忆上限 | 单用户 5,000 `MemoryItem`；recall limit 8；body ≤ 2KB |
| 删除 | 跟 Highlight / 卡片级联删除对应 `MemoryItem` |
| Mem0 试点 | 不做，除非 Phase 2 结束仍缺「对话提炼」质量 |
| Walrus Memory | Phase 3+ 再评估；默认不做；若做则仅摘要 + 自建 relay + 用户显式开启 |

---

## 11. 成功标准

1. 伴读问「和我之前读过的什么有关」时，能引用 **其他书** 的链接卡/高亮（朱批可见 `忆「…」→ 找关联`）。
2. 思维链接语义召回优于纯词法（同一测试集 top-1 命中率提升）。
3. 派生记忆未经确认不出现在 recall 结果中。
4. 不破坏防剧透：未读书籍章节文本不出现在 Memory 与 Agent observation 中。
5. 全程可不依赖第三方 Memory 服务运行。

---

*文档版本：2026-06-11（含 Walrus Memory 调研 §7.3 / §7.5）· 与 Reading Agent v1、双 SwiftData Store 架构对齐*