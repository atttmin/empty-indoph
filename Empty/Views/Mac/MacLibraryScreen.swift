//
//  MacLibraryScreen.swift
//  Empty
//
//  书库 from the 01 Mac prototype: a "continue reading" hero for the
//  most recent book, then the shelf grid with an import tile.
//

#if os(macOS)

import SwiftData
import SwiftUI

struct MacLibraryScreen: View {
    var onOpenBook: (Book) -> Void

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]

    @State private var isImporterPresented = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]


    private var shelfBooks: [Book] {
        let filtered = filteredBooks
        return filtered.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
    }

    private var filteredBooks: [Book] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return books }
        return books.filter { book in
            if book.title.lowercased().contains(needle) { return true }
            if book.author.lowercased().contains(needle) { return true }
            let bookHighlights = highlights.filter { $0.book?.id == book.id }
            if bookHighlights.contains(where: { $0.textSnapshot.lowercased().contains(needle) }) {
                return true
            }
            return false
        }
    }

    private var continueBook: Book? {
        filteredBooks.filter { $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if let continueBook {
                    ContinueReadingHero(book: continueBook, onOpen: onOpenBook)
                        .padding(.top, 28)
                }

                shelfHeader
                    .padding(.top, 36)
                    .padding(.bottom, 16)

                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 20, alignment: .top),
                        count: 6
                    ),
                    spacing: 24
                ) {
                    ForEach(shelfBooks) { book in
                        ShelfItem(book: book, onOpen: onOpenBook)
                            .contextMenu {
                                Button("删除", systemImage: "trash", role: .destructive) {
                                    delete(book)
                                }
                            }
                    }
                    importTile
                }
            }
            .frame(maxWidth: 1010, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 36)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Library.importableContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("书库")
                .font(.system(size: 32, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
            Spacer()
            MacSearchField(
                text: $searchText,
                placeholder: "搜索书名、高亮或问过的问题…"
            )
            Button {
                isImporterPresented = true
            } label: {
                Text("+ 导入书籍")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.window)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(palette.ink, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var shelfHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("我的书架")
                .font(.system(size: 18, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
            Text("\(shelfBooks.count) 本 · 按最近阅读排序")
                .font(.system(size: 12))
                .foregroundStyle(palette.ink3)
        }
    }

    private var importTile: some View {
        Button {
            isImporterPresented = true
        } label: {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    palette.line2,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
                .aspectRatio(132 / 188, contentMode: .fit)
                .overlay {
                    VStack(spacing: 4) {
                        Text("+").font(.system(size: 26, weight: .light))
                        Text("导入 EPUB / PDF").font(.system(size: 11.5))
                    }
                    .foregroundStyle(palette.ink3)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            let library = try Library(modelContext: modelContext)
            for url in try result.get() {
                try library.importBook(from: url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ book: Book) {
        do {
            try Library(modelContext: modelContext).deleteBook(book)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Hero

private struct ContinueReadingHero: View {
    let book: Book
    var onOpen: (Book) -> Void

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext

    @State private var heroRecap: String?
    @State private var chapterLabel: String?
    @State private var remainingLabel: String?

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            BookCoverView(book: book, width: 132)
                .onTapGesture { onOpen(book) }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("继续阅读")
                        .emptyChip(foreground: palette.accent, background: palette.accentSoft)
                    if let chapterLabel {
                        Text(chapterLabel)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.ink3)
                            .lineLimit(1)
                    } else if let openedAt = book.lastOpenedAt {
                        Text("上次阅读 \(openedAt.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.ink3)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(book.title)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(palette.ink2)
                            .lineLimit(1)
                    }
                }
                .padding(.top, 12)

                ZhupiCallout(title: "朱批 · 上次读到") {
                    Text(heroRecap ?? fallbackTeaser)
                        .font(.system(size: 13.5))
                        .lineSpacing(5)
                        .foregroundStyle(palette.ink2)
                        .lineLimit(4)
                }
                .padding(.top, 12)

                Spacer(minLength: 14)

                HStack(spacing: 18) {
                    Button {
                        onOpen(book)
                    } label: {
                        Text("继续阅读 →")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(palette.onAccent)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(palette.accent, in: Capsule())
                            .accessibilityIdentifier("continueReadingButton")
                    }
                    .buttonStyle(.plain)

                    ProgressView(value: book.progressFraction)
                        .progressViewStyle(.linear)
                        .tint(palette.accent)
                        .frame(maxWidth: 280)

                    Text(progressLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(EdgeInsets(top: 26, leading: 28, bottom: 26, trailing: 28))
        .emptyCard(palette, radius: 18)
        .task(id: "\(book.id)-\(book.position.chapterIndex)") {
            await loadHeroDetails()
        }
    }

    private var fallbackTeaser: String {
        "第 \(book.position.chapterIndex + 1) 章。打开后,可随时呼出「朱 · AI 伴读」回顾前情、就这一页提问 — 只根据你已读的部分回答,不剧透。"
    }

    private var progressLabel: String {
        let percent = "\(Int((book.progressFraction * 100).rounded()))%"
        if let remainingLabel {
            return "\(percent) · \(remainingLabel)"
        }
        return percent
    }

    /// Fills the chapter label, remaining-time estimate, and — when it's
    /// cheap — the spoiler-safe AI "上次读到" recap.
    private func loadHeroDetails() async {
        let bookID = book.id
        let chapterIndex = book.position.chapterIndex
        let chapters = (try? modelContext.fetch(
            FetchDescriptor<Chapter>(
                predicate: #Predicate { $0.bookID == bookID },
                sortBy: [SortDescriptor(\.index)]
            )
        )) ?? []

        if let current = chapters.first(where: { $0.index == chapterIndex }) {
            var label = "第 \(chapterIndex + 1) 章"
            if let title = current.title, !title.isEmpty {
                label += " · \(title)"
            }
            chapterLabel = label
        }

        let totalLength = chapters.reduce(0) { $0 + $1.utf16Length }
        remainingLabel = ReadingTimeEstimate.remainingLabel(
            totalUTF16Length: totalLength,
            progressFraction: book.progressFraction,
            languageTag: book.languageTag
        )

        if let cached = book.cachedHeroRecap, !cached.isEmpty,
           book.cachedHeroRecapChapterIndex == chapterIndex {
            heroRecap = cached
            return
        }
        guard chapterIndex > 0 else { return }
        // Only auto-build when every prior chapter already carries a cached
        // condensation — then the recap is a single cheap reduce call. The
        // expensive map pass stays an explicit choice (RecapView).
        let prior = chapters.filter { $0.index < chapterIndex }
        guard !prior.isEmpty, prior.allSatisfy({ chapter in
            chapter.cachedSummary?.isEmpty == false
                || chapter.utf16Length < RecapBuilder.inlineSummaryThreshold
        }) else { return }

        let resolution = AIProviderSettings.load().resolveUsableService()
        guard resolution.service.availability.isAvailable else { return }
        do {
            let recap = try await RecapBuilder(
                modelContext: modelContext,
                summarize: { text, focus in
                    try await resolution.service.summarize(text, focus: focus)
                }
            ).recap(
                for: book,
                before: ReadingPosition(chapterIndex: chapterIndex, utf16Offset: 0)
            )
            let trimmed = recap.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            heroRecap = trimmed
            book.cachedHeroRecap = trimmed
            book.cachedHeroRecapChapterIndex = chapterIndex
            try? modelContext.save()
        } catch {
            // The static teaser stays.
        }
    }
}

// MARK: - Shelf

private struct ShelfItem: View {
    let book: Book
    var onOpen: (Book) -> Void

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        Button {
            onOpen(book)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                BookCoverView(book: book)
                Text(book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.ink)
                    .lineLimit(1)
                    .padding(.top, 10)
                Text(statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(palette.ink3)
                    .padding(.top, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusLine: String {
        let highlightCount = book.highlights?.count ?? 0
        var parts: [String] = []
        if book.progressFraction >= 0.995 {
            parts.append("已读完")
        } else if book.progressFraction > 0 {
            parts.append("\(Int(book.progressFraction * 100))%")
        } else {
            parts.append("未开始")
        }
        if highlightCount > 0 {
            parts.append("\(highlightCount) 条朱批")
        }
        return parts.joined(separator: " · ")
    }
}

/// Full-size cover: real thumbnail when the EPUB had one, otherwise a
/// designed placeholder in the prototype's cover language (serif title,
/// author line, "EMPTY 藏本" colophon).
struct BookCoverView: View {
    let book: Book
    var width: CGFloat?

    @Environment(\.emptyPalette) private var palette

    var body: some View {
        Group {
            if let data = book.coverThumbnailData, let image = NSImage(data: data) {
                Color.clear
                    .aspectRatio(132 / 188, contentMode: .fit)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                placeholder
            }
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.black.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: palette.shadow, radius: 10, y: 8)
    }

    private var placeholder: some View {
        let style = CoverStyle.style(for: book.title)
        return VStack(alignment: .leading, spacing: 0) {
            if !book.author.isEmpty {
                Text(book.author.uppercased())
                    .font(.system(size: 8))
                    .kerning(2)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            Text(book.title)
                .font(.system(size: 17, weight: .bold, design: .serif))
                .lineLimit(4)
                .padding(.top, 8)
            Spacer(minLength: 0)
            Rectangle()
                .fill(style.foreground.opacity(0.35))
                .frame(height: 1)
                .padding(.bottom, 6)
            Text("EMPTY 藏本")
                .font(.system(size: 8))
                .kerning(2)
                .opacity(0.6)
        }
        .foregroundStyle(style.foreground)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .aspectRatio(132 / 188, contentMode: .fit)
        .background(style.background)
    }
}

#endif
