//
//  IOSRootView.swift
//  Empty
//
//  iOS "随身伴读" shell from the 02 iOS prototype: 书库 / 阅读 / 卡片
//  behind a floating capsule tab bar, plus the vermilion 朱 button that
//  summons the half-screen AI companion sheet from anywhere.
//

#if !os(macOS)

import SwiftData
import SwiftUI

enum IOSTab: Hashable {
    case library
    case reader
    case cards
}

struct IOSRootView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Book.lastOpenedAt, order: .reverse) private var books: [Book]

    @State private var tab: IOSTab = .library
    @State private var openBook: Book?
    @State private var companion = CompanionModel()
    @State private var showCompanion = false
    /// Fresher than `book.position` while the reader is open mid-session.
    @State private var companionPosition: ReadingPosition?
    @State private var readerControlsVisible = true

    private var palette: EmptyPalette {
        colorScheme == .dark ? .dark : .light
    }

    /// The book the 阅读 tab and the AI sheet operate on.
    private var currentBook: Book? {
        openBook ?? books.first { $0.lastOpenedAt != nil } ?? books.first
    }

    private var tabBarVisible: Bool {
        tab != .reader || readerControlsVisible
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.window.ignoresSafeArea()

            content

            if tabBarVisible {
                tabBar
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: tabBarVisible)
        .environment(\.emptyPalette, palette)
        .sheet(isPresented: $showCompanion) {
            IOSCompanionSheet(
                model: companion,
                book: currentBook,
                position: companionPosition ?? currentBook?.position
                    ?? ReadingPosition(chapterIndex: 0, utf16Offset: 0)
            )
            .environment(\.emptyPalette, palette)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .library:
            IOSLibraryScreen(
                onOpenBook: open(_:),
                onReview: { tab = .cards }
            )
        case .reader:
            if let book = currentBook {
                ReadingView(
                    book: book,
                    onExit: { tab = .library },
                    onAskCompanion: { question, position in
                        askCompanion(question, position: position)
                    },
                    onControlsChange: { readerControlsVisible = $0 }
                )
                .id(book.id)
            } else {
                readerEmptyState
            }
        case .cards:
            IOSCardsScreen()
        }
    }

    private var readerEmptyState: some View {
        VStack(spacing: 10) {
            EnsoMark(size: 44)
                .opacity(0.5)
            Text("还没有正在读的书")
                .font(.system(size: 18, weight: .black, design: .serif))
                .foregroundStyle(palette.ink)
                .padding(.top, 6)
            Text("去书库挑一本,或导入一个 EPUB / PDF。")
                .font(.system(size: 13))
                .foregroundStyle(palette.ink3)
            Button("去书库 →") { tab = .library }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(palette.accent, in: Capsule())
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton("⌂", "书库", .library)
            tabButton("❧", "阅读", .reader)
            tabButton("❏", "卡片", .cards)
            Button {
                companionPosition = nil
                showCompanion = true
            } label: {
                Text("朱")
                    .font(.system(size: 14, weight: .black, design: .serif))
                    .foregroundStyle(palette.onAccent)
                    .frame(width: 38, height: 38)
                    .background(palette.accent, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
        .shadow(color: palette.shadow, radius: 15, y: 8)
    }

    private func tabButton(_ glyph: String, _ title: String, _ target: IOSTab) -> some View {
        let isActive = tab == target
        return Button {
            tab = target
        } label: {
            HStack(spacing: 6) {
                Text(glyph).font(.system(size: 13))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isActive ? palette.accent : palette.ink3)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(isActive ? palette.accentSoft : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func open(_ book: Book) {
        openBook = book
        readerControlsVisible = true
        tab = .reader
    }

    /// 追问 from the reader: opens the sheet and sends right away, using
    /// the reader's live position so answers stay spoiler-safe.
    private func askCompanion(_ question: String, position: ReadingPosition) {
        companionPosition = position
        companion.draft = question
        showCompanion = true
    }
}

#Preview {
    IOSRootView()
        .modelContainer(try! AppStores.makeContainer(ephemeral: true))
}

#endif
