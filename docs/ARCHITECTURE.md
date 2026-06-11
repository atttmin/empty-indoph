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
| `Highlight` | 高亮锚点、文本快照与批注 |
| `ReadingSession` | 阅读会话起止位置 |
| `VocabEntry` | 词汇与间隔复习状态 |
| `StudyCardEntry` | 问答卡 / 链接卡 / 复习卡 |
| `MemoryItem` | ReaderMemory：高亮批注 / 链接卡 / 问答卡 / 主题记忆 |

CloudKit 同步**已启用**（`syncedDatabase = .automatic`，`Empty.entitlements` 含 iCloud capability）。容器初始化失败时（本机未登录 iCloud、关闭签名的测试环境等），自动以 `cloudKitDatabase: .none` 重建同一组磁盘 store——应用照常工作，仅不同步。

### Local Store（仅本机）

| 模型 | 用途 |
|------|------|
| `Chapter` | 章节纯文本（从 EPUB 解析） |
| `Chunk` | 分块文本 + 可选 sentence embedding |
| `ParagraphTranslation` | 双语 / 导读译文持久缓存（按稳定文本哈希键控，见 `TranslationStore`） |
| `MemoryEmbedding` | 本地 `MemoryItem` 语义向量（跨 store 仅按 `itemID` 对应） |

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
ReadingView / MacReaderScreen  # 原生 SwiftUI 渲染（块模型 + 纵向滚动）
```

### 原生渲染（无 WebView）

EPUB 章节不经 WebView：`NativeChapterParser`（`XMLParser`）把 XHTML 解析为标题 / 段落 / 引文 / 列表 / 表格 / 脚注 / 代码块 / 图片块（`NativeChapterDocument`，畸形输入回退纯文本逐段切分），由 `NativeChapterReaderView` 以 `ScrollView + LazyVStack` 渲染。每个文本块是原生 `NSTextView` / `UITextView`，段内精确划词；「跨段」面板（`NativeChapterSelectionSheet`）把整章放进单个可选文本视图覆盖跨段选取，并自动定位当前阅读位置。每个块解析出章内精确 UTF-16 范围（`NativeTextBlockSpan`）：高亮按范围绘制、选区带前后文锚定、可见段落经 SwiftUI preference 上报（驱动双语 / 导读逐段翻译），插入译文不会触发任何 reflow / 滚动跳动。

### 高亮锚定

[`HighlightStore`](../Empty/Services/HighlightStore.swift) 存精确 UTF-16 偏移 + 原文快照，定位经 `PlainTextSearch` 以选区前后文消歧；快照保证偏移漂移时高亮仍可读。高亮列表支持写 / 编辑批注与精确跳回锚点。

### 阅读位置

`ReadingPosition` 包含 `chapterIndex` 与 `utf16Offset`。阅读器滚动时上报最远可见字符，防剧透粒度为**章内字符级**；续读按存储偏移落回文本块内的精确进度。

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
| `inlineNote(for:kind:)` | 双语 / 导读逐段翻译（纯文本路径；瞬态错误经 `AITransientRetry` 退避重试） |
| `flashcards(from:maxCount:)` | 闪卡生成（高亮列表 / 伴读内可存为卡片） |
| `toolStep(toolDocs:transcript:)` | 阅读 agent 单步决策（调用工具或收尾作答） |

实现（云端 BYOK 提供**两套标准**）：

- [`FoundationModelsAIService`](../Empty/Services/FoundationModelsAIService.swift) — 本机，map-reduce 超长文本；agent 步骤用 `@Generable` guided generation
- [`CloudAIService`](../Empty/Services/CloudAIService.swift) — OpenAI 兼容 chat completions（DeepSeek 预设）；端点拒绝 JSON mode 时降级重试一次
- [`AnthropicAIService`](../Empty/Services/AnthropicAIService.swift) — Anthropic Messages API（Kimi Code 预设），复用云端 JSON 解析器

路由：[`AIProviderSettings.resolveUsableService()`](../Empty/Services/AIProviderSettings.swift)，`cloudProtocol` 切换接口标准；本机不可用时自动回退云端（若已配置 Key）。

### 阅读 Agent

[`ReadingAgent`](../Empty/Services/ReadingAgent.swift)（有界循环：本机 ≤3 步 / 云端 ≤4 步）经 `AIService.toolStep` 驱动 [`ReadingToolbox`](../Empty/Services/ReadingToolbox.swift) 的九个工具（search_passages / recap_progress / explain / find_link / recall_reader_memory / search_highlights / propose_memory / add_vocab / make_flashcards）。读操作全部走防剧透检索或 ReaderMemory 召回；写操作只产出 `CompanionAction` **提案**，读者在伴读面板 / 朱 sheet 确认后才落库；步骤轨迹随答案展示，任一步失败回退 grounded 问答。

### ReaderMemory

[`ReaderMemory`](../Empty/Services/ReaderMemory.swift) 从高亮批注、链接卡、问答卡同步出 `MemoryItem`，并支持 `propose_memory` 确认写入的 `theme` 记忆。`MemoryEmbedding` 把这些确认过的记忆写成仅本机保存的语义向量；旧问答还可在 ReaderMemory 面板里手动压缩为 `theme`，压缩后的问答不再参与 recall。`ThoughtLinkFinder` 会先走 ReaderMemory 召回，再回退到高亮语义/词法匹配；因此读者已经保存过的链接卡和主题记忆可以参与后续「活思维链接」。

### 语义索引

[`SemanticIndexer`](../Empty/Services/SemanticIndexer.swift) actor 在后台为 Chunk 写入**语言感知**的 sentence embedding（按文本主导语言选模型，中文支持，见 `SemanticScorer.embeddingModel`）；[`MemoryIndexer`](../Empty/Services/MemoryIndexer.swift) 则为 `MemoryItem` 维护平行的本地 `MemoryEmbedding`，供跨书 ReaderMemory / 思维链接复用。

### 预译缓存

[`TranslationStore`](../Empty/Services/TranslationStore.swift) 以稳定文本哈希（FNV-1a，空白归一化）为键持久化每段译文（`ParagraphTranslation`，本地 store）。双语模式下 Mac 预译当前章及后两章（含章节标题，`Chapter.pretranslatedAt` 标记），重开书零重译；☰ 目录展示每章预译状态与全书缓存量。

---

## 平台分层

```
EmptyApp
├── macOS → MacRootView
│   ├── MacLibraryScreen
│   ├── MacReaderScreen (+ MacCompanionPanel)
│   ├── MacNotesScreen
│   └── MacVocabScreen
└── iOS   → IOSRootView（书库 / 阅读 / 卡片 + 「朱」半屏伴读 sheet）
              ├── IOSLibraryScreen
              ├── ReadingView / PDFReaderView
              └── IOSCardsScreen
