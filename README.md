# Empty · 空 — AI Reading Companion for Deep Readers

[![CI](https://github.com/DaviRain-Su/empty/actions/workflows/ci.yml/badge.svg)](https://github.com/DaviRain-Su/empty/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20iOS%20%7C%20iPadOS%20%7C%20visionOS-999999?logo=apple)](https://github.com/DaviRain-Su/empty)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![Xcode](https://img.shields.io/badge/Xcode-26%2B-blue?logo=xcode)](https://developer.apple.com/xcode/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Website](https://img.shields.io/badge/website-empty--78c.pages.dev-8A2BE2)](https://empty-78c.pages.dev)

> **An open-source, native SwiftUI EPUB & PDF reader with a spoiler-free AI companion.**  
> Mac is your deep-reading workspace; iPhone / iPad is your pocket companion. Your books, your notes, your vocabulary, and your cross-book memory stay local-first and private by default.

<p align="center">
  <a href="https://empty-78c.pages.dev">Website</a> ·
  <a href="#download">Download</a> ·
  <a href="#features">Features</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#roadmap">Roadmap</a>
</p>

---

## 🎯 Why Empty?

Most AI reading tools summarize the *whole* book and accidentally spoil the ending. **Empty only uses what you have already read.** Every AI feature — recap, explanation, translation, vocabulary, flashcards, and thought links — is filtered at the data layer, not just guarded by a prompt.

Built for readers who want to:

- **Read deeply** with an AI that respects plot boundaries.
- **Own their data**: books, highlights, notes, vocabulary, and memory stay on-device by default.
- **Learn actively** with built-in spaced-repetition vocabulary, flashcards, and cross-book theme discovery.
- **Go offline** with local Apple Intelligence and optional BYOK cloud AI (OpenAI-compatible / Anthropic-compatible).

---

## 🖼 Screenshots

All screenshots are real app UI, not mock-ups. See [`docs/screenshots/README.md`](docs/screenshots/README.md) for regeneration notes.

| macOS Library | macOS Reader | iOS Library | iOS Reader |
|---|---|---|---|
| ![macOS library](docs/screenshots/mac-library.png) | ![macOS reader](docs/screenshots/mac-reader.png) | ![iOS library](docs/screenshots/ios-library.png) | ![iOS reading](docs/screenshots/ios-reading.png) |
| Deep-reading workspace with continue-reading cards, bookshelves, and import. | Bilingual side-by-side reading, AI chapter overview, and native EPUB rendering. | Pocket library tab with continue-reading and import. | Reading tab with chapter progress, translation, tts, and the “Zhu” AI companion button. |

---

## ✨ Features

### 📖 Reading Engine

- **Native EPUB & PDF support** — EPUB is rendered with a native SwiftUI block model (headings, paragraphs, quotes, lists, tables, footnotes, images) **without a WebView**. PDF uses PDFKit.
- **Precise highlights & notes** — UTF-16 anchored with context disambiguation; tap a highlight to jump back to the exact source location.
- **Word-accurate selection & cross-paragraph selection** — native in-paragraph selection plus a full-chapter selection sheet.
- **Character-level reading progress** — `utf16Offset` progress and session tracking; resume inside a paragraph.
- **Dark mode, typography, and line-spacing controls**.

### 🤖 Spoiler-Free AI Companion (朱)

Every AI feature is limited to text you have already read:

- **Chapter Recap** — “Previously on…” recap with a structured chapter overview and a “← you are here” marker.
- **Inline Translation / Guide / Debate / References** (EPUB) — Mac uses side-by-side bilingual panels; iOS uses paragraph lenses. Pre-translated and cached so the original text renders first and never blocks.
- **Zhu Reading Agent** — A conversational companion that schedules reading tools (search read text, recap, explain, find links, suggest vocabulary, draft flashcards). All writes are confirm-gated; failures fall back to grounded Q&A.
- **Vocabulary lookup** — One-tap word lookup with spaced-repetition scheduling.
- **Thought Links** — Discover thematic echoes across your highlights and save them as link cards.
- **Library “Continue Reading”** — Spoiler-free recap + estimated remaining read time.

### 🧠 Learning Tools (Mac)

- **Notes screen** — Highlight cards + Q&A / link / review cards with in-card spaced repetition and an expandable knowledge graph.
- **Vocabulary screen** — Ebbinghaus ladder (1 → 2 → 4 → 7 → 15 → 30 days), cloze example sentences, and next-queue preview.
- **Text-to-Speech** on macOS.

### 🔒 AI Providers

| Mode | Details |
|------|---------|
| **On-Device (default)** | Apple Foundation Models — local, free, private. |
| **Cloud (BYOK)** | OpenAI-compatible (DeepSeek preset) or Anthropic-compatible (Kimi Code preset); keys stored in Keychain. |

Choose the provider and run a connectivity test in the **AI Diagnostics** panel (`AIDiagnosticsView`).

---

## ⬇️ Download

The latest macOS build is produced by GitHub Actions and attached as an artifact:

[![CI Artifact](https://img.shields.io/badge/CI%20Artifact-Empty%20macOS-blue?logo=github)](https://github.com/DaviRain-Su/empty/actions/workflows/ci.yml)

> The artifact is an **unsigned** `.dmg`. macOS Gatekeeper will warn on first open — right-click the app and choose **Open**, or allow it in **System Settings → Privacy & Security**.

For a signed / notarized release suitable for wider distribution, add an Apple Developer ID certificate and notarization credentials to the CI workflow.

You can also build from source (see [Quick Start](#quick-start)).

---

## 🚀 Quick Start

```bash
git clone https://github.com/DaviRain-Su/empty.git
cd Empty
open Empty.xcodeproj
```

1. Select a destination (My Mac / iPhone Simulator).
2. Press `Cmd + R` to run.
3. Tap **Import** and choose an `.epub` or `.pdf` file.
4. Open the **AI Diagnostics** panel to verify on-device AI or connect your own API key.

### Run tests

```bash
xcodebuild test -project Empty.xcodeproj -scheme Empty \
  -destination 'platform=macOS' \
  -parallel-testing-enabled NO \
  -only-testing:EmptyTests \
  -skip-testing:EmptyUITests \
  CODE_SIGNING_ALLOWED=NO \
  MACOSX_DEPLOYMENT_TARGET=15.0 \
  IPHONEOS_DEPLOYMENT_TARGET=18.0
```

For local unsigned debug builds you can also add:

```bash
CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

All **237** unit tests pass on CI and locally.

---

## 💻 Platform Support

| Platform | Experience |
|----------|------------|
| **macOS** | Full four-pane workspace: Library / Reader / Notes / Vocabulary. |
| **iOS / iPadOS** | Pocket companion: Library / Reader / Cards + Zhu AI sheet, paragraph translation, thought links, and vocabulary review. |
| **visionOS** | Compiles; no dedicated UI yet. |

**Requirements:** Xcode 26+. Default deployment target is iOS / macOS 26.2; CI falls back to iOS 18 / macOS 15 for availability testing.

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI Views                                          │
│  MacRootView / IOSRootView / ReadingView / Companion    │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  Services                                               │
│  Library · BookIndexer · ChunkRetriever · AIService     │
└────────────┬───────────────────────┬────────────────────┘
             │                       │
   ┌─────────▼─────────┐   ┌─────────▼─────────┐
   │  Reader Data      │   │  Local Derived    │
   │  (device-only)    │   │  (device-only)    │
   │  Book, Highlight  │   │  Chapter, Chunk   │
   │  Session, Vocab   │   │  translations     │
   │  Cards, Memory    │   │  + embeddings     │
   │  Bookmark         │   │                   │
```

Core principle: **do local deep-reading first; backups only touch reader notes, never book content.**

- Library metadata, reading progress, highlights, notes, vocabulary, cards, and ReaderMemory stay on-device.
- EPUB/PDF files, chapter text, translation cache, embeddings, and API keys remain local.
- Reader notes can be exported/imported as an `.empty-notes` package (highlights, notes, vocabulary, cards, memory, and book metadata). Book content is not included.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and [`docs/SYNC-BACKUP-DESIGN.md`](docs/SYNC-BACKUP-DESIGN.md) for more.

---

## 📁 Project Structure

```
Empty/
├── Empty/                 # Main app
│   ├── Models/            # SwiftData models
│   ├── Services/          # Business logic & AI pipeline
│   ├── Views/             # SwiftUI views
│   │   └── Mac/           # macOS deep-reading workspace
│   └── DesignSystem/      # Vermilion (朱批) design system
├── EmptyTests/            # Unit tests (Swift Testing + XCTest)
├── EmptyUITests/          # UI smoke + screenshot tests
├── docs/                  # Architecture & dev docs
│   └── screenshots/       # README & website assets
├── website/               # Static landing page (Cloudflare Pages)
└── scripts/               # Build & packaging scripts
```

---

## 🗺 Roadmap

Highlights of what already works:

- [x] Character-level reading position (`utf16Offset`) for spoiler-safe AI.
- [x] Language-aware semantic embeddings for Chinese and English.
- [x] Flashcard UI with highlight-to-card and spaced repetition.
- [x] iOS vocabulary / notes / study tabs.
- [x] PDF reading, pagination, and highlight annotations.
- [x] Bilingual side-by-side / inline guide panels.
- [x] Structured chapter overview + save-as-card + knowledge graph.
- [x] Library hero AI “continue reading” + estimated remaining time.
- [x] iOS pocket companion with Zhu AI, paragraph translation, thought links.
- [x] Pre-translation cache with visualization.
- [x] Reading Agent v1 with tool loop, trace, and confirm-gated writes.
- [x] Kimi Code (Anthropic-compatible) cloud path.
- [x] Native SwiftUI EPUB renderer with precise selection and highlights.
- [x] ReaderMemory Phase 1/2 + 1b: cross-book ingest/recall, propose_memory, local embeddings, Q&A compression into themes.
- [x] Living thought links: link cards / theme memory feed ThoughtLinkFinder.
- [x] `.empty-notes` reader-note package export / import.

See [CHANGELOG.md](CHANGELOG.md), [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/READER-MEMORY-PLAN.md](docs/READER-MEMORY-PLAN.md), and [docs/LIBER-PORT-PLAN.md](docs/LIBER-PORT-PLAN.md) for full details.

---

## 🤝 Contributing & Community

If Empty helps you read more deeply, please consider **giving it a ⭐️** — it makes the project easier for others to discover.

- Found a bug? Open an [issue](https://github.com/DaviRain-Su/empty/issues).
- Have an idea? Start a [discussion](https://github.com/DaviRain-Su/empty/discussions).
- Want to contribute? Look for issues labeled `good first issue`.

---

## 📄 License

[MIT License](LICENSE) — Copyright © 2026 davirian

---

## 🙏 Acknowledgements

- Design system **Vermilion (朱批)** from the Empty product prototype.
- AI abstraction inspired by Apple Foundation Models and OpenAI-compatible API best practices.

---

# 空 · Empty — 中文介绍

**AI 伴读 · 深读工作台**

多平台 SwiftUI 阅读应用：在**不剧透**的前提下，用 AI 帮你摘要、问书、记笔记、复习词汇。Mac 是完整的「深读工作台」；iOS / iPad 提供轻量阅读与 AI 辅助。

> *空是底，朱是点 —— 应用是空房间，AI 是页边那一笔朱批。*

**官网：** [empty-78c.pages.dev](https://empty-78c.pages.dev) · [GitHub](https://github.com/DaviRain-Su/empty)

## 核心特性

- **防剧透 AI**：所有 AI 功能只基于你已经读过的文本，在数据层过滤未读内容。
- **EPUB / PDF 原生阅读**：EPUB 走原生 SwiftUI 块模型渲染，不经 WebView；PDF 走 PDFKit。
- **朱 · 阅读 Agent**：伴读对话自主调度阅读工具，写操作一律待确认。
- **高亮与批注**：精确 UTF-16 锚定，点击精确跳回原文。
- **词汇与闪卡**：Ebbinghaus 间隔复习、挖空例句、跨书思维链接。
- **本地优先**：默认 Apple Intelligence；可选云端 BYOK，密钥存 Keychain。

## 快速开始

```bash
git clone https://github.com/DaviRain-Su/empty.git
cd Empty
open Empty.xcodeproj
```

选择目标平台（My Mac / iPhone Simulator），`Cmd + R` 运行。导入 `.epub` 或 `.pdf` 即可开始阅读。

## 下载

最新 macOS 构建由 GitHub Actions 产出， artifact 名为 `Empty-macOS`，下载后即为 `.dmg`。注意当前为未签名版本，首次打开需在「系统设置 → 隐私与安全性」中允许。

## 参与

如果这个项目对你有帮助，请点亮 ⭐️ 让更多人发现它。欢迎提交 issue、参与 discussion 或认领 `good first issue`。
