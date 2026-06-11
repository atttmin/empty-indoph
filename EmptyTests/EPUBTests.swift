//
//  EPUBTests.swift
//  EmptyTests
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct EPUBImportTests {
    @Test func importParsesMetadataCoverlessChaptersAndPlainText() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "EPUBTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let source = tempDirectory.appending(path: "raw-import.epub")
        try TestEPUB.minimal().write(to: source)

        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let store = BookFileStore(
            rootDirectory: tempDirectory.appending(path: "store", directoryHint: .isDirectory)
        )
        let library = Library(modelContext: context, fileStore: store)

        let book = try library.importBook(from: source)

        // Real OPF metadata wins over the filename fallback.
        #expect(book.title == "思维之书")
        #expect(book.author == "测试作者")
        #expect(book.languageTag == "zh")

        // Chapter records carry tag-free plain text for the AI layer.
        let chapters = try context.fetch(
            FetchDescriptor<Chapter>(sortBy: [SortDescriptor(\Chapter.index)])
        )
        #expect(chapters.count == 2)
        #expect(chapters[0].title == "第一章")
        #expect(chapters[0].text.contains("第一章正文"))
        #expect(chapters[0].text.contains("强调内容"))
        #expect(!chapters[0].text.contains("<"))
        #expect(chapters[1].text.contains("第二章正文"))

        // The unzipped archive landed inside the book's file-store directory.
        #expect(
            FileManager.default.fileExists(
                atPath: store.unzipDirectory(forBookID: book.id).path
            )
        )
    }

    @Test func corruptEPUBStillImportsWithFilenameTitle() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "EPUBTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: tempDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let source = tempDirectory.appending(path: "Broken Book.epub")
        try Data("definitely not a zip".utf8).write(to: source)

        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let store = BookFileStore(
            rootDirectory: tempDirectory.appending(path: "store", directoryHint: .isDirectory)
        )
        let library = Library(modelContext: context, fileStore: store)

        // Import never loses the file: record created, title from filename.
        let book = try library.importBook(from: source)
        #expect(book.title == "Broken Book")
        #expect(try context.fetchCount(FetchDescriptor<Chapter>()) == 0)
    }
}

struct HTMLPlainTextTests {
    @Test func stripsTagsDecodesEntitiesAndKeepsParagraphs() {
        let html = """
        <html><head><title>T</title><style>p { color: red; }</style></head>\
        <body><h1>标题</h1><p>第一段 &amp; 文本。</p><p>第二段 &mdash; 结尾。</p></body></html>
        """
        let text = HTMLPlainText.extract(from: html)
        #expect(text == "标题\n第一段 & 文本。\n第二段 — 结尾。")
    }

    @Test func dropsScriptBlocksAcrossLines() {
        let html = """
        <body><script>
        var x = 1;
        </script><p>Visible.</p></body>
        """
        #expect(HTMLPlainText.extract(from: html) == "Visible.")
    }
}

struct NativeChapterParserTests {
    @Test func extractsReadableBlocksImagesAndParagraphIndexes() {
        let chapter = EPUBChapter(
            title: "Native",
            href: "Text/ch1.xhtml",
            content: """
            <html xmlns="http://www.w3.org/1999/xhtml">
              <head><title>Ignored</title></head>
              <body>
                <h1>第一章</h1>
                <p>第一段 <em>强调</em>&nbsp;文字。</p>
                <blockquote>引文</blockquote>
                <ul><li>列表项</li></ul>
                <img src="../Images/pic.jpg" alt="插图"/>
              </body>
            </html>
            """
        )

        let document = NativeChapterParser.parse(chapter)

        #expect(document.blocks.count == 5)
        #expect(document.textBlocks.map(\.text) == ["第一章", "第一段 强调 文字。", "引文", "列表项"])
        #expect(document.blocks.compactMap(\.readerParagraph?.idx) == [0, 1, 2])
        if case .image(_, let source, let alt) = document.blocks.last {
            #expect(source == "../Images/pic.jpg")
            #expect(alt == "插图")
        } else {
            Issue.record("Expected image block")
        }
    }

    @Test func malformedXHTMLFallsBackToPlainParagraphs() {
        let chapter = EPUBChapter(
            title: "Broken",
            href: "broken.xhtml",
            content: "<html><body><p>第一段<p>第二段</body></html>"
        )

        let document = NativeChapterParser.parse(chapter)

        #expect(document.blocks.compactMap(\.readerParagraph?.text).contains("第一段"))
        #expect(!document.blocks.isEmpty)
    }
}

