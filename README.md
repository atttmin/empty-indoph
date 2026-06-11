# 空 · Empty

[![CI](https://github.com/DaviRain-Su/empty/actions/workflows/ci.yml/badge.svg)](https://github.com/DaviRain-Su/empty/actions/workflows/ci.yml)

**AI 伴读 · 深读工作台**

多平台 SwiftUI 阅读应用：在**不剧透**的前提下，用 AI 帮你摘要、问书、记笔记、复习词汇。  
Mac 是完整的「深读工作台」；iOS / iPad 提供轻量阅读与 AI 辅助。

> *空是底，朱是点 —— 应用是空房间，AI 是页边那一笔朱批。*

---

## 特性

### 阅读

- **EPUB 导入与阅读** — 自定义 ZIP 解析、WebKit 分栏分页、暗色模式、字体与行距调节
- **高亮** — UTF-16 锚定 + 前后缀消歧，支持列表查看与跳转
- **阅读进度** — 章节级进度与会话记录（章内字符偏移待完善）

### 防剧透 AI

所有 AI 功能只基于**你已经读过的文本**，在数据层过滤未读内容，而非仅靠 prompt 约束：

- **章节摘要 / Recap** — 「Previously on…」式回顾
- **问书** — 检索已读段落 + grounded 回答（带引用）
- **词汇释义** — 选中查词，接入间隔复习
- **思维链接**（Mac）— 跨书高亮的主题关联发现
- **伴读面板**（Mac）— 基于已读内容的对话式辅助

### 学习工具（Mac）

- **笔记屏** — 高亮卡片与知识图谱视图
- **词汇屏** — Ebbinghaus 间隔复习（1 → 2 → 4 → 7 → 15 → 30 天）
- **朗读**（macOS TTS）

### AI 提供商

| 模式 | 说明 |
|------|------|
| **On-Device**（默认） | Apple Foundation Models，本地、免费、私密 |
| **Cloud（BYOK）** | OpenAI 兼容 API，内置 DeepSeek 预设，密钥存 Keychain |

在 **书库 → AI 诊断**（`AIDiagnosticsView`）中切换提供商并做连通性测试。

---

## 平台支持

| 平台 | 体验 |
|------|------|
| **macOS** | 完整四屏工作台：书库 / 阅读 / 笔记 / 词汇 |
| **iOS / iPadOS** | 书库 → 阅读器 + Recap / 问书 / 高亮 |
| **visionOS** | 可编译，暂无专属 UI |

**系统要求：** Xcode 26+，部署目标 iOS / macOS **26.2**（本地开发）  
**CI：** GitHub Actions 在 `macos-latest` 上以 macOS 15 / iOS 18 部署目标运行单元测试  
**Bundle ID：** `davirian.Empty`

---

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/DaviRain-Su/empty.git
cd Empty
```

### 2. 用 Xcode 打开

```bash
open Empty.xcodeproj
```

选择目标平台（My Mac / iPhone Simulator），`Cmd + R` 运行。

### 3. 导入书籍

点击 **导入**，选择 `.epub` 文件。PDF 可导入元数据，但阅读器尚未实现（会提示仅支持 EPUB）。

### 4. 配置 AI（可选）

1. 打开 **AI 诊断** 面板
2. 默认使用本机 Apple Intelligence；若不可用，可切换到 Cloud 并填入 API Key
3. 运行一次 Summarize 测试确认管线正常

---

## 运行测试

```bash
# macOS 单元测试
xcodebuild -scheme Empty -destination 'platform=macOS' test

# 仅跑 EmptyTests（跳过 UI 测试）
xcodebuild -scheme Empty -destination 'platform=macOS' \
  -only-testing:EmptyTests test
```

当前约 **78/79** 单元测试通过；`SemanticScorerTests.testRetrieverFallsBackToLexical` 与 retriever 行为存在已知不一致，待修复。

---

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI Views                                          │
│  MacRootView / LibraryView / ReadingView / AskBookView  │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  Services                                             │
│  Library · BookIndexer · ChunkRetriever · AIService   │
└────────────┬───────────────────────┬──────────────────┘
             │                       │
   ┌─────────▼─────────┐   ┌─────────▼─────────┐
   │  Synced Store     │   │  Local Store      │
   │  (CloudKit-ready) │   │  (device-only)    │
   │  Book, Highlight  │   │  Chapter, Chunk   │
   │  Session, Vocab   │   │  + embeddings     │
   └───────────────────┘   └───────────────────┘
```

核心设计原则：**同步读者的数据，不同步书籍正文。**  
跨 store 仅通过 `Book.id` 关联。详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

---

## 项目结构

```
Empty/
├── Empty/                 # 主应用
│   ├── Models/            # SwiftData 模型
│   ├── Services/          # 业务逻辑与 AI 管线
│   ├── Views/             # SwiftUI 视图
│   │   └── Mac/           # macOS 深读工作台
│   └── DesignSystem/      # 朱批设计系统
├── EmptyTests/            # 单元测试（Swift Testing + XCTest）
├── EmptyUITests/          # UI 测试（模板级）
└── docs/                  # 架构与开发文档
```

---

## 推送到 GitHub

本地已完成初始提交后，在 GitHub 新建空仓库（不要勾选 README / .gitignore，避免冲突），然后：

```bash
git remote add origin https://github.com/DaviRain-Su/empty.git
git branch -M main
git push -u origin main
```

若使用 SSH：

```bash
git remote add origin git@github.com:DaviRain-Su/empty.git
git push -u origin main
```

**推送前建议检查：**

- `.gitignore` 已排除 `xcuserdata/`、`DerivedData/` 等本地文件
- 不要在仓库中提交 API Key（密钥通过 Keychain 存储）
- 若启用 CloudKit，需在 Xcode 中添加 iCloud capability 并配置 entitlements

---

## 路线图

- [ ] 章内阅读位置（`utf16Offset`）上报，实现精细防剧透
- [ ] 闪卡 UI（`AIService.flashcards` 已实现，缺界面）
- [ ] iOS 词汇 / 笔记功能对齐
- [ ] CloudKit 同步启用
- [ ] PDF 阅读支持
- [ ] 修复语义检索回归测试

完整变更记录见 [CHANGELOG.md](CHANGELOG.md)。

---

## 许可证

[MIT License](LICENSE) — Copyright © 2026 davirian

---

## 致谢

设计系统「朱批 Vermilion」来自 Empty. 空 产品原型。  
AI 层抽象参考 Apple Foundation Models 与 OpenAI 兼容 API 的最佳实践。