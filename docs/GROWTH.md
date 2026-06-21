# Empty Growth & Launch Plan

How to move Empty from an unknown repo to a trending open-source reading app.

---

## 1. Foundation (do this first)

These are one-time or continuous baseline tasks that multiply every later launch.

### 1.1 GitHub repo hygiene

| Item | Status | Action |
|------|--------|--------|
| Description | ✅ Done | Filled with keywords: "AI Reading Companion", "EPUB/PDF reader", "SwiftUI", "macOS/iOS". |
| Homepage URL | ✅ Done | Points to `https://empty-78c.pages.dev`. |
| Topics | ✅ Done | 16 topics including `swiftui`, `epub-reader`, `pdf-reader`, `ai`, `apple-intelligence`, `deep-reading`, `local-first`. |
| README | ✅ Done | English-first, keyword-rich, badges, screenshots, download CTA, Chinese section. |
| Social preview image | ⬜ Todo | Add an OpenGraph image in repo Settings → Social preview (1200×630). Use the macOS reader screenshot + logo + tagline. |
| Releases | ⬜ Todo | Create a signed/notarized Release when ready; attach `.dmg` and source zip. Unsigned CI artifact is fine for early adopters but blocks broader sharing. |
| Discussions | ⬜ Todo | Enable GitHub Discussions (General + Q&A + Ideas). |
| Issue templates | ⬜ Todo | Add bug report / feature request templates. |
| `good first issue` labels | ⬜ Todo | Label approachable issues to attract first-time contributors. |

### 1.2 Website alignment

- The website already has a clear hero and feature sections.
- Add a "Star on GitHub" button in the header and a floating corner button.
- Add an OpenGraph image and Twitter/X card meta tags.
- Add a short demo video or animated GIF to the hero.
- Add a "Download" page that links to the latest CI artifact / Release.

### 1.3 Demo assets

| Asset | Why | Priority |
|-------|-----|----------|
| 30–60 s demo video/GIF | Highest conversion asset for social media. | High |
| Screenshot carousel | Already have; keep updated. | Medium |
| "A week with Empty" blog post | Storytelling > feature lists. | Medium |
| Feature comparison table | vs FolioReaderKit, Apple Books, Kindle, Calibre. | Low |

---

## 2. SEO & Discoverability on GitHub

GitHub search and Google both index repo name, description, topics, README, and releases.

### 2.1 Keywords to own

Primary:

- `ai reading companion`
- `epub reader macos`
- `epub reader ios`
- `pdf reader swiftui`
- `open source reading app`
- `spoiler free ai`
- `swiftui epub reader`

Secondary:

- `deep reading app`
- `vocabulary builder app`
- `cross book notes`
- `apple intelligence reading`
- `local first reader`
- `knowledge graph reading`

### 2.2 README SEO tactics already applied

- H1 contains the exact phrase "AI Reading Companion for Deep Readers".
- First paragraph repeats "EPUB", "PDF", "SwiftUI", "macOS", "iOS", "local-first", "private".
- Section headings are keyword-rich (`Features`, `Download`, `Architecture`, `Roadmap`).
- Tables, code blocks, and alt text improve indexing.
- Chinese section captures domestic search traffic without diluting English keywords.

### 2.3 Content marketing for long-tail traffic

Publish on:

- **dev.to / Medium / 掘金 / 知乎专栏**: "How I built a spoiler-free AI reader in SwiftUI".
- **GitHub README**: Add a "Built With Empty" or "User Stories" section once you have testimonials.
- **Hacker News / Lobsters**: "Show HN: A SwiftUI EPUB reader that won't spoil the ending".

---

## 3. Launch Sequence

The goal is to create a **star spike** in a 24–48 h window. GitHub Trending ranks repos by star velocity, so coordinated launches matter more than slow trickles.

### 3.1 Pre-launch checklist (1–2 weeks before)

- [ ] Demo video/GIF is ready.
- [ ] README and website are polished.
- [ ] At least one signed Release or a clearly linked CI artifact.
- [ ] Social preview image is set.
- [ ] GitHub Discussions enabled.
- [ ] Twitter/X, 小红书/即刻, Product Hunt accounts ready with bio/link.
- [ ] Draft posts for each channel (see templates below).

### 3.2 Launch day (T)

| Time (UTC) | Channel | Post |
|------------|---------|------|
| T 08:00 | **Product Hunt** | Submit "Empty — AI reading companion that won't spoil your books". Use video + screenshots + maker comment. |
| T 09:00 | **Hacker News Show HN** | "Show HN: Empty, a spoiler-free AI companion for deep reading (SwiftUI, macOS/iOS)". Link to GitHub, not website. |
| T 10:00 | **Twitter/X** | Thread: hook ("Most AI readers spoil the ending"), demo GIF, features, GitHub link, ask for stars/feedback. |
| T 11:00 | **Reddit** | r/swift, r/iOSProgramming, r/MacApps, r/selfhosted, r/books, r/languagelearning. Tailor title per sub. |
| T 12:00 | **dev.to / 掘金** | Cross-post the launch article. |
| T 14:00 | **V2EX** | 分享创造节点：「空 · Empty — 防剧透 AI 深读工作台，开源 SwiftUI 阅读器」。 |
| T 15:00 | **知乎 / 即刻 / 小红书** | 中文短文/视频：痛点（AI 摘要剧透）+ 解决方案 + 截图 + GitHub 链接。 |

