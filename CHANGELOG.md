# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- iOS 随身伴读 aligned with the 02 iOS prototype:
  - 书库 / 阅读 / 卡片 behind a floating capsule tab bar, plus the
    vermilion 朱 button that summons a half-screen AI companion sheet
    from anywhere (same spoiler-safe `CompanionModel` as the Mac panel,
    now shared cross-platform)
  - 书库: time-of-day greeting with real minutes-read-today, a
    continue-reading card, the 朱批·今日伴读 nudge (去复习 / 今天跳过,
    built from due reviews and recent highlights), and a three-column
    designed-cover shelf with import tile
  - 阅读: prototype top bar (centered position line incl. 剩 N 页),
    「译」toggle that translates each paragraph in-flow as you reach it,
    selection bar 解释 / 翻译 / 追问 ↩ / 高亮 (EPUB and PDF), 朱批 margin
    note with 继续追问, ⟲ 思维链接 card with 存为链接卡, and the floating
    朗读条 (TTS now on iOS too)
  - 卡片: one stream merging highlight cards, 复习卡 / 问答卡 / 链接卡,
    a compact Ebbinghaus 生词复习 card (cloze, 忘了 / 记得✓, 下次队列),
    and a 朱批·发现关联 footer

### Changed

- iOS information architecture follows the prototype: the former
  Library / Notes / Study system tabs and the form-style Ask-the-Book
  sheet are replaced by 书库 / 阅读 / 卡片 + the conversational 朱 sheet
  (`LibraryView`, `NotesView`, `StudyView`, `VocabReviewView`,
  `AskBookView` removed); reading settings dropped their own dark-mode
  toggle — the reader now follows the system / workbench theme

### Added (Mac batch)

- 双语对照 / 导读 in-flow reading modes (Mac, EPUB): the reader translates
  or retells each paragraph **as you reach it**, injecting quiet gray
  serif translations (双语) or 朱批-style callouts (导读) directly under
  the original paragraphs, with per-chapter caching and progress status;
  position math and highlight anchoring skip the injected blocks
- Structured AI 章节概览 (Mac, EPUB): the overview card now renders the
  prototype's ① ② ③ three-part outline with a "← 你在这里" position
  marker, "本章约 X 分钟" reading-time estimate, and chapter progress
  pills (cached per chapter in `Chapter.cachedOutline`)
- Saved study cards become real card types in the notes screen:
  问答卡 (save a companion answer with 存为卡片), 链接卡 (save a thought
  link with 存为链接卡), and interactive 复习卡 with 显示答案 / 记得 ✓
  spaced-repetition grading inline (`StudyCardKind` on `StudyCardEntry`)
- 朱批边注 action buttons: 继续追问 ↩ hands the explained selection to
  the companion panel; 存为卡片 keeps the margin note as a 问答卡
- 查看完整图谱: the knowledge-graph button now opens a full-graph sheet —
  recent highlight concepts on a ring, edges drawn where passages
  lexically resonate
- Library hero upgrades: spoiler-safe AI "朱批 · 上次读到" recap (built
  from cached chapter summaries, stored on `Book.cachedHeroRecap`),
  "第 N 章 · <章节名>" label, and a "剩余约 X 小时" estimate; sidebar
  recent rows show "第 N 章 · X%"
- 生词本 polish: cloze sentences blank the word until reveal
  (`nor did I wish to practise ______`), the completed state forecasts
  the next review queue ("下次队列:明天 2 词 · …"), stage pills use the
  prototype's "第N轮 · N天 / 稳固 · N天" wording, and 全部生词 rows
  expand to show the original sentence context
- Reader bottom bar shows "本章还剩 N 页" from live page geometry
- PDF reading: import `.pdf` files, native PDFKit viewer with per-page
  navigation, progress tracking, and AI indexing via per-page `Chapter` rows
- PDF text selection and highlights: selections report through the same
  `ReaderSelection` pipeline as EPUB (highlight button on iOS; explain /
  translate / ask / vocab popover on Mac), and stored highlights paint as
  PDF annotations on the visible page
- Intra-chapter reading position: the paginated reader now reports the
  furthest visible character (`utf16Offset`) on every page turn, so
  spoiler-safe retrieval includes already-read text from the current chapter
- Language-aware sentence embeddings: semantic indexing and retrieval now
  pick the embedding model from the text's language (Chinese supported),
  instead of hardcoding English
- Flashcards: generate study cards from highlights (`StudyCardEntry`,
  `StudyCardStore`) and review them with the Ebbinghaus ladder on the Mac
  vocab screen and the new iOS Study tab (`FlashcardsReviewView`)
- iOS root tabs: Library / Notes / Study, bringing vocab review and
  highlight notes to iPhone and iPad
- CloudKit sync enabled: `Empty.entitlements` + synced store on
  `.automatic`
- Mac notes screen AI theme suggestion for the knowledge graph

### Fixed

- `StudyCardEntry.book` now has an inverse relationship on `Book`
  (`studyCards`, cascade delete) — CloudKit refuses to initialize a synced
  store containing inverse-less relationships, which crashed the app at
  launch with sync enabled; deleting a book also no longer orphans its
  study cards
- Removed duplicated doc-comment line in `ChunkRetriever`
- `BookIndexer` doc comment no longer claims the embedding pass is
  unimplemented (`SemanticIndexer` exists and is wired into ask-the-book)
- Docs: test suite status updated (the previously noted
  `SemanticScorerTests.testRetrieverFallsBackToLexical` failure no longer
  reproduces)

### Known limitations

- Building with the iCloud entitlement requires a paid developer team;
  local test runs can disable signing (`CODE_SIGNING_ALLOWED=NO`)

## [1.0.0] - 2026-06-11

### Added

- Initial release: **空 · AI 伴读** v1.0 prototype
- EPUB import, parsing, and WebKit paginated reader with highlights
- Dual SwiftData persistence (synced metadata + local chapter/chunk store)
- Spoiler-safe chunk retrieval and grounded AI answering
- On-device Apple Foundation Models and cloud BYOK (DeepSeek preset)
- Recap, ask-the-book, chapter summaries, and vocab gloss lookup
- Mac deep-reading workbench: library, reader, notes, vocab screens
- Companion panel, thought links, reading aloud (macOS TTS)
- Ebbinghaus spaced-repetition vocab scheduling
- Vermilion (朱批) design system for Mac UI
- Unit test suite (~79 tests) covering persistence, EPUB, retrieval, highlights, recap, cloud AI

### Known limitations (at 1.0.0; all addressed in Unreleased)

- Reading position tracked at chapter level only
- PDF import supported; PDF reading not implemented
- CloudKit sync prepared but disabled (`syncedDatabase = .none`)
- Flashcard generation implemented in services; no UI yet
- iOS lacks vocab/notes screens (Mac-only)

[1.0.0]: https://github.com/DaviRain-Su/empty/releases/tag/v1.0.0