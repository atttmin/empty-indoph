//
//  ServerSnapshotClient.swift
//  Empty
//

import Foundation

nonisolated enum ServerSnapshotClientError: LocalizedError {
    case invalidBaseURL
    case invalidNamespace
    case missingBearerToken
    case invalidResponse
    case snapshotMissing
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            "Server Base URL 无效；请输入 http:// 或 https:// 开头的地址。"
        case .invalidNamespace:
            "命名空间不能为空，且只能包含字母、数字、点、横线或下划线。"
        case .missingBearerToken:
            "当前 server target 需要有效凭证。若你用的是 Passkey，请重新登录账号。"
        case .invalidResponse:
            "Server 返回了无法识别的响应。"
        case .snapshotMissing:
            "Server 上还没有这个命名空间的读者快照。"
        case .providerError(let message):
            message
        }
    }
}

nonisolated struct ServerSnapshotHealth: Codable, Equatable, Sendable {
    var status: String?
    var service: String?
    var features: [String]?
}

nonisolated struct ServerSnapshotReceipt: Codable, Equatable, Sendable {
    var namespace: String?
    var updatedAt: Date?
    var etag: String?
}

nonisolated struct ServerSnapshotClient: SyncSnapshotBackupProvider {
    nonisolated struct Configuration: Equatable, Sendable {
        var baseURLString: String
        var namespace: String
        var authMode: ServerAuthMode
        var bearerToken: String
        var deviceLabel: String

        init(
            baseURLString: String,
            namespace: String,
            authMode: ServerAuthMode,
            bearerToken: String,
            deviceLabel: String = "Empty"
        ) {
            self.baseURLString = baseURLString
            self.namespace = namespace
            self.authMode = authMode
            self.bearerToken = bearerToken
            self.deviceLabel = deviceLabel
        }

        func normalizedBaseURL() throws -> URL {
            let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw ServerSnapshotClientError.invalidBaseURL
            }
            return url
        }

        func normalizedNamespace() throws -> String {
            let trimmed = namespace.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.unicodeScalars.allSatisfy({ scalar in
                      CharacterSet.alphanumerics.contains(scalar)
                          || scalar == "."
                          || scalar == "-"
                          || scalar == "_"
                  })
            else {
                throw ServerSnapshotClientError.invalidNamespace
            }
            return trimmed
        }

        func resolvedAuthorizationHeader() throws -> String? {
            switch authMode {
            case .none:
                return nil
            case .bearer, .passkeySession:
                let trimmed = bearerToken.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw ServerSnapshotClientError.missingBearerToken
                }
                return "Bearer \(trimmed)"
            }
        }
    }

    let configuration: Configuration
    let session: URLSession

    init(configuration: Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    var providerTitle: String {
        configuration.baseURLString
    }

    func healthCheck() async throws -> ServerSnapshotHealth {
        let request = try makeRequest(path: ["v1", "health"], method: "GET", contentType: nil)
        let (data, _) = try await perform(request)
        guard !data.isEmpty else { return ServerSnapshotHealth(status: "ok", service: nil, features: nil) }
        return (try? SyncSnapshotCodec.makeDecoder().decode(ServerSnapshotHealth.self, from: data))
            ?? ServerSnapshotHealth(status: "ok", service: nil, features: nil)
    }

    func export(snapshot: SyncSnapshot) async throws -> SyncBackupReceipt {
        let request = try makeRequest(
            path: ["v1", "reader-snapshots", configuration.normalizedNamespace(), "latest"],
            method: "PUT",
            contentType: "application/vnd.empty.sync-snapshot+json",
            body: try SyncSnapshotCodec.makeEncoder().encode(snapshot),
            schemaVersion: snapshot.schemaVersion
        )
        let (data, response) = try await perform(request)
        let receipt = try decodeReceipt(data: data, response: response, fallbackDate: snapshot.exportedAt)
        return SyncBackupReceipt(
            locationDescription: receipt.namespace ?? configuration.namespace,
            updatedAt: receipt.updatedAt,
            etag: receipt.etag
        )
    }

    func restoreLatest() async throws -> SyncSnapshot {
        let request = try makeRequest(
            path: ["v1", "reader-snapshots", configuration.normalizedNamespace(), "latest"],
            method: "GET",
            contentType: nil,
            accept: "application/vnd.empty.sync-snapshot+json, application/json"
        )
        let (data, _) = try await perform(request)
        do {
            return try SyncSnapshotCodec.makeDecoder().decode(SyncSnapshot.self, from: data)
        } catch {
            throw ServerSnapshotClientError.invalidResponse
        }
    }

    private func makeRequest(
        path: [String],
        method: String,
        contentType: String?,
        body: Data? = nil,
        accept: String = "application/json",
        schemaVersion: Int? = nil
    ) throws -> URLRequest {
        let baseURL = try configuration.normalizedBaseURL()
        var url = baseURL
        for component in path {
            url = url.appending(path: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(configuration.deviceLabel, forHTTPHeaderField: "X-Empty-Device")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let schemaVersion {
            request.setValue(String(schemaVersion), forHTTPHeaderField: "X-Empty-Schema-Version")
        }
        if let authorizationHeader = try configuration.resolvedAuthorizationHeader() {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerSnapshotClientError.invalidResponse
        }
        if http.statusCode == 404 {
            throw ServerSnapshotClientError.snapshotMissing
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = decodeErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw ServerSnapshotClientError.providerError(message)
        }
        return (data, http)
    }

    private func decodeReceipt(data: Data, response: HTTPURLResponse, fallbackDate: Date) throws -> ServerSnapshotReceipt {
        if data.isEmpty {
            return ServerSnapshotReceipt(
                namespace: try configuration.normalizedNamespace(),
                updatedAt: fallbackDate,
                etag: response.value(forHTTPHeaderField: "ETag")
            )
        }
        guard var receipt = try? SyncSnapshotCodec.makeDecoder().decode(ServerSnapshotReceipt.self, from: data) else {
            throw ServerSnapshotClientError.invalidResponse
        }
        if receipt.namespace == nil {
            receipt.namespace = try configuration.normalizedNamespace()
        }
        if receipt.updatedAt == nil {
            receipt.updatedAt = fallbackDate
        }
        if receipt.etag == nil {
            receipt.etag = response.value(forHTTPHeaderField: "ETag")
        }
        return receipt
    }

    private func decodeErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let envelope = try? SyncSnapshotCodec.makeDecoder().decode(ServerErrorEnvelope.self, from: data) {
            return envelope.error.message ?? envelope.message
        }
        let text = String(data: data, encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated private struct ServerErrorEnvelope: Codable, Sendable {
    struct ErrorBody: Codable {
        var message: String?
    }

    var message: String?
    var error: ErrorBody
}
