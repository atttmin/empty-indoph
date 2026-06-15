//
//  ReaderInstructionService.swift
//  Empty
//
//  Discovers reader-supplied instruction files that customize the AI companion
//  for a single book or globally. Modeled after Pi's context-file discovery:
//  files with well-known names near the book (or in the app's notes directory)
//  are loaded and concatenated as a system-prompt appendix.
//

import Foundation

/// A loaded instruction file and where it came from.
struct ReaderInstructionSource: Equatable {
    let path: String
    let content: String
}

/// Discovers AI companion instruction files for a book.
///
/// Search order (later files augment, not replace):
/// 1. `~/Empty/instructions.md` — global reader preferences
/// 2. `<bookContainer>/instructions.md` — per-book instructions (sibling of the imported file)
/// 3. `<bookContainer>/.empty/instructions.md` — hidden per-book instructions
/// 4. `<bookContainer>/CLAUDE.md`
/// 5. `<bookContainer>/.empty/CLAUDE.md`
/// 6. `<bookContainer>/AGENTS.md`
/// 7. `<bookContainer>/.empty/AGENTS.md`
///
/// Only files that exist and are readable are returned. Empty files are ignored
/// so the caller can cleanly fall back to the default system prompt.
struct ReaderInstructionService {
    private let fileManager: FileManager
    private let globalDirectory: String

    init(
        fileManager: FileManager = Foundation.FileManager(),
        globalDirectory: String = ReaderInstructionService.defaultGlobalDirectory()
    ) {
        self.fileManager = fileManager
        self.globalDirectory = globalDirectory
    }

    /// Loads all applicable instruction files for a book.
    ///
    /// - Parameter bookFileURL: The imported book file's URL. The parent
    ///   directory and its `.empty/` subdirectory are searched.
    func loadInstructions(bookFileURL: URL?) -> [ReaderInstructionSource] {
        var candidates: [String] = []

        candidates.append(globalPath(named: "instructions.md"))

        if let bookFileURL {
            let container = bookFileURL.deletingLastPathComponent().path
            let hiddenContainer = (URL(fileURLWithPath: container) as NSURL)
                .appendingPathComponent(".empty")?
                .path ?? "\(container)/.empty"

            candidates.append("\(container)/instructions.md")
            candidates.append("\(hiddenContainer)/instructions.md")
            candidates.append("\(container)/CLAUDE.md")
            candidates.append("\(hiddenContainer)/CLAUDE.md")
            candidates.append("\(container)/AGENTS.md")
            candidates.append("\(hiddenContainer)/AGENTS.md")
        }

        var seen = Set<String>()
        var sources: [ReaderInstructionSource] = []
        for path in candidates {
            let standardized = (path as NSString).standardizingPath
            guard !seen.contains(standardized),
                  let source = readInstruction(at: standardized),
                  !source.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                continue
            }
            seen.insert(standardized)
            sources.append(source)
        }
        return sources
    }

    /// Loads only the global instruction file.
    func loadGlobalInstructions() -> [ReaderInstructionSource] {
        let path = globalPath(named: "instructions.md")
        guard let source = readInstruction(at: path),
              !source.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }
        return [source]
    }

    private func readInstruction(at path: String) -> ReaderInstructionSource? {
        guard fileManager.fileExists(atPath: path),
              let data = fileManager.contents(atPath: path),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return ReaderInstructionSource(path: path, content: content)
    }

    private func globalPath(named filename: String) -> String {
        (globalDirectory as NSString).appendingPathComponent(filename)
    }

    private static func defaultGlobalDirectory() -> String {
        NSHomeDirectory() + "/Empty"
    }
}

extension ReaderInstructionSource {
    /// Formats this source as a system-prompt appendix block.
    func promptAppendix() -> String {
        """
        [Reader instruction from \(path.lastPathComponent)]
        \(content)
        """
    }
}

private extension String {
    var lastPathComponent: String {
        (self as NSString).lastPathComponent
    }
}
