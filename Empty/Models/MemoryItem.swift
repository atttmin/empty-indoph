//
//  MemoryItem.swift
//  Empty
//
//  ReaderMemory entries (docs/READER-MEMORY-PLAN.md §3.1): summaries
//  derived from reader behaviour — highlights with notes, link cards,
//  saved Q&A. Synced store; bodies are short summaries and must never
//  contain unread-chapter text (the ingest sources are read-only-by-
//  construction: highlights and cards only exist on read text).
//

import Foundation
import SwiftData

nonisolated enum MemoryKind: String, Codable, CaseIterable, Sendable {
    /// 高亮 + 读者笔记.
    case highlightNote
    /// 链接卡 (StudyCardKind.link).
    case thoughtLink
    /// 保存的问答卡.
    case companionQA
    /// 派生主题 (LLM 提炼, 确认后参与召回).
    case theme
    /// 派生：常查词/主题词.
    case vocabPattern

    var title: String {
        switch self {
        case .highlightNote: "高亮批注"
        case .thoughtLink: "思维链接"
        case .companionQA: "问答"
        case .theme: "主题"
        case .vocabPattern: "词汇"
        }
    }
}

@Model
final class MemoryItem {
    var id: UUID = UUID()
    var kindRawValue: String = MemoryKind.highlightNote.rawValue
    /// Short title for UI and retrieval.
    var title: String = ""
    /// Summary body (≤ 2KB by convention) — never unread source text.
    var body: String = ""
    var bookID: UUID?
    var chapterIndex: Int?
    /// "Walden · 第 2 章" — provenance shown with citations.
    var sourceLabel: String?
    /// Comma-joined topic tags (CloudKit-friendly scalar).
    var tagsRawValue: String = ""
    /// Highlight.id / StudyCardEntry.id the item derives from.
    var sourceRefID: UUID?
    var sourceRefKind: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Derived items join recall only after the reader confirms them.
    var isUserConfirmed: Bool = false

    var kind: MemoryKind {
        get { MemoryKind(rawValue: kindRawValue) ?? .highlightNote }
        set { kindRawValue = newValue.rawValue }
    }

    var tags: [String] {
        get {
            tagsRawValue.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
        set { tagsRawValue = newValue.joined(separator: ",") }
    }

    init(
        kind: MemoryKind,
        title: String,
        body: String,
        bookID: UUID? = nil,
        chapterIndex: Int? = nil,
        sourceLabel: String? = nil,
        tags: [String] = [],
        sourceRefID: UUID? = nil,
        sourceRefKind: String? = nil,
        isUserConfirmed: Bool = false
    ) {
        self.kindRawValue = kind.rawValue
        self.title = title
        self.body = body
        self.bookID = bookID
        self.chapterIndex = chapterIndex
        self.sourceLabel = sourceLabel
        self.tagsRawValue = tags.joined(separator: ",")
        self.sourceRefID = sourceRefID
        self.sourceRefKind = sourceRefKind
        self.isUserConfirmed = isUserConfirmed
    }
}
