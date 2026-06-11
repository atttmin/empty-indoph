//
//  IOSLibraryScreen.swift
//  Empty
//
//  iOS 书库 from the 02 iOS prototype: greeting with today's reading
//  minutes, a continue-reading card, the 朱批·今日伴读 nudge, and the
//  three-column shelf with an import tile.
//

#if !os(macOS)

import SwiftData
import SwiftUI

struct IOSLibraryScreen: View {
    var onOpenBook: (Book) -> Void
    var onReview: () -> Void

    @Environment(\.emptyPalette) private var palette
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.addedAt, order: .reverse) private var books: [Book]
    @Query private var sessions: [ReadingSession]
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]
    @Query private var vocabEntries: [VocabEntry]
    @Query private var studyCards: [StudyCardEntry]

    @State private var isImporterPresented = false
    @State private var isDiagnosticsPresented = false
    @State private var isSearching = false
    @State private var showStats = false
    @State private var searchText = ""
    @State private var errorMessage: String?
    /// "yyyy-MM-dd" of the day the reader skipped the nudge.
    @AppStorage("iosBriefSkippedDay") private var briefSkippedDay = ""

    private var shelfBooks: [Book] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = needle.isEmpty ? books : books.filter {
            $0.title.lowercased().contains(needle) || $0.author.lowercased().contains(needle)
        }
        return filtered.sorted {
            ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt)
        }
    }

    private var continueBook: Book? {
        shelfBooks.first { $0.lastOpenedAt != nil }
    }

    /// Minutes read today, from real session data.
    private var minutesToday: Int {
        let dayStart = Calendar.current.startOfDay(for: Date())
        let seconds = sessions
            .filter { $0.startedAt >= dayStart }
            .reduce(0.0) { total, session in
                total + (session.endedAt ?? session.startedAt)
                    .timeIntervalSince(session.startedAt)
            }
        return Int(seconds / 60)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let salutation: String = switch hour {
        case 5..<12: "早上好"
        case 12..<18: "下午好"
        default: "晚上好"
        }
        return minutesToday > 0
            ? "\(salutation) · 今天已读 \(minutesToday) 分钟"
            : "\(salutation) · 今天还没翻开书"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if isSearching {
                    searchField
                        .padding(.top, 12)
                }

                if let continueBook {
                    continueCard(continueBook)
                        .padding(.top, 18)
                }

                if let brief = dailyBrief {
                    briefCallout(brief)
                        .padding(.top, 14)
                }

                if books.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    shelfHeader
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    shelfGrid
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Library.importableContentTypes,
            allowsMultipleSelection: true,
            onCompletion: handleImport
        )
        .sheet(isPresented: $isDiagnosticsPresented) {
            AIDiagnosticsView()
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
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("书库")
                    .font(.system(size: 30, weight: .black, design: .serif))
                    .foregroundStyle(palette.ink)
                Text(greeting)
                    .font(.system(size: 12.5))
                    .foregroundStyle(palette.ink3)
            }
            Spacer()
            Button {
                showStats = true
            } label: {
                Image(systemName: "chart.bar")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.ink3)
                    .frame(width: 36, height: 36)
                    .background(palette.accentSoft.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showStats) {
                ReadingStatsView()
            }
            Button {
                isDiagnosticsPresented = true
            } label: {
                Text("✦")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink3)
                    .frame(width: 36, height: 36)
                    .background(palette.accentSoft.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isSearching.toggle()
                    if !isSearching { searchText = "" }
                }
            } label: {
                Text("⌕")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.accent)
                    .frame(width: 36, height: 36)
                    .background(palette.accentSoft, in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Text("⌕")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
            TextField("搜索书名或作者…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(palette.ink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(palette.card, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
    }

    // MARK: Continue reading

    private func continueCard(_ book: Book) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            HStack(spacing: 16) {
                SharedBookCover(book: book)
                    .frame(width: 76)

                VStack(alignment: .leading, spacing: 0) {
                    Text("继续阅读")
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.2)
                        .foregroundStyle(palette.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(palette.accentSoft, in: Capsule())
                    Text(book.title)
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                        .padding(.top, 8)
                    Text("第 \(book.position.chapterIndex + 1) 章")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink3)
                        .padding(.top, 2)
                    Spacer(minLength: 10)
                    HStack(spacing: 10) {
                        ProgressView(value: book.progressFraction)
                            .progressViewStyle(.linear)
                            .tint(palette.accent)
                        Text("\(Int((book.progressFraction * 100).rounded()))%")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.ink3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .emptyCard(palette, radius: 18)
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    // MARK: 朱批 · 今日伴读

    private struct DailyBrief {
        var text: String
        var actionTitle: String
    }

    /// Heuristic nudge built from real review/highlight state — no model
    /// call, so the library opens instantly.
    private var dailyBrief: DailyBrief? {
        let today = Self.dayStamp(Date())
        guard briefSkippedDay != today else { return nil }

        let now = Date()
        let dueCount = vocabEntries.count { $0.dueAt <= now }
            + studyCards.count { $0.dueAt <= now }
        if dueCount > 0 {
            return DailyBrief(
                text: "你有 \(dueCount) 张卡片到了复习节点。趁记忆还热,花 3 分钟过一遍?",
                actionTitle: "去复习"
            )
        }
        if let highlight = highlights.first {
            let snippet = highlight.textSnapshot.prefix(18)
            return DailyBrief(
                text: "上次你标下了「\(snippet)…」。回卡片页看看它和其他高亮连成了什么?",
                actionTitle: "去看看"
            )
        }
        return nil
    }

    private func briefCallout(_ brief: DailyBrief) -> some View {
        ZhupiCallout(title: "朱批 · 今日伴读") {
            Text(brief.text)
                .font(.system(size: 13))
                .lineSpacing(5)
                .foregroundStyle(palette.ink2)
            HStack(spacing: 8) {
                Button(brief.actionTitle, action: onReview)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(palette.onAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(palette.accent, in: Capsule())
                Button("今天跳过") {
                    briefSkippedDay = Self.dayStamp(Date())
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.ink3)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(palette.line2, lineWidth: 1))
            }
            .padding(.top, 8)
        }
    }

    private static func dayStamp(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    // MARK: Shelf

    private var shelfHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("我的书架")
                .font(.system(size: 17, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
            Spacer()
            Text("\(shelfBooks.count) 本")
                .font(.system(size: 12))
                .foregroundStyle(palette.ink3)
        }
    }

    private var shelfGrid: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 14, alignment: .top),
                count: 3
            ),
            spacing: 18
        ) {
            ForEach(shelfBooks) { book in
                Button {
                    onOpenBook(book)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        SharedBookCover(book: book)
                        Text(book.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.ink)
                            .lineLimit(1)
                            .padding(.top, 7)
                        Text(statusLine(for: book))
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.ink3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("删除", systemImage: "trash", role: .destructive) {
                        delete(book)
                    }
                }
            }

            Button {
                isImporterPresented = true
            } label: {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        palette.line2,
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
                    .aspectRatio(76 / 108, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 2) {
                            Text("+").font(.system(size: 20, weight: .light))
                            Text("导入").font(.system(size: 10))
                        }
                        .foregroundStyle(palette.ink3)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
    }

    private func statusLine(for book: Book) -> String {
        if book.progressFraction >= 0.995 { return "已读完" }
        if book.progressFraction > 0 {
            return "\(Int((book.progressFraction * 100).rounded()))%"
        }
        return "未开始"
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            EnsoMark(size: 44)
                .opacity(0.5)
            Text("虚室生白")
                .font(.system(size: 20, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
                .padding(.top, 8)
            Text("书架还空着。导入一本 EPUB 或 PDF,开始第一段伴读。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
                .multilineTextAlignment(.center)
            Button("导入书籍") { isImporterPresented = true }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(palette.accent, in: Capsule())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Import / delete

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

#endif
