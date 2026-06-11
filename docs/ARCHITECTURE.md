# 架构说明

本文档描述 Empty（空 · AI 伴读）的核心架构决策与数据流，供贡献者与未来维护参考。

**演进规划**（实现前必读）：

- [READER-MEMORY-PLAN.md](./READER-MEMORY-PLAN.md) — 读者记忆层、Agent 工具扩展、第三方 Memory 选型
- [LIBER-PORT-PLAN.md](./LIBER-PORT-PLAN.md) — 从 Liber Web 借鉴的能力（活思维链接、镜片、卡片 fork 等）

---

## 设计原则

1. **防剧透是结构性的** — 未读文本在检索层被过滤（`Chunk.fullyReadPredicate`），AI 无法访问未来章节。
2. **同步读者数据，不同步书籍正文** — 高亮、进度、词汇可同步；章节文本与 embedding 仅存本地。
3. **AI 提供商可替换** — `AIService` 协议隔离 Foundation Models 与云端 BYOK，视图层无感知。
4. **衍生数据可重建** — `Chapter` 与 `Chunk` 可从导入的 EPUB 文件重新索引。

---

## 持久化：双 SwiftData Store

定义于 [`Empty/Models/AppStores.swift`](../Empty/Models/AppStores.swift)。

### Synced Store（CloudKit-ready）

| 模型 | 用途 |
|------|------|
| `Book` | 书库元数据、封面、阅读位置 |
| `Highlight` | 高亮锚点与文本快照 |
| `ReadingSession` | 阅读会话起止位置 |
| `VocabEntry` | 词汇与间隔复习状态 |

当前 `syncedDatabase = .none`。启用 CloudKit 步骤：

1. Xcode → Signing & Capabilities → **+ iCloud** → 勾选 CloudKit
2. 将 `AppStores.swift` 中 `syncedDatabase` 改为 `.automatic`
3. 确保模型符合 CloudKit 约束（已遵循：无 unique 约束、关系 optional）

### Local Store（仅本机）

| 模型 | 用途 |
|------|------|
| `Chapter` | 章节纯文本（从 EPUB 解析） |
| `Chunk` | 分块文本 + 可选 sentence embedding |

跨 store 关联：**仅通过 `Book.id`（UUID）**，不使用 SwiftData 跨 store relationship。

---

## 阅读管线

```
EPUB 文件
    │
    ▼
BookFileStore.copyImport()     # 复制到 App Container
    │
    ▼
EPUBParser.parse()             # 解压、读 OPF、提取章节 HTML → 纯文本
    │
    ▼
Library.import()               # 写入 Book + Chapter（双 store）
    │
    ▼
BookIndexer.ensureChunks()     # 按需分块，写入 Chunk
    │
    ▼
ReadingView / MacReaderScreen  # WebKit 渲染 + 分页 + 高亮桥接
```

### 高亮锚定

[`HighlightStore`](../Empty/Services/HighlightStore.swift) 使用 UTF-16 偏移 + 选区前后各 32 字符的 prefix/suffix 快照，在章节重解析后仍能定位高亮。

### 阅读位置

`ReadingPosition` 包含 `chapterIndex` 与 `utf16Offset`。  
**当前限制：** UI 层 `saveProgress()` 仅更新章节索引，`utf16Offset` 固定为 0，防剧透粒度实际为章级。

---

## AI 管线

### 分块与索引

- [`TextChunker`](../Empty/Services/TextChunker.swift) — 按字符预算切分，保留 UTF-16 锚点
- [`BookIndexer`](../Empty/Services/BookIndexer.swift) — 幂等建索引，ordinal 为全书阅读顺序

### 防剧透检索

[`ChunkRetriever`](../Empty/Services/ChunkRetriever.swift)：

1. 用 `Chunk.fullyReadPredicate(bookID:position:)` 取候选
2. 词法打分（`LexicalScorer`）+ 可选语义打分（`SemanticScorer` / `NLEmbedding`）
3. 无词法匹配时，回退到最近已读块（保证「总结一下」类问题仍有上下文）

### AI 服务

[`AIService`](../Empty/Services/AIService.swift) 协议：

| 方法 | 用途 |
|------|------|
| `summarize(_:focus:)` | 摘要 / Recap / 论证骨架 |
| `answer(question:groundedIn:)` | 基于已检索段落的 grounded 回答 |
| `flashcards(from:maxCount:)` | 闪卡生成（服务已实现，UI 待接） |

实现：

- [`FoundationModelsAIService`](../Empty/Services/FoundationModelsAIService.swift) — 本机，map-reduce 超长文本
- [`CloudAIService`](../Empty/Services/CloudAIService.swift) — OpenAI 兼容 chat completions

路由：[`AIProviderSettings.resolveUsableService()`](../Empty/Services/AIProviderSettings.swift)  
本机不可用时自动回退云端（若已配置 Key）。

### 语义索引

[`SemanticIndexer`](../Empty/Services/SemanticIndexer.swift) actor 在后台为 Chunk 写入 embedding。  
依赖 `NLEmbedding.sentenceEmbedding(for: .english)`，目前以英文为主，由 `AskBookView` 触发。

---

## 平台分层

```
EmptyApp
├── macOS → MacRootView
│   ├── MacLibraryScreen
│   ├── MacReaderScreen (+ MacCompanionPanel)
│   ├── MacNotesScreen
│   └── MacVocabScreen
└── iOS   → LibraryView → ReadingView
              ├── RecapView
              ├── AskBookView
              └── HighlightsListView
```

Mac 阅读器额外功能：双语模式、边注、思维链接、TTS（[`ReadingAloud`](../Empty/Services/ReadingAloud.swift)）。

---

## 测试策略

| 层级 | 覆盖 | 工具 |
|------|------|------|
| 持久化 / 模型 | 高 | Swift Testing |
| EPUB 导入 | 中高 | 临时文件 + 夹具 |
| 分块 / 检索 / 防剧透 | 高 | Swift Testing |
| 云端 AI JSON | 高 | 纯函数解析测试 |
| 本机 Foundation Models | 低 | 硬件依赖，未纳入 CI |
| SwiftUI 视图 | 极低 | UITests 为模板 |

测试容器使用 `AppStores.makeContainer(ephemeral: true)` 隔离并行测试。

---

## 已知限制

| 项目 | 状态 |
|------|------|
| PDF 阅读 | 未实现 |
| 章内 utf16Offset | 模型支持，UI 未上报 |
| CloudKit | 已预留，未启用 |
| 闪卡 UI | 服务有，界面无 |
| iOS 词汇/笔记 | Mac 独有 |
| Mac 笔记屏 AI 建议 | 部分为静态文案 |
| 语义 embedding | 英文 NLEmbedding，非全局后台索引 |