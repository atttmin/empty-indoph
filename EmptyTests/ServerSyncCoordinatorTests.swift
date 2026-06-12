//
//  ServerSyncCoordinatorTests.swift
//  EmptyTests
//

import Foundation
import SwiftData
import Testing
@testable import Empty

@MainActor
struct ServerSyncCoordinatorTests {
    @Test func pullAppliesTombstonesIntoLocalStore() async throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext

        let book = Book(title: "Walden", author: "Thoreau", format: .epub)
        context.insert(book)
        let highlight = Highlight(
            anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 6),
            textSnapshot: "Walden",
            color: .yellow,
            note: nil
        )
        highlight.book = book
        context.insert(highlight)
        try context.save()
        let highlightID = highlight.id

        let session = makeCoordinatorSession(
            SequenceResponder([
                { (request: URLRequest) in
                    #expect(request.url?.absoluteString == "https://sync.example.com/v1/reader-live-sync/reader-main/pull")
                    return CoordinatorStubURLProtocol.response(
                        url: request.url!,
                        statusCode: 200,
                        headers: [:],
                        body: """
                        {"delta":{"schemaVersion":1,"emittedAt":"1970-01-01T00:02:03Z","isFullSnapshot":false,"books":[],"highlights":[],"sessions":[],"vocab":[],"studyCards":[],"bookmarks":[],"memoryItems":[],"tombstones":[{"kind":"highlight","recordID":"\(highlightID.uuidString)","deletedAt":"1970-01-01T00:02:04Z"}]},"nextCursor":{"opaqueValue":"cursor-2","serverTime":"1970-01-01T00:03:20Z"},"resetRequired":false}
                        """.data(using: .utf8)!
                    )
                }
            ])
        )

        let coordinator = ServerSyncCoordinator(
            client: ServerLiveSyncClient(
                configuration: .init(
                    baseURLString: "https://sync.example.com",
                    namespace: "reader-main",
                    authMode: .none,
                    bearerToken: ""
                ),
                session: session
            )
        )

        let summary = try await coordinator.pull(into: context, cursor: nil as LiveSyncCursor?)
        #expect(summary.tombstoneCount == 1)
        #expect(summary.cursor?.opaqueValue == "cursor-2")
        #expect(try context.fetchCount(FetchDescriptor<Highlight>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }

    @Test func syncPullsThenPushesUsingPulledCursor() async throws {
        let container = try AppStores.makeContainer(ephemeral: true)
        let context = container.mainContext
        let remoteBook = Book(title: "Walden", author: "Thoreau", format: .epub)
        remoteBook.id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let remoteBookID = remoteBook.id
        let remoteSnapshot = SyncSnapshot(
            schemaVersion: SyncSnapshot.currentSchemaVersion,
            exportedAt: Date(timeIntervalSince1970: 123),
            books: [BookRecord(remoteBook)]
        )
        let remoteDelta = ReaderLiveSyncDelta.bootstrap(from: remoteSnapshot)

        let session = makeCoordinatorSession(
            SequenceResponder([
                { (request: URLRequest) in
                    #expect(request.url?.absoluteString == "https://sync.example.com/v1/reader-live-sync/reader-main/pull")
                    let body = try #require(coordinatorRequestBody(from: request))
                    let decoded = try SyncSnapshotCodec.makeDecoder().decode(ReaderLiveSyncPullRequest.self, from: body)
                    #expect(decoded.cursor == nil)
                    return CoordinatorStubURLProtocol.response(
                        url: request.url!,
                        statusCode: 200,
                        headers: [:],
                        body: try SyncSnapshotCodec.makeEncoder().encode(
                            ReaderLiveSyncPullResponse(
                                delta: remoteDelta,
                                nextCursor: LiveSyncCursor(opaqueValue: "cursor-2", serverTime: Date(timeIntervalSince1970: 200)),
                                resetRequired: false
                            )
                        )
                    )
                },
                { (request: URLRequest) in
                    #expect(request.url?.absoluteString == "https://sync.example.com/v1/reader-live-sync/reader-main/push")
                    let body = try #require(coordinatorRequestBody(from: request))
                    let decoded = try SyncSnapshotCodec.makeDecoder().decode(ReaderLiveSyncPushRequest.self, from: body)
                    #expect(decoded.baseCursor?.opaqueValue == "cursor-2")
                    #expect(decoded.delta.isFullSnapshot == true)
                    #expect(decoded.delta.books.first?.id == remoteBookID)
                    return CoordinatorStubURLProtocol.response(
                        url: request.url!,
                        statusCode: 200,
                        headers: [:],
                        body: try SyncSnapshotCodec.makeEncoder().encode(
                            ReaderLiveSyncPushResponse(
                                acceptedCursor: LiveSyncCursor(opaqueValue: "cursor-3", serverTime: Date(timeIntervalSince1970: 300)),
                                serverTime: Date(timeIntervalSince1970: 300),
                                resetRequired: false
                            )
                        )
                    )
                }
            ])
        )

        let coordinator = ServerSyncCoordinator(
            client: ServerLiveSyncClient(
                configuration: .init(
                    baseURLString: "https://sync.example.com",
                    namespace: "reader-main",
                    authMode: .none,
                    bearerToken: ""
                ),
                session: session
            )
        )

        let summary = try await coordinator.sync(into: context, cursor: nil as LiveSyncCursor?)
        #expect(summary.pull.cursor?.opaqueValue == "cursor-2")
        #expect(summary.push.cursor?.opaqueValue == "cursor-3")
        #expect(try context.fetchCount(FetchDescriptor<Book>()) == 1)
    }
}

private func makeCoordinatorSession(_ responder: SequenceResponder) -> URLSession {
    CoordinatorStubURLProtocol.responder = responder
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoordinatorStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func coordinatorRequestBody(from request: URLRequest) -> Data? {
    if let data = request.httpBody {
        return data
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

private final class SequenceResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let handlers: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data)]

    init(_ handlers: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data)]) {
        self.handlers = handlers
    }

    func handle(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        lock.lock()
        let current = index
        index += 1
        lock.unlock()
        return try handlers[current](request)
    }
}

private final class CoordinatorStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: SequenceResponder?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try responder.handle(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func response(url: URL, statusCode: Int, headers: [String: String], body: Data) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: headers)!,
            body
        )
    }
}
