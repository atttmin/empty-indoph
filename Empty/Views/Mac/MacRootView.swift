//
//  MacRootView.swift
//  Empty
//
//  Mac "深读工作台" shell from the 01 Mac prototype: a fixed 224pt
//  sidebar (brand, navigation, recent books, weekly stats, theme
//  toggle) beside the active screen.
//

#if os(macOS)

import SwiftData
import SwiftUI

enum MacScreen: Hashable {
    case library
    case reader
    case notes
    case vocab
}

struct MacRootView: View {
    @AppStorage("emptyDarkTheme") private var isDarkTheme = false
    @State private var screen: MacScreen = .library
    @State private var openBook: Book?

    private var palette: EmptyPalette {
        isDarkTheme ? .dark : .light
    }

    var body: some View {
        HStack(spacing: 0) {
            MacSidebar(
                screen: $screen,
                isDarkTheme: $isDarkTheme,
                openBook: openBook,
                onOpenBook: open(_:)
            )
            .frame(width: 224)

            Rectangle()
                .fill(palette.line)
                .frame(width: 1)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.window)
        .environment(\.emptyPalette, palette)
        .preferredColorScheme(isDarkTheme ? .dark : .light)
        .frame(minWidth: 1080, minHeight: 700)
        .animation(.easeInOut(duration: 0.2), value: isDarkTheme)
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .library:
            MacLibraryScreen(onOpenBook: open(_:))
        case .reader:
            if let openBook {
                MacReaderScreen(
                    book: openBook,
                    onBack: { screen = .library },
                    onOpenVocab: { screen = .vocab },
                    onOpenNotes: { screen = .notes }
                )
                .id(openBook.id)
            } else {
                MacLibraryScreen(onOpenBook: open(_:))
            }
        case .notes:
            MacNotesScreen()
        case .vocab:
            MacVocabScreen()
        }
    }

    private func open(_ book: Book) {
        openBook = book
        screen = .reader
    }
}

// MARK: - Sidebar

private struct MacSidebar: View {
    @Binding var screen: MacScreen
    @Binding var isDarkTheme: Bool
    var openBook: Book?
    var onOpenBook: (Book) -> Void

    @Environment(\.emptyPalette) private var palette
    @Query(sort: \Book.lastOpenedAt, order: .reverse) private var books: [Book]
    @Query private var vocabEntries: [VocabEntry]
    @Query private var sessions: [ReadingSession]
    @Query private var highlights: [Highlight]

    @State private var showDiagnostics = false

    private var recentBooks: [Book] {
        Array(books.filter { $0.lastOpenedAt != nil }.prefix(2))
    }

    private var dueVocabCount: Int {
        let now = Date()
        return vocabEntries.count { $0.dueAt <= now }
    }

    /// Hours read in the current week, from real session data.
    private var weeklyHours: Double {
        let calendar = Calendar.current
        guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else {
            return 0
        }
        let seconds = sessions
            .filter { $0.startedAt >= weekStart }
            .reduce(0.0) { total, session in
                total + (session.endedAt ?? session.startedAt)
                    .timeIntervalSince(session.startedAt)
            }
        return seconds / 3600
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clearance for the window's traffic lights.
            Spacer().frame(height: 40)

            HStack(spacing: 10) {
                EnsoMark(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Empty\(Text(".").foregroundStyle(palette.accent))")
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(palette.ink)
                    Text("空 · AI 伴读")
                        .font(.system(size: 10, design: .serif))
                        .kerning(1.4)
                        .foregroundStyle(palette.ink3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 18)

            VStack(spacing: 2) {
                navButton("⌂", "书库", .library)
                navButton("❧", "正在阅读", .reader)
                navButton("❏", "笔记 · 卡片", .notes)
                navButton("Aa", "生词本", .vocab, badge: dueVocabCount)
            }
            .padding(.horizontal, 12)

            if !recentBooks.isEmpty {
                Text("最近阅读")
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.6)
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 22)
                    .padding(.top, 22)
                    .padding(.bottom, 8)

                VStack(spacing: 2) {
                    ForEach(recentBooks) { book in
                        recentRow(book)
                    }
                }
                .padding(.horizontal, 12)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Circle().fill(palette.accent).frame(width: 8, height: 8)
                    Text(weeklySummary)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.ink2)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)

                footerButton(isDarkTheme ? "☀ 浅色主题" : "☾ 深色主题") {
                    isDarkTheme.toggle()
                }
                footerButton("✦ AI 状态") {
                    showDiagnostics = true
                }
            }
            .padding(14)
            .overlay(alignment: .top) {
                Rectangle().fill(palette.line).frame(height: 1)
            }
        }
        .background(palette.side)
        .sheet(isPresented: $showDiagnostics) {
            AIDiagnosticsView()
        }
    }

    private var weeklySummary: String {
        let hours = weeklyHours >= 0.1 ? String(format: "%.1f", weeklyHours) : "0"
        return "本周伴读 \(hours) 小时 · \(highlights.count) 条朱批"
    }

    private func navButton(
        _ glyph: String, _ title: String, _ target: MacScreen, badge: Int = 0
    ) -> some View {
        let isActive = screen == target
        return Button {
            screen = target
        } label: {
            HStack(spacing: 10) {
                Text(glyph)
                    .font(.system(size: glyph == "Aa" ? 12 : 14))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: isActive ? .bold : .medium))
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(palette.onAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(palette.accent, in: Capsule())
                }
            }
            .foregroundStyle(isActive ? palette.accent : palette.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isActive ? palette.accentSoft : .clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ book: Book) -> some View {
        Button {
            onOpenBook(book)
        } label: {
            HStack(spacing: 10) {
                MiniCover(book: book)
                VStack(alignment: .leading, spacing: 1) {
                    Text(book.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(palette.ink)
                        .lineLimit(1)
                    Text(progressLabel(for: book))
                        .font(.system(size: 11))
                        .foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func progressLabel(for book: Book) -> String {
        guard book.progressFraction > 0 else { return "未开始" }
        return "第 \(book.position.chapterIndex + 1) 章 · \(Int(book.progressFraction * 100))%"
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(palette.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(palette.line2, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }
}

/// 22×30 spine-style thumbnail for sidebar rows: real cover if present,
/// else the book's first character on a deterministic cover color.
struct MiniCover: View {
    let book: Book

    var body: some View {
        Group {
            if let data = book.coverThumbnailData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                let style = CoverStyle.style(for: book.title)
                ZStack {
                    style.background
                    Text(String(book.title.prefix(1)))
                        .font(.system(size: 9, weight: .bold, design: .serif))
                        .foregroundStyle(style.foreground)
                }
            }
        }
        .frame(width: 22, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

#Preview {
    MacRootView()
        .modelContainer(try! AppStores.makeContainer(ephemeral: true))
}

#endif
