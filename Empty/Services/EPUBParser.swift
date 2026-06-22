import Foundation
import Compression

/// Parses EPUB files which are ZIP archives containing XHTML content
final class EPUBParser {

    enum ParseError: LocalizedError {
        case fileNotFound
        case invalidEPUB
        case containerNotFound
        case opfNotFound
        case parsingFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound: return "EPUB file not found"
            case .invalidEPUB: return "Invalid EPUB file"
            case .containerNotFound: return "container.xml not found"
            case .opfNotFound: return "OPF file not found"
            case .parsingFailed(let msg): return "Parsing failed: \(msg)"
            }
        }
    }

    func parseBook(
        at fileURL: URL,
        unzipDirectory: URL,
        loadContent: Bool = false
    ) throws -> EPUBBook {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw ParseError.fileNotFound
        }
        if !fileManager.fileExists(atPath: unzipDirectory.path) {
            try unzipEPUB(at: fileURL, to: unzipDirectory)
        }

        let opfURL = try parseOPFURL(from: unzipDirectory)
        let metadata = try parseMetadata(opfURL: opfURL)
        let coverData = extractCoverImage(from: unzipDirectory, metadata: metadata)
        let chapters = try parseChapters(opfURL: opfURL, loadContent: loadContent)

        return EPUBBook(
            metadata: metadata,
            chapters: chapters,
            coverImageData: coverData,
            basePath: unzipDirectory,
            opfDirectory: opfURL.deletingLastPathComponent()
        )
    }

    // MARK: - ZIP Extraction

    private func unzipEPUB(at source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try extractZIP(at: source, to: destination)
    }

    private func extractZIP(at zipURL: URL, to destinationURL: URL) throws {
        let data = try Data(contentsOf: zipURL)
        try extractZIPData(data, to: destinationURL)
    }

    private func extractZIPData(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        var offset = 0
        let bytes = [UInt8](data)
        let count = bytes.count

        while offset + 30 <= count {
            guard bytes[offset] == 0x50,
                  bytes[offset + 1] == 0x4B,
                  bytes[offset + 2] == 0x03,
                  bytes[offset + 3] == 0x04 else {
                break
            }

            let compressionMethod = UInt16(bytes[offset + 8]) | (UInt16(bytes[offset + 9]) << 8)
            let compressedSize = Int(UInt32(bytes[offset + 18]) | (UInt32(bytes[offset + 19]) << 8) | (UInt32(bytes[offset + 20]) << 16) | (UInt32(bytes[offset + 21]) << 24))
            let uncompressedSize = Int(UInt32(bytes[offset + 22]) | (UInt32(bytes[offset + 23]) << 8) | (UInt32(bytes[offset + 24]) << 16) | (UInt32(bytes[offset + 25]) << 24))
            let nameLength = Int(UInt16(bytes[offset + 26]) | (UInt16(bytes[offset + 27]) << 8))
            let extraLength = Int(UInt16(bytes[offset + 28]) | (UInt16(bytes[offset + 29]) << 8))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            guard nameEnd <= count else { break }

            let nameData = Data(bytes[nameStart..<nameEnd])
            // Try UTF-8 first, fall back to CP437 (common for older ZIPs).
            let name: String
            if let utf8Name = String(data: nameData, encoding: .utf8) {
                name = utf8Name
            } else if let cp437Name = String(data: nameData, encoding: .ascii) {
                name = cp437Name
            } else {
                offset = nameEnd + extraLength + compressedSize
                continue
            }

            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressedSize
            guard dataEnd <= count else { break }

            let filePath = destination.appendingPathComponent(name)
            guard filePath.standardizedFileURL.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                offset = dataEnd
                continue
            }

            if name.hasSuffix("/") {
                try? fileManager.createDirectory(at: filePath, withIntermediateDirectories: true)
            } else {
                let parentDir = filePath.deletingLastPathComponent()
                try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)

                let fileData: Data
                if compressionMethod == 0 {
                    fileData = Data(bytes[dataStart..<dataEnd])
                } else if compressionMethod == 8 {
                    let compressedData = Data(bytes[dataStart..<dataEnd])
                    guard let decompressed = decompress(compressedData, expectedSize: uncompressedSize) else {
                        offset = dataEnd
                        continue
                    }
                    fileData = decompressed
                } else {
                    offset = dataEnd
                    continue
                }

                try? fileData.write(to: filePath)
            }

            offset = dataEnd
        }
    }

    private func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }
        let bufferSize = max(expectedSize, 1024)
        let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destinationBuffer.deallocate() }

        let decompressedSize = data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return compression_decode_buffer(
                destinationBuffer, bufferSize,
                baseAddress.assumingMemoryBound(to: UInt8.self), data.count,
                nil,
                COMPRESSION_ZLIB
            )
        }

        guard decompressedSize > 0 else { return nil }
        return Data(bytes: destinationBuffer, count: decompressedSize)
    }

    // MARK: - OPF & Metadata

    private func parseOPFURL(from bookDir: URL) throws -> URL {
        let containerURL = bookDir.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw ParseError.containerNotFound
        }

        let containerData = try Data(contentsOf: containerURL)
        let containerParser = SimpleXMLParser()
        containerParser.parse(data: containerData)

        guard let opfPath = containerParser.rootfilePath else {
            throw ParseError.opfNotFound
        }

        return bookDir.appendingPathComponent(opfPath)
    }

    private func parseMetadata(opfURL: URL) throws -> EPUBMetadata {
        let opfData = try Data(contentsOf: opfURL)
        let opfParser = OPFParser()
        opfParser.parse(data: opfData)

        var metadata = opfParser.metadata
        if let coverID = opfParser.coverImageID,
           let coverHref = opfParser.manifest[coverID] {
            let opfDir = opfURL.deletingLastPathComponent()
            metadata.coverImagePath = opfDir.appendingPathComponent(coverHref).path
        }

        return metadata
    }

    private func extractCoverImage(from bookDir: URL, metadata: EPUBMetadata) -> Data? {
        if let coverPath = metadata.coverImagePath {
            return try? Data(contentsOf: URL(fileURLWithPath: coverPath))
        }

        let commonPaths = [
            "cover.jpg", "cover.jpeg", "cover.png",
            "images/cover.jpg", "images/cover.jpeg", "images/cover.png",
            "OEBPS/images/cover.jpg", "OEBPS/images/cover.jpeg", "OEBPS/images/cover.png",
            "OEBPS/cover.jpg", "OEBPS/cover.jpeg", "OEBPS/cover.png"
        ]

        for path in commonPaths {
            let url = bookDir.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }

        return nil
    }

    // MARK: - Chapter Parsing

    private func parseChapters(
        opfURL: URL,
        loadContent: Bool
    ) throws -> [EPUBChapter] {
        let opfData = try Data(contentsOf: opfURL)
        let opfParser = OPFParser()
        opfParser.parse(data: opfData)

        let opfDir = opfURL.deletingLastPathComponent()
        var chapters: [EPUBChapter] = []

        for spineItem in opfParser.spine {
            guard let href = opfParser.manifest[spineItem] else { continue }
            let chapterURL = opfDir.appendingPathComponent(href)

            let content: String
            do {
                content = try String(contentsOf: chapterURL, encoding: .utf8)
            } catch {
                guard let raw = try? Data(contentsOf: chapterURL),
                      let detected = Self.detectEncoding(raw) else { continue }
                content = detected
            }

            let title = extractTitle(from: content)
                ?? href.components(separatedBy: "/").last?
                    .replacingOccurrences(of: ".xhtml", with: "")
                    .replacingOccurrences(of: ".html", with: "")
                ?? "Chapter"

            let tocTitle = opfParser.tocTitles[spineItem] ?? title

            chapters.append(EPUBChapter(
                title: tocTitle,
                href: href,
                content: loadContent ? content : ""
            ))
        }

        return chapters
    }

    private func extractTitle(from htmlContent: String) -> String? {
        if let range = htmlContent.range(of: "<title>(.*?)</title>", options: .regularExpression) {
            let match = htmlContent[range]
            let cleaned = match
                .replacingOccurrences(of: "<title>", with: "")
                .replacingOccurrences(of: "</title>", with: "")
            if !cleaned.isEmpty && cleaned != "Untitled" {
                return cleaned
            }
        }

        if let range = htmlContent.range(of: "<h1[^>]*>(.*?)</h1>", options: .regularExpression) {
            let match = htmlContent[range]
            return match
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    /// Detect HTML/XHTML encoding from BOM, XML declaration, or meta charset.
    private static func detectEncoding(_ data: Data) -> String? {
        let raw = [UInt8](data)
        let prefix = String(decoding: data.prefix(2048), as: UTF8.self)

        // 1. BOM detection
        if raw.starts(with: [0xFF, 0xFE]) {
            return String(data: data.advanced(by: 2), encoding: .utf16LittleEndian)
        }
        if raw.starts(with: [0xFE, 0xFF]) {
            return String(data: data.advanced(by: 2), encoding: .utf16BigEndian)
        }

        // 2. XML declaration: <?xml encoding="..."?>
        if let xmlEnd = prefix.range(of: "?>") {
            let xmlDecl = prefix[prefix.startIndex..<xmlEnd.lowerBound]
            if let encStart = xmlDecl.range(of: "encoding"),
               let qStart = xmlDecl[encStart.upperBound...].firstIndex(of: "\""),
               let qEnd = xmlDecl[qStart...].dropFirst().firstIndex(of: "\"") {
                let encName = xmlDecl[xmlDecl.index(after: qStart)..<qEnd].lowercased()
                let cfEnc = CFStringConvertIANACharsetNameToEncoding(encName as CFString)
                if cfEnc != kCFStringEncodingInvalidId {
                    let nsEnc = CFStringConvertEncodingToNSStringEncoding(cfEnc)
                    return String(data: data, encoding: String.Encoding(rawValue: nsEnc))
                }
            }
        }

        // 3. BOM-less UTF-16 detection (no BOM, but valid UTF-16BE/LE)
        if raw.count >= 2 {
            if raw[0] == 0x00 && raw[1] != 0x00 {
                return String(data: data, encoding: .utf16BigEndian)
            }
            if raw[0] != 0x00 && raw[1] == 0x00 {
                return String(data: data, encoding: .utf16LittleEndian)
            }
        }

        // 4. Final fallback: common legacy encodings
        for enc in [String.Encoding.windowsCP1252, .isoLatin1, .ascii] {
            if let s = String(data: data, encoding: enc) {
                return s
            }
        }

        return nil
    }
}

// MARK: - XML Parsers

/// Parses container.xml to find the OPF file path
private class SimpleXMLParser: NSObject, XMLParserDelegate {
    var rootfilePath: String?

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "rootfile" || elementName.hasSuffix(":rootfile") {
            rootfilePath = attributeDict["full-path"]
        }
    }
}

