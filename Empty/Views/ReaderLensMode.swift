//
//  ReaderLensMode.swift
//  Empty
//

import Foundation

/// Shared policy for the non-original reader lenses across iOS and macOS.
/// Keeps the cache / guide / prompt behavior aligned between the two readers.
nonisolated enum ReaderLensMode: CaseIterable {
    case bilingual
    case companion
    case debate
    case sources

    var translationKind: TranslationKind {
        switch self {
        case .bilingual: .bilingual
        case .companion: .companion
        case .debate: .debate
        case .sources: .sources
        }
    }

    var aiNoteKind: AIInlineNoteKind {
        switch self {
        case .bilingual: .bilingual
        case .companion: .companion
        case .debate: .debate
        case .sources: .sources
        }
    }

    var inlineNoteKind: InlineNoteKind {
        switch self {
        case .bilingual: .bilingual
        case .companion: .companion
        case .debate: .debate
        case .sources: .sources
        }
    }

    var guideLoadingText: String {
        switch self {
        case .bilingual: "生成双语对照…"
        case .companion: "生成导读…"
        case .debate: "生成辩难…"
        case .sources: "生成文献…"
        }
    }

    var guideTitle: String {
        switch self {
        case .bilingual: "今译"
        case .companion: InlineNoteKind.companion.label
        case .debate: InlineNoteKind.debate.label
        case .sources: InlineNoteKind.sources.label
        }
    }

    var pretranslatesTitles: Bool {
        self == .bilingual
    }

    var skipsTargetLanguageParagraphs: Bool {
        self == .bilingual
    }

    func shouldStore(note: String, original: String) -> Bool {
        switch self {
        case .bilingual:
            InlineNoteQuality.isWorthShowing(note: note, original: original)
        case .companion, .debate, .sources:
            !note.isEmpty
        }
    }
}

#if os(macOS)
extension MacReadingMode {
    var lensMode: ReaderLensMode? {
        switch self {
        case .original: nil
        case .bilingual: .bilingual
        case .companion: .companion
        case .debate: .debate
        case .sources: .sources
        }
    }
}
#endif

extension IOSReadingMode {
    var lensMode: ReaderLensMode? {
        switch self {
        case .original: nil
        case .bilingual: .bilingual
        case .companion: .companion
        case .debate: .debate
        case .sources: .sources
        }
    }
}
