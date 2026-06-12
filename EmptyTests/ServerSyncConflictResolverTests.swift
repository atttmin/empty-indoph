//
//  ServerSyncConflictResolverTests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

struct ServerSyncConflictResolverTests {
    @Test func keepLocalLeavesOverlappingChangesIntact() {
        let sharedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let local = ReaderLiveSyncDelta(
            emittedAt: Date(timeIntervalSince1970: 10),
            books: [makeBookRecord(id: sharedID, title: "Local", chapterIndex: 1, progress: 0.2)]
        )
        let remote = ReaderLiveSyncDelta(
            emittedAt: Date(timeIntervalSince1970: 20),
            books: [makeBookRecord(id: sharedID, title: "Remote", chapterIndex: 2, progress: 0.4)]
        )

        let resolution = ServerSyncConflictResolver.resolve(
            localDelta: local,
            remoteDelta: remote,
            policy: .keepLocal,
            resolvedAt: Date(timeIntervalSince1970: 30)
        )

        #expect(resolution.deltaToApplyLocally.books.count == 1)
        #expect(resolution.deltaToPush.books.count == 1)
        #expect(resolution.summary?.policy == .keepLocal)
        #expect(resolution.summary?.conflictCount == 1)
    }

    @Test func keepRemoteDropsOverlappingChangesButKeepsIndependentOnes() {
        let sharedID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let localOnlyID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let deletedBookmarkID = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let local = ReaderLiveSyncDelta(
            emittedAt: Date(timeIntervalSince1970: 10),
            books: [
                makeBookRecord(id: sharedID, title: "Local shared", chapterIndex: 1, progress: 0.2),
                makeBookRecord(id: localOnlyID, title: "Local only", chapterIndex: 3, progress: 0.8),
            ],
            tombstones: [LiveSyncTombstone(kind: .bookmark, recordID: deletedBookmarkID, deletedAt: Date(timeIntervalSince1970: 9))]
        )
        let remote = ReaderLiveSyncDelta(
            emittedAt: Date(timeIntervalSince1970: 20),
            books: [makeBookRecord(id: sharedID, title: "Remote shared", chapterIndex: 2, progress: 0.4)],
            tombstones: [LiveSyncTombstone(kind: .bookmark, recordID: deletedBookmarkID, deletedAt: Date(timeIntervalSince1970: 11))]
        )

        let resolution = ServerSyncConflictResolver.resolve(
            localDelta: local,
            remoteDelta: remote,
            policy: .keepRemote,
            resolvedAt: Date(timeIntervalSince1970: 30)
        )

        #expect(resolution.deltaToApplyLocally.books.map { $0.id } == [localOnlyID])
        #expect(resolution.deltaToPush.books.map { $0.id } == [localOnlyID])
        #expect(resolution.deltaToPush.tombstones.isEmpty)
        #expect(resolution.summary?.policy == .keepRemote)
        #expect(resolution.summary?.conflictCount == 2)
    }
}

private func makeBookRecord(id: UUID, title: String, chapterIndex: Int, progress: Double) -> BookRecord {
    let book = Book(title: title, author: "Thoreau", format: .epub)
    book.id = id
    book.addedAt = Date(timeIntervalSince1970: 1)
    book.position = ReadingPosition(chapterIndex: chapterIndex, utf16Offset: 0)
    book.progressFraction = progress
    return BookRecord(book)
}