### 3.3 Launch week follow-up

- Respond to every comment/issue within hours during the first 48 h.
- Pin a welcome discussion.
- Tweet/X post daily updates: "Day 2: 500 stars — what's next?".
- Post launch recap on dev.to / 掘金 / 知乎 after 7 days.

### 3.4 Sustained rhythm

| Frequency | Activity |
|-----------|----------|
| Weekly | Merge a visible improvement; tweet/X about it. |
| Bi-weekly | Publish a short blog/video about one feature (e.g., "How Empty renders EPUB without WebView"). |
| Monthly | Newsletter round-up + roadmap update discussion. |
| Quarterly | Big release with changelog + Product Hunt re-launch / featured update. |

---

## 4. Channel-Specific Playbooks

### 4.1 Product Hunt

- **Tagline**: "AI companion for deep reading that never spoils the ending."
- **Thumbnail**: macOS reader screenshot with a bold tagline.
- **Gallery**: 5 screenshots (library, reader, Zhu AI, vocabulary, notes).
- **Maker comment**: Tell the story — why "spoiler-free" matters, why SwiftUI, what's next.
- **Ask**: Upvotes + GitHub stars + feedback.

### 4.2 Hacker News (Show HN)

- Title format: `Show HN: Empty – AI reading companion that only uses what you've read`.
- Lead with the technical differentiator (data-layer spoiler filtering, native SwiftUI EPUB renderer).
- Be in the comments early to answer questions.
- Don't ask for upvotes directly; ask for feedback.

### 4.3 Reddit

Tailor per subreddit:

- r/swift: "Open-source SwiftUI EPUB/PDF reader with on-device AI — looking for feedback".
- r/MacApps: "Empty — native macOS reader with AI that respects spoilers".
- r/languagelearning: "I built an EPUB reader with built-in vocab + spaced repetition".
- r/selfhosted / r/privacy: "Local-first EPUB reader with optional BYOK cloud AI".

Follow each sub's self-promotion rules. Participate in comments before posting if required.

### 4.4 Twitter/X

Thread structure:

1. Hook: "Most AI book summaries spoil the ending. I built one that doesn't."
2. Demo GIF (3–5 s).
3. The spoiler-free mechanic in one sentence.
4. Feature carousel (4 tweets).
5. Open-source callout (SwiftUI, GitHub link).
6. CTA: "Star the repo / try the build / reply with your worst AI-spoiler story."

### 4.5 Chinese communities

| Platform | Format | Angle |
|----------|--------|-------|
| 即刻 | 短动态 + 截图 | 独立开发者故事，防剧透 AI。 |
| 小红书 | 图文/短视频 | 「这个开源阅读器治好了我的 AI 剧透 PTSD」。 |
| 知乎 | 长回答/文章 | 在「有哪些好用的 EPUB 阅读器？」等问题下回答。 |
| 掘金 | 技术文章 | SwiftUI 原生 EPUB 渲染、防剧透 AI 管线设计。 |
| V2EX | 分享创造 | 直接发项目帖，附 GitHub 链接。 |

---

## 5. Community & Retention

Stars spike from launches; retention comes from community.

### 5.1 Make contributing easy

- Label `good first issue` and `help wanted` issues.
- Add `CONTRIBUTING.md` with build instructions and code-style notes.
- Respond to PRs within 48 h.
- Highlight contributors in release notes.

### 5.2 Build in public

- Use GitHub Discussions for roadmap voting.
- Share milestones on social: "100 stars → dark mode refactor", "500 stars → iPad UI overhaul".
- Publish a public changelog in Releases, not just `CHANGELOG.md`.

### 5.3 Collect social proof

- Ask early users for screenshots/quotes.
- Add a "Used by" or "Loved by" section to README once you have 5+ testimonials.
- Track GitHub stars, forks, and issue velocity weekly.

---

## 6. Metrics to Track

| Metric | Tool | Goal (30 days post-launch) |
|--------|------|----------------------------|
| GitHub stars | GitHub | 500+ |
| Unique visitors | GitHub insights + website analytics | 5,000+ |
| Release downloads | GitHub Releases | 200+ |
| Product Hunt upvotes | Product Hunt | 200+ |
| Social impressions | Twitter/X, Reddit, 知乎 analytics | 50,000+ |
| Issues / discussions | GitHub | 20+ active threads |
| Forks | GitHub | 30+ |

---

## 7. What to Avoid

- **Don't spam** the same post across subreddits unchanged.
- **Don't buy stars** — GitHub detects this and it kills trust.
- **Don't over-promise** AI capabilities; the spoiler-free angle is the moat.
- **Don't neglect issues** during a launch spike — slow responses waste momentum.

---

## 8. Immediate Next Steps

1. ✅ README and GitHub metadata are updated.
2. ⬜ Add a social preview image in repo settings.
3. ⬜ Enable GitHub Discussions and add a welcome post.
4. ⬜ Create a 30–60 s demo video or GIF.
5. ⬜ Set up a signed Release workflow (or keep promoting the CI artifact for now).
6. ⬜ Draft and schedule the launch-day posts.
7. ⬜ Pick a launch date and execute the sequence in §3.2.

---

*Last updated: 2026-06-21*
