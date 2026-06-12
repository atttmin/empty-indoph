//
//  ServerPasskeyClient.swift
//  Empty
//

import Foundation

nonisolated enum ServerPasskeyFeature: String, Codable, CaseIterable, Sendable {
    case authV1 = "empty-passkey-auth-v1"
}

nonisolated enum ServerPasskeyClientError: LocalizedError {
    case unsupported
    case invalidResponse
    case missingSessionToken
    case invalidChallenge
    case invalidUserID
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "这个 server 还没有声明 empty-passkey-auth-v1。"
        case .invalidResponse:
            "Server 返回了无法识别的 Passkey 响应。"
        case .missingSessionToken:
            "Passkey 登录成功了，但 server 没有返回会话 token。"
        case .invalidChallenge:
            "Server 返回的 Passkey challenge 无法解码。"
        case .invalidUserID:
            "Server 返回的 userID 无法解码。"
        case .providerError(let message):
            message
        }
    }
}

nonisolated struct ServerPasskeySession: Codable, Equatable, Sendable {
    var accountID: String
    var displayName: String
    var email: String?
    var issuedAt: Date?
    var expiresAt: Date?
}

nonisolated struct ServerPasskeyRegistrationOptions: Codable, Equatable, Sendable {
    var relyingPartyID: String
    var challenge: String
    var userID: String
    var userName: String
    var userDisplayName: String
}

nonisolated struct ServerPasskeyAuthenticationOptions: Codable, Equatable, Sendable {
    var relyingPartyID: String
    var challenge: String
    var allowedCredentialIDs: [String]?
}

nonisolated struct ServerPasskeyRegistrationFinishRequest: Codable, Equatable, Sendable {
    var credentialID: String
    var clientDataJSON: String
    var attestationObject: String
}

nonisolated struct ServerPasskeyAuthenticationFinishRequest: Codable, Equatable, Sendable {
    var credentialID: String
    var clientDataJSON: String
    var authenticatorData: String
    var signature: String
    var userID: String?
}

nonisolated struct ServerPasskeyAuthResult: Codable, Equatable, Sendable {
    var sessionToken: String
    var session: ServerPasskeySession
}

nonisolated struct ServerPasskeyClient {
    private struct RegistrationOptionsRequest: Codable, Sendable {
        var displayName: String?
        var deviceLabel: String
    }

    private struct AuthenticationOptionsRequest: Codable, Sendable {
        var deviceLabel: String
    }

    let configuration: ServerSnapshotClient.Configuration
    let session: URLSession

    init(configuration: ServerSnapshotClient.Configuration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    func fetchSession() async throws -> ServerPasskeySession? {
        let request = try makeRequest(path: ["v1", "auth", "session"], method: "GET", body: nil)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerPasskeyClientError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 404 {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerPasskeyClientError.providerError(decodeErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        return try decode(ServerPasskeySession.self, from: data)
    }

    func signOut() async throws {
        let request = try makeRequest(path: ["v1", "auth", "session"], method: "DELETE", body: nil)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerPasskeyClientError.invalidResponse
        }
        if http.statusCode == 401 || http.statusCode == 404 {
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerPasskeyClientError.providerError(decodeErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
    }

    func beginRegistration(displayName: String?) async throws -> ServerPasskeyRegistrationOptions {
        let body = try SyncSnapshotCodec.makeEncoder().encode(
            RegistrationOptionsRequest(
                displayName: displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceLabel: configuration.deviceLabel
            )
        )
        let request = try makeRequest(path: ["v1", "auth", "passkey", "register", "options"], method: "POST", body: body)
        let (data, _) = try await perform(request)
        return try decode(ServerPasskeyRegistrationOptions.self, from: data)
    }

    func completeRegistration(_ finish: ServerPasskeyRegistrationFinishRequest) async throws -> ServerPasskeyAuthResult {
        let body = try SyncSnapshotCodec.makeEncoder().encode(finish)
        let request = try makeRequest(path: ["v1", "auth", "passkey", "register", "verify"], method: "POST", body: body)
        let (data, _) = try await perform(request)
        let result = try decode(ServerPasskeyAuthResult.self, from: data)
        guard !result.sessionToken.isEmpty else {
            throw ServerPasskeyClientError.missingSessionToken
        }
        return result
    }

    func beginAuthentication() async throws -> ServerPasskeyAuthenticationOptions {
        let body = try SyncSnapshotCodec.makeEncoder().encode(
            AuthenticationOptionsRequest(deviceLabel: configuration.deviceLabel)
        )
        let request = try makeRequest(path: ["v1", "auth", "passkey", "login", "options"], method: "POST", body: body)
        let (data, _) = try await perform(request)
        return try decode(ServerPasskeyAuthenticationOptions.self, from: data)
    }

    func completeAuthentication(_ finish: ServerPasskeyAuthenticationFinishRequest) async throws -> ServerPasskeyAuthResult {
        let body = try SyncSnapshotCodec.makeEncoder().encode(finish)
        let request = try makeRequest(path: ["v1", "auth", "passkey", "login", "verify"], method: "POST", body: body)
        let (data, _) = try await perform(request)
        let result = try decode(ServerPasskeyAuthResult.self, from: data)
        guard !result.sessionToken.isEmpty else {
            throw ServerPasskeyClientError.missingSessionToken
        }
        return result
    }

    private func makeRequest(path: [String], method: String, body: Data?) throws -> URLRequest {
        let baseURL = try configuration.normalizedBaseURL()
        var url = baseURL
        for component in path {
            url = url.appending(path: component)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.deviceLabel, forHTTPHeaderField: "X-Empty-Device")
        if let authorizationHeader = try configuration.resolvedAuthorizationHeader() {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServerPasskeyClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServerPasskeyClientError.providerError(decodeErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try SyncSnapshotCodec.makeDecoder().decode(type, from: data)
        } catch {
            throw ServerPasskeyClientError.invalidResponse
        }
    }

    private func decodeErrorMessage(from data: Data) -> String? {
        if let decoded = try? SyncSnapshotCodec.makeDecoder().decode([String: String].self, from: data) {
            return decoded["error"] ?? decoded["message"]
        }
        if let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }
}