struct NativeChapterOffsetsTests {
    @Test func resolvesTextSpansAndSelectionContextPrecisely() {
        let chapter = EPUBChapter(
            title: "Native",
            href: "Text/ch2.xhtml",
            content: """
            <html xmlns="http://www.w3.org/1999/xhtml">
              <body>
                <h1>Chapter</h1>
                <p>第一段 甲乙丙。</p>
                <p>第二段 甲乙丙。</p>
                <p>尾段 收束。</p>
              </body>
            </html>
            """
        )

        let document = NativeChapterParser.parse(chapter)
        let chapterText = document.plainText
        let spans = document.resolvedTextSpans(in: chapterText)
        let secondParagraph = document.blocks[2]

        guard let span = spans[secondParagraph.id] else {
            Issue.record("Missing resolved span")
            return
        }

        #expect(span.chapterRange.lowerBound < span.chapterRange.upperBound)
        #expect(span.paragraphInfo?.idx == 1)

        let selected = "甲乙丙"
        guard let localRange = PlainTextSearch.utf16Range(of: selected, in: secondParagraph.text),
              let selection = document.selection(
                for: secondParagraph.id,
                localUTF16Range: localRange,
                chapterPlainText: chapterText,
                spans: spans
              ) else {
            Issue.record("Missing precise selection context")
            return
        }

        #expect(selection.text == selected)
        #expect(selection.prefix.contains("第二段"))
        #expect(selection.suffix.contains("尾段"))
    }

    @Test func convertsAbsoluteHighlightRangesIntoLocalRanges() {
        let span = NativeTextBlockSpan(
            blockID: "p-1",
            chapterRange: 20..<42,
            paragraphInfo: ReaderParagraph(idx: 0, text: "dummy")
        )

        #expect(span.localRange(intersecting: 24..<31) == 4..<11)
        #expect(span.localRange(intersecting: 0..<10) == nil)
        #expect(span.localRange(intersecting: 35..<50) == 15..<22)
    }
}

// MARK: - Minimal EPUB fixture

/// Builds a tiny but structurally valid EPUB: a stored-entry (uncompressed)
/// ZIP holding container.xml, an OPF with Dublin Core metadata, and two
/// XHTML chapters. Exercises the real unzip → OPF → chapter pipeline.
private enum TestEPUB {
    static func minimal() -> Data {
        let containerXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:title>思维之书</dc:title>
            <dc:creator>测试作者</dc:creator>
            <dc:language>zh</dc:language>
            <dc:identifier id="uid">test-epub-001</dc:identifier>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
          </spine>
        </package>
        """

        let chapter1 = """
        <html><head><title>第一章</title></head>\
        <body><h1>第一章</h1><p>第一章正文，包含<em>强调内容</em>。</p></body></html>
        """

        let chapter2 = """
        <html><head><title>第二章</title></head>\
        <body><h1>第二章</h1><p>第二章正文。</p></body></html>
        """

        return storedZIP(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/ch1.xhtml", Data(chapter1.utf8)),
            ("OEBPS/ch2.xhtml", Data(chapter2.utf8)),
        ])
    }

    /// Stored-method-only ZIP writer. `EPUBParser` walks local file headers
    /// sequentially and ignores CRCs and the central directory, so neither
    /// is emitted.
    private static func storedZIP(entries: [(name: String, data: Data)]) -> Data {
        var zip = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            zip.append(contentsOf: [0x50, 0x4B, 0x03, 0x04]) // local header signature
            appendLE16(&zip, 20) // version needed
            appendLE16(&zip, 0) // flags
            appendLE16(&zip, 0) // compression method: stored
            appendLE16(&zip, 0) // mod time
            appendLE16(&zip, 0) // mod date
            appendLE32(&zip, 0) // crc32 (unchecked by the parser)
            appendLE32(&zip, UInt32(entry.data.count)) // compressed size
            appendLE32(&zip, UInt32(entry.data.count)) // uncompressed size
            appendLE16(&zip, UInt16(nameBytes.count)) // name length
            appendLE16(&zip, 0) // extra length
            zip.append(contentsOf: nameBytes)
            zip.append(entry.data)
        }
        return zip
    }

    private static func appendLE16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8(value >> 8))
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}
