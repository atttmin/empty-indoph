//
//  ServerLiveSyncClient.swift
//  Empty
//

import Foundation

nonisolated enum ServerLiveSyncClientError: LocalizedError {
    case invalidResponse
    case unsupported
    case conflictRequiresReset
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Server 返回了无法识别的 live sync 响应。"
        case .unsupported:
            "这个 server 还没有启用 reader-live-sync-v1。"
        case .conflictRequiresReset:
            "Server 要求先 reset / rebase 当前游标。"
        case .providerError(let message):
            message
        }
    }
}

nonisolated struct ServerLiveSyncClient {
    let configuration: ServerSnapshotClient.Configuration
    let session: URLSession

    init(configuration: ServerSnapshotClient.Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func pull(cursor: LiveSyncCursor?, wantsFullSnapshot: Bool = false) async throws -> ReaderLiveSyncPullResponse {
        let request = try makeRequest(
            path: ["v1", "reader-live-sync", configuration.normalizedNamespace(), "pull"],
            method: "POST",
            body: try SyncSnapshotCodec.makeEncoder().encode(
                ReaderLiveSyncPullRequest(cursor: cursor, wantsFullSnapshot: wantsFullSnapshot)
            )
        )
        let (data, _) = try await perform(request)
        guard let response = try? SyncSnapshotCodec.makeDecoder().decode(ReaderLiveSyncPullResponse.self, from: data) else {
            throw ServerLiveSyncClientError.invalidResponse
        }
        return response
    }

    func push(delta: ReaderLiveSyncDelta, baseCursor: LiveSyncCursor?) async throws -> ReaderLiveSyncPushResponse {
        let request = try makeRequest(
            path: ["v1", "reader-live-sync", configuration.normalizedNamespace(), "push"],
            method: "POST",
            body: try SyncSnapshotCodec.makeEncoder().encode(
                ReaderLiveSyncPushRequest(baseCursor: baseCursor, delta: delta)
            ),
            schemaVersion: delta.schemaVersion
        )
        let (data, _) = try await perform(request)
        guard let response = try? SyncSnapshotCodec.makeDecoder().decode(ReaderLiveSyncPushResponse.self, from: data) else {
            throw ServerLiveSyncClientError.invalidResponse
        }
        if response.resetRequired {
            throw ServerLiveSyncClientError.conflictRequiresReset
        }
        return response
    }

    private func makeRequest(
        path: [String],
        method: String,
        body: Data,
        schemaVersion: Int = ReaderLiveSyncDelta.currentSchemaVersion
    ) throws -> URLRequest {
        let baseURL = try configuration.normalizedBaseURL()
        var url = baseURL
        for component in path {
            url = url.appending(path: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/vnd.empty.reader-live-sync+json, application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/vnd.empty.reader-live-sync+json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.deviceLabel, forHTTPHeaderField: "X-Empty-Device")
        request.setValue(String(schemaVersion), forHTTPHeaderField: "X-Empty-Schema-Version")
        if let authorizationHeader = try configuration.resolvedAuthorizationHeader() {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerLiveSyncClientError.invalidResponse
        }
        if http.statusCode == 404 || http.statusCode == 501 {
            throw ServerLiveSyncClientError.unsupported
        }
        if http.statusCode == 409 {
            throw ServerLiveSyncClientError.conflictRequiresReset
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = decodeErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw ServerLiveSyncClientError.providerError(message)
        }
        return (data, http)
    }

    private func decodeErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let envelope = try? SyncSnapshotCodec.makeDecoder().decode(ServerLiveSyncErrorEnvelope.self, from: data) {
            return envelope.error.message ?? envelope.message
        }
        let text = String(data: data, encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated private struct ServerLiveSyncErrorEnvelope: Codable, Sendable {
    struct ErrorBody: Codable {
        var message: String?
    }

    var message: String?
    var error: ErrorBody
}
