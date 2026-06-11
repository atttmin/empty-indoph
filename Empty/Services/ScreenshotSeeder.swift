//
//  ScreenshotSeeder.swift
//  Empty
//
//  Imports a tiny demo EPUB when `-ScreenshotSeed` is passed (simulator
//  screenshots). No-op when the library already has books.
//

import Foundation
import SwiftData

enum ScreenshotSeeder {
    @MainActor
    static func seedDemoBookIfNeeded(modelContext: ModelContext) throws {
        guard ProcessInfo.processInfo.arguments.contains("-ScreenshotSeed") else { return }
        guard try modelContext.fetchCount(FetchDescriptor<Book>()) == 0 else { return }

        let temp = FileManager.default.temporaryDirectory
            .appending(path: "EmptyScreenshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let epubURL = temp.appending(path: "demo.epub")
        try DemoEPUB.data().write(to: epubURL)

        let store = try BookFileStore.makeDefault()
        _ = try Library(modelContext: modelContext, fileStore: store)
            .importBook(from: epubURL)
    }
}

// MARK: - Minimal EPUB bytes (mirrors EmptyTests fixture)

private enum DemoEPUB {
    static func data() -> Data {
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
            <dc:identifier id="uid">demo-epub</dc:identifier>
          </metadata>
          <manifest>
            <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
          </spine>
        </package>
        """
        let chapter = """
        <html><head><title>第一章</title></head>\
        <body><h1>第一章</h1><p>深读始于空白。导入一本书，朱批落在页边。</p></body></html>
        """
        return storedZIP(entries: [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(containerXML.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/ch1.xhtml", Data(chapter.utf8)),
        ])
    }

    private static func storedZIP(entries: [(name: String, data: Data)]) -> Data {
        var zip = Data()
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            zip.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])
            appendLE16(&zip, 20)
            appendLE16(&zip, 0)
            appendLE16(&zip, 0)
            appendLE16(&zip, 0)
            appendLE16(&zip, 0)
            appendLE32(&zip, 0)
            appendLE32(&zip, UInt32(entry.data.count))
            appendLE32(&zip, UInt32(entry.data.count))
            appendLE16(&zip, UInt16(nameBytes.count))
            appendLE16(&zip, 0)
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