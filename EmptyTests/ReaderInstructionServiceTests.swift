//
//  ReaderInstructionServiceTests.swift
//  EmptyTests
//

@testable import Empty
import Foundation
import Testing

struct ReaderInstructionServiceTests {
    private let temporaryDirectory: URL
    private let fileManager: FileManager

    init() throws {
        fileManager = FileManager()
        temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    @Test func emptyResultWhenNoFilesExist() {
        let service = ReaderInstructionService(
            fileManager: fileManager,
            globalDirectory: nonexistentDirectory()
        )
        #expect(service.loadInstructions(bookFileURL: nil).isEmpty)
    }

    @Test func loadsGlobalInstructions() throws {
        let globalDirectory = temporaryDirectory.appendingPathComponent("global")
        try fileManager.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        let globalFile = globalDirectory.appendingPathComponent("instructions.md")
        try "Prefer brief answers.".write(to: globalFile, atomically: true, encoding: .utf8)

        let service = ReaderInstructionService(
            fileManager: fileManager,
            globalDirectory: globalDirectory.path
        )
        let sources = service.loadInstructions(bookFileURL: nil)

        #expect(sources.count == 1)
        #expect(sources.first?.content == "Prefer brief answers.")
    }

    @Test func loadsBookAndGlobalInstructions() throws {
        let globalDirectory = temporaryDirectory.appendingPathComponent("global")
        try fileManager.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try "Global.".write(
            to: globalDirectory.appendingPathComponent("instructions.md"),
            atomically: true,
            encoding: .utf8
        )

        let bookContainer = temporaryDirectory.appendingPathComponent("Book")
        try fileManager.createDirectory(at: bookContainer, withIntermediateDirectories: true)
        let bookFile = bookContainer.appendingPathComponent("book.epub")
        try Data().write(to: bookFile)
        try "Per-book.".write(
            to: bookContainer.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = ReaderInstructionService(
            fileManager: fileManager,
            globalDirectory: globalDirectory.path
        )
        let sources = service.loadInstructions(bookFileURL: bookFile)

        #expect(sources.count == 2)
        #expect(sources[0].content == "Global.")
        #expect(sources[1].content == "Per-book.")
    }

    @Test func ignoresEmptyFilesAndDuplicates() throws {
        let globalDirectory = temporaryDirectory.appendingPathComponent("global")
        try fileManager.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try "Global.".write(
            to: globalDirectory.appendingPathComponent("instructions.md"),
            atomically: true,
            encoding: .utf8
        )

        let bookContainer = temporaryDirectory.appendingPathComponent("Book")
        try fileManager.createDirectory(at: bookContainer, withIntermediateDirectories: true)
        let bookFile = bookContainer.appendingPathComponent("book.epub")
        try Data().write(to: bookFile)
        try "".write(
            to: bookContainer.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        let service = ReaderInstructionService(
            fileManager: fileManager,
            globalDirectory: globalDirectory.path
        )
        let sources = service.loadInstructions(bookFileURL: bookFile)

        #expect(sources.count == 1)
        #expect(sources.first?.content == "Global.")
    }

    @Test func promptAppendixFormat() {
        let source = ReaderInstructionSource(path: "/tmp/test.md", content: "Be brief.")
        let appendix = source.promptAppendix()
        #expect(appendix.contains("test.md"))
        #expect(appendix.contains("Be brief."))
    }

    private func nonexistentDirectory() -> String {
        temporaryDirectory.appendingPathComponent("missing").path
    }
}
