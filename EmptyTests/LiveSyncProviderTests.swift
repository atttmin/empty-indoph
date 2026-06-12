//
//  LiveSyncProviderTests.swift
//  EmptyTests
//

import CloudKit
import Foundation
import Testing
@testable import Empty

struct LiveSyncProviderTests {
    @Test func bootstrapDeltaCopiesSnapshotRecords() {
        let snapshot = makeProviderTestSnapshot()
        let delta = ReaderLiveSyncDelta.bootstrap(from: snapshot)

        #expect(delta.isFullSnapshot == true)
        #expect(delta.schemaVersion == snapshot.schemaVersion)
        #expect(delta.books == snapshot.books)
        #expect(delta.highlights == snapshot.highlights)
        #expect(delta.tombstones.isEmpty)
    }

    @Test func snapshotFingerprintIgnoresExportedAt() throws {
        let earlier = makeProviderTestSnapshot()
        var later = earlier
        later.exportedAt = Date(timeIntervalSince1970: 9_999)
        #expect(try earlier.stableFingerprint() == later.stableFingerprint())
    }

    @Test func cloudKitProviderMapsAvailableToActiveNoAccountToSetupAndMissingEntitlementToUnavailable() async {
        let active = await CloudKitLiveSyncProvider(
            isEphemeral: false,
            hasEntitlement: { true },
            accountStatusLoader: { .available }
        ).status(selectedMode: .cloudKit)
        #expect(active.state == .active)

        let setupRequired = await CloudKitLiveSyncProvider(
            isEphemeral: false,
            hasEntitlement: { true },
            accountStatusLoader: { .noAccount }
        ).status(selectedMode: .cloudKit)
        #expect(setupRequired.state == .setupRequired)

        let localAvailable = await CloudKitLiveSyncProvider(
            isEphemeral: false,
            hasEntitlement: { true },
            accountStatusLoader: { .available }
        ).status(selectedMode: .localOnly)
        #expect(localAvailable.state == .available)

        let unavailable = await CloudKitLiveSyncProvider(
            isEphemeral: false,
            hasEntitlement: { false },
            accountStatusLoader: { .available }
        ).status(selectedMode: .cloudKit)
        #expect(unavailable.state == .unavailable)
    }

    @Test func serverProviderNeedsSavedTargetBeforeProbe() async {
        let status = await ServerLiveSyncProvider(
            target: nil,
            bearerToken: ""
        ).status(selectedMode: .cloudKit)
        #expect(status.state == .setupRequired)
    }

    @Test func serverProviderReportsSnapshotOnlyWithoutLiveFeature() async {
        let session = makeProviderStubSession { request in
            #expect(request.url?.absoluteString == "https://sync.example.com/v1/health")
            return ProviderStubURLProtocol.response(
                url: request.url!,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: "{\"status\":\"ok\",\"service\":\"Empty Sync\",\"features\":[\"reader-snapshots-v1\"]}".data(using: .utf8)!
            )
        }
        let status = await ServerLiveSyncProvider(
            target: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                lastSnapshotAt: nil,
                lastValidatedAt: nil
            ),
            bearerToken: "",
            session: session
        ).status(selectedMode: .cloudKit)

        #expect(status.state == .snapshotOnly)
        #expect(status.features == [LiveSyncFeature.readerSnapshotsV1.rawValue])
    }

    @Test func serverProviderReportsContractReadyWhenLiveFeaturePresent() async {
        let session = makeProviderStubSession { request in
            ProviderStubURLProtocol.response(
                url: request.url!,
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: "{\"status\":\"ok\",\"service\":\"Empty Sync\",\"features\":[\"reader-snapshots-v1\",\"reader-live-sync-v1\",\"empty-passkey-auth-v1\"]}".data(using: .utf8)!
            )
        }
        let status = await ServerLiveSyncProvider(
            target: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .bearer,
                lastSnapshotAt: nil,
                lastValidatedAt: nil
            ),
            bearerToken: "secret-token",
            session: session
        ).status(selectedMode: .cloudKit)

        #expect(status.state == .contractReady)
        #expect(status.features.contains(LiveSyncFeature.readerLiveSyncV1.rawValue))
        #expect(status.features.contains(ServerPasskeyFeature.authV1.rawValue))
        #expect(status.detail.contains("Passkey"))
    }
}

private func makeProviderTestSnapshot() -> SyncSnapshot {
    let book = Book(title: "Walden", author: "Thoreau", format: .epub)
    book.id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    book.languageTag = "en"
    let highlight = Highlight(
        anchor: TextAnchor(chapterIndex: 0, startUTF16: 0, endUTF16: 8),
        textSnapshot: "Walden",
        color: .yellow,
        note: nil
    )
    highlight.id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    return SyncSnapshot(
        schemaVersion: SyncSnapshot.currentSchemaVersion,
        exportedAt: Date(timeIntervalSince1970: 123),
        books: [BookRecord(book)],
        highlights: [HighlightRecord(highlight)]
    )
}

private func makeProviderStubSession(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    ProviderStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ProviderStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class ProviderStubURLProtocol: URLProtocol, @unchecked Sendable {
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
