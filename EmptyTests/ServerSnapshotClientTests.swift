//
//  ServerSnapshotClientTests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

struct ServerSnapshotClientTests {
    @Test func backupProviderCatalogIncludesFolderAndServer() {
        let kinds = SyncProviderCatalog.backupProviders.map(\.kind)
        #expect(kinds == [.folder, .server])
    }

    @Test func syncSettingsRoundTripServerTarget() throws {
        let suiteName = "ServerSnapshotClientTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SyncSettings(
            liveMode: .localOnly,
            folderTarget: nil,
            serverTarget: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .bearer,
                lastSnapshotAt: Date(timeIntervalSince1970: 10),
                lastValidatedAt: Date(timeIntervalSince1970: 20),
                liveCursor: LiveSyncCursor(opaqueValue: "cursor-9"),
                lastLivePullAt: Date(timeIntervalSince1970: 30),
                lastLivePushAt: Date(timeIntervalSince1970: 40),
                autoSyncEnabled: true,
                autoSyncIntervalSeconds: 180,
                lastAutoSyncAt: Date(timeIntervalSince1970: 50),
                lastAutoSyncFingerprint: "abcdef1234567890"
            )
        )
        settings.save(defaults: defaults)

        let loaded = SyncSettings.load(defaults: defaults)
        #expect(loaded.liveMode == .localOnly)
        #expect(loaded.serverTarget?.baseURLString == "https://sync.example.com")
        #expect(loaded.serverTarget?.namespace == "reader-main")
        #expect(loaded.serverTarget?.authMode == .bearer)
        #expect(loaded.serverTarget?.liveCursor?.opaqueValue == "cursor-9")
        #expect(loaded.serverTarget?.lastLivePullAt == Date(timeIntervalSince1970: 30))
        #expect(loaded.serverTarget?.lastLivePushAt == Date(timeIntervalSince1970: 40))
        #expect(loaded.serverTarget?.autoSyncEnabled == true)
        #expect(loaded.serverTarget?.clampedAutoSyncIntervalSeconds == 180)
        #expect(loaded.serverTarget?.lastAutoSyncAt == Date(timeIntervalSince1970: 50))
        #expect(loaded.serverTarget?.shortFingerprint == "abcdef123456")
    }

    @Test func syncSettingsLoadsLegacyV1Payload() throws {
        struct LegacySyncSettings: Codable {
            var liveMode: SyncLiveMode
            var folderTarget: SyncSettings.FolderBackupTarget?
        }

        let suiteName = "LegacySyncSettings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let legacy = LegacySyncSettings(liveMode: .localOnly, folderTarget: nil)
        defaults.set(try JSONEncoder().encode(legacy), forKey: "sync.settings.v1")

        let loaded = SyncSettings.load(defaults: defaults)
        #expect(loaded.liveMode == .localOnly)
        #expect(loaded.serverTarget == nil)
    }

    @Test func healthCheckUsesExpectedEndpointAndBearerHeader() async throws {
        let session = makeStubSession { request in
            #expect(request.url?.absoluteString == "https://sync.example.com/v1/health")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
            #expect(request.value(forHTTPHeaderField: "X-Empty-Device") == "Test Device")
            return StubURLProtocol.response(
                url: request.url!,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: "{\"status\":\"ok\",\"service\":\"Empty Sync\"}".data(using: .utf8)!
            )
        }

        let client = ServerSnapshotClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .bearer,
                bearerToken: "secret-token",
                deviceLabel: "Test Device"
            ),
            session: session
        )

        let health = try await client.healthCheck()
        #expect(health.status == "ok")
        #expect(health.service == "Empty Sync")
    }

    @Test func uploadSnapshotUsesStableContract() async throws {
        let snapshot = makeSnapshot()
        let session = makeStubSession { request in
            #expect(request.url?.absoluteString == "https://sync.example.com/v1/reader-snapshots/reader-main/latest")
            #expect(request.httpMethod == "PUT")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.empty.sync-snapshot+json")
            let body = try #require(requestBodyData(from: request))
            let decoded = try SyncSnapshotCodec.makeDecoder().decode(SyncSnapshot.self, from: body)
            #expect(decoded.books.first?.title == snapshot.books.first?.title)
            return StubURLProtocol.response(
                url: request.url!,
                statusCode: 200,
                headers: ["ETag": "etag-1"],
                body: "{\"namespace\":\"reader-main\",\"updatedAt\":\"1970-01-01T00:02:03Z\"}".data(using: .utf8)!
            )
        }

        let client = ServerSnapshotClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                bearerToken: "",
                deviceLabel: "Uploader"
            ),
            session: session
        )

        let receipt = try await client.export(snapshot: snapshot)
        #expect(receipt.locationDescription == "reader-main")
        #expect(receipt.etag == "etag-1")
        #expect(receipt.updatedAt == Date(timeIntervalSince1970: 123))
    }

    @Test func restoreLatestDecodesSnapshotAndMaps404() async throws {
        let snapshot = makeSnapshot()
        let payload = try SyncSnapshotCodec.makeEncoder().encode(snapshot)
        let goodSession = makeStubSession { request in
            #expect(request.url?.absoluteString == "https://sync.example.com/v1/reader-snapshots/reader-main/latest")
            #expect(request.httpMethod == "GET")
            return StubURLProtocol.response(url: request.url!, statusCode: 200, headers: [:], body: payload)
        }
        let goodClient = ServerSnapshotClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                bearerToken: ""
            ),
            session: goodSession
        )

        let restored = try await goodClient.restoreLatest()
        #expect(restored.books.first?.id == snapshot.books.first?.id)

        let missingSession = makeStubSession { request in
            StubURLProtocol.response(url: request.url!, statusCode: 404, headers: [:], body: Data())
        }
        let missingClient = ServerSnapshotClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                bearerToken: ""
            ),
            session: missingSession
        )

        await #expect(throws: ServerSnapshotClientError.self) {
            _ = try await missingClient.restoreLatest()
        }
    }
    @Test func liveSyncPullUsesExpectedContract() async throws {
        let session = makeStubSession { request in
            #expect(request.url?.absoluteString == "https://sync.example.com/v1/reader-live-sync/reader-main/pull")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/vnd.empty.reader-live-sync+json")
            let body = try #require(requestBodyData(from: request))
            let decoded = try SyncSnapshotCodec.makeDecoder().decode(ReaderLiveSyncPullRequest.self, from: body)
            #expect(decoded.cursor?.opaqueValue == "cursor-1")
            #expect(decoded.wantsFullSnapshot == false)
            return StubURLProtocol.response(
                url: request.url!,
                statusCode: 200,
                headers: [:],
                body: """
                {"delta":{"schemaVersion":1,"emittedAt":"1970-01-01T00:02:03Z","isFullSnapshot":false,"books":[],"highlights":[],"sessions":[],"vocab":[],"studyCards":[],"bookmarks":[],"memoryItems":[],"tombstones":[]},"nextCursor":{"opaqueValue":"cursor-2","serverTime":"1970-01-01T00:03:20Z"},"resetRequired":false}
                """.data(using: .utf8)!
            )
        }

        let client = ServerLiveSyncClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                bearerToken: "",
                deviceLabel: "Puller"
            ),
            session: session
        )

        let response = try await client.pull(cursor: LiveSyncCursor(opaqueValue: "cursor-1"))
        #expect(response.nextCursor?.opaqueValue == "cursor-2")
        #expect(response.delta.books.isEmpty)
        #expect(response.resetRequired == false)
    }

    @Test func liveSyncPushUsesExpectedContract() async throws {
        let delta = ReaderLiveSyncDelta.bootstrap(from: makeSnapshot())
        let session = makeStubSession { request in
            #expect(request.url?.absoluteString == "https://sync.example.com/v1/reader-live-sync/reader-main/push")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Empty-Schema-Version") == String(delta.schemaVersion))
            let body = try #require(requestBodyData(from: request))
            let decoded = try SyncSnapshotCodec.makeDecoder().decode(ReaderLiveSyncPushRequest.self, from: body)
            #expect(decoded.baseCursor?.opaqueValue == "cursor-1")
            #expect(decoded.delta.books.first?.title == delta.books.first?.title)
            return StubURLProtocol.response(
                url: request.url!,
                statusCode: 200,
                headers: [:],
                body: """
                {"acceptedCursor":{"opaqueValue":"cursor-2","serverTime":"1970-01-01T00:03:20Z"},"serverTime":"1970-01-01T00:03:20Z","resetRequired":false}
                """.data(using: .utf8)!
            )
        }

        let client = ServerLiveSyncClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                bearerToken: "",
                deviceLabel: "Pusher"
            ),
            session: session
        )

        let response = try await client.push(delta: delta, baseCursor: LiveSyncCursor(opaqueValue: "cursor-1"))
        #expect(response.acceptedCursor?.opaqueValue == "cursor-2")
        #expect(response.resetRequired == false)
    }
}


private func makeSnapshot() -> SyncSnapshot {
    let book = Book(title: "Walden", author: "Thoreau", format: .epub)
    book.id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    book.languageTag = "en"
    book.addedAt = Date(timeIntervalSince1970: 100)
    book.position = .start
    book.progressFraction = 0.25
    return SyncSnapshot(
        schemaVersion: SyncSnapshot.currentSchemaVersion,
        exportedAt: Date(timeIntervalSince1970: 123),
        books: [BookRecord(book)]
    )
}

private func makeStubSession(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    StubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
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

private func requestBodyData(from request: URLRequest) -> Data? {
    if let data = request.httpBody {
        return data
    }
    guard let stream = request.httpBodyStream else {
        return nil
    }
    stream.open()
    defer { stream.close() }
    let bufferSize = 1024
    var buffer = [UInt8](repeating: 0, count: bufferSize)
    var data = Data()
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}