/// Parses the OPF (Open Packaging Format) file for metadata, manifest, and spine
private class OPFParser: NSObject, XMLParserDelegate {
    var metadata = EPUBMetadata()
    var manifest: [String: String] = [:]
    var manifestMediaTypes: [String: String] = [:]
    var spine: [String] = []
    var coverImageID: String?
    var tocTitles: [String: String] = [:]

    private var currentElement = ""
    private var currentText = ""
    private var inMetadata = false

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""

        switch localName {
        case "metadata":
            inMetadata = true
        case "item":
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
                if let mediaType = attributeDict["media-type"] {
                    manifestMediaTypes[id] = mediaType
                }
            }
        case "itemref":
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        case "meta":
            if attributeDict["name"] == "cover" {
                coverImageID = attributeDict["content"]
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        if localName == "metadata" {
            inMetadata = false
            return
        }

        guard inMetadata else { return }

        switch localName {
        case "title":
            if !text.isEmpty { metadata.title = text }
        case "creator":
            if !text.isEmpty { metadata.author = text }
        case "language":
            if !text.isEmpty { metadata.language = text }
        case "identifier":
            if !text.isEmpty { metadata.identifier = text }
        case "publisher":
            if !text.isEmpty { metadata.publisher = text }
        case "description":
            if !text.isEmpty { metadata.description = text }
        default:
            break
        }
    }
}