```

Mac 阅读器额外功能：双语对照（左右分栏 + 预译缓存）、导读、结构化章节概览、☰ 目录面板、边注、思维链接、跨段选取、TTS（[`ReadingAloud`](../Empty/Services/ReadingAloud.swift)）。

---

## 测试策略

| 层级 | 覆盖 | 工具 |
|------|------|------|
| 持久化 / 模型 | 高 | Swift Testing |
| EPUB 导入 | 中高 | 临时文件 + 夹具 |
| 分块 / 检索 / 防剧透 | 高 | Swift Testing |
| 云端 AI JSON | 高 | 纯函数解析测试 |
| 本机 Foundation Models | 低 | 硬件依赖，未纳入 CI |
| SwiftUI 视图 | UI smoke + 截图冒烟 | XCUITest 确定性播种演示书（`-ScreenshotSeed`），覆盖 reader → highlights → export 以及 README 截图 |

测试容器使用 `AppStores.makeContainer(ephemeral: true)`；CI 串行运行 `EmptyTests`，避免 SwiftData 临时 store 与 Swift Testing 并发交叉污染。

---

## 已知限制

| 项目 | 状态 |
|------|------|
| 内嵌样式非常复杂的 EPUB | 原生块模型保留结构优先；CSS 细节不做像素级复现 |
| 跨段划词 | 直接拖选限单个文本块，跨段经「跨段」整章面板完成 |
| iCloud entitlement 签名 | 个人开发账号本地跑测试需 `CODE_SIGNING_ALLOWED=NO` |
| 本机 Foundation Models 测试 | 硬件依赖，未纳入 CI；CI 通过 availability fallback 验证低部署目标可编译 |
| visionOS | target 可配置；本仓库当前无专属 UI |
| 语义 embedding | Chunk 语言感知按需索引；MemoryEmbedding 后台索引仍待做 |