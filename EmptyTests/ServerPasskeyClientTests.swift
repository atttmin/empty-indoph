//
//  ServerPasskeyClientTests.swift
//  EmptyTests
//

import Foundation
import Testing
@testable import Empty

struct ServerPasskeyClientTests {
    @Test func beginRegistrationUsesExpectedContract() async throws {
        let session = makePasskeyStubSession { request in
            #expect(request.url?.absoluteString == "https://sync.example.com/v1/auth/passkey/register/options")
            #expect(request.httpMethod == "POST")
            let body = try #require(passkeyRequestBody(from: request))
            let decoded = try SyncSnapshotCodec.makeDecoder().decode([String: String].self, from: body)
            #expect(decoded["displayName"] == "Davi")
            #expect(decoded["deviceLabel"] == "Reader")
            return PasskeyStubURLProtocol.response(
                url: request.url!,
                statusCode: 200,
                headers: [:],
                body: """
                {"relyingPartyID":"sync.example.com","challenge":"Y2hhbGxlbmdl","userID":"dXNlci0x","userName":"davi","userDisplayName":"Davi"}
                """.data(using: .utf8)!
            )
        }

        let client = ServerPasskeyClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                bearerToken: "",
                deviceLabel: "Reader"
            ),
            session: session
        )

        let options = try await client.beginRegistration(displayName: "Davi")
        #expect(options.userName == "davi")
        #expect(options.relyingPartyID == "sync.example.com")
    }

    @Test func authenticationAndSessionUseExpectedContracts() async throws {
        let session = makePasskeyStubSession { request in
            if request.url?.absoluteString == "https://sync.example.com/v1/auth/passkey/login/options" {
                #expect(request.httpMethod == "POST")
                return PasskeyStubURLProtocol.response(
                    url: request.url!,
                    statusCode: 200,
                    headers: [:],
                    body: """
                    {"relyingPartyID":"sync.example.com","challenge":"Y2hhbGxlbmdl","allowedCredentialIDs":["Y3JlZC0x"]}
                    """.data(using: .utf8)!
                )
            }
            if request.url?.absoluteString == "https://sync.example.com/v1/auth/passkey/login/verify" {
                #expect(request.httpMethod == "POST")
                let body = try #require(passkeyRequestBody(from: request))
                let decoded = try SyncSnapshotCodec.makeDecoder().decode(ServerPasskeyAuthenticationFinishRequest.self, from: body)
                #expect(decoded.credentialID == "cred-1")
                return PasskeyStubURLProtocol.response(
                    url: request.url!,
                    statusCode: 200,
                    headers: [:],
                    body: """
                    {"sessionToken":"session-1","session":{"accountID":"user-1","displayName":"Davi","email":"davi@example.com","issuedAt":"1970-01-01T00:02:03Z","expiresAt":"1970-01-01T00:03:20Z"}}
                    """.data(using: .utf8)!
                )
            }
            if request.url?.absoluteString == "https://sync.example.com/v1/auth/session" {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-1")
                if request.httpMethod == "GET" {
                    return PasskeyStubURLProtocol.response(
                        url: request.url!,
                        statusCode: 200,
                        headers: [:],
                        body: """
                        {"accountID":"user-1","displayName":"Davi","email":"davi@example.com","issuedAt":"1970-01-01T00:02:03Z","expiresAt":"1970-01-01T00:03:20Z"}
                        """.data(using: .utf8)!
                    )
                }
                #expect(request.httpMethod == "DELETE")
                return PasskeyStubURLProtocol.response(url: request.url!, statusCode: 204, headers: [:], body: Data())
            }
            Issue.record("Unexpected request: \(request.url?.absoluteString ?? "nil")")
            throw URLError(.badURL)
        }

        let anonymousClient = ServerPasskeyClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .none,
                bearerToken: "",
                deviceLabel: "Reader"
            ),
            session: session
        )
        let options = try await anonymousClient.beginAuthentication()
        #expect(options.allowedCredentialIDs?.first == "Y3JlZC0x")
        let result = try await anonymousClient.completeAuthentication(
            .init(
                credentialID: "cred-1",
                clientDataJSON: "client-json",
                authenticatorData: "auth-data",
                signature: "signature",
                userID: "user"
            )
        )
        #expect(result.sessionToken == "session-1")
        #expect(result.session.displayName == "Davi")

        let signedInClient = ServerPasskeyClient(
            configuration: .init(
                baseURLString: "https://sync.example.com",
                namespace: "reader-main",
                authMode: .passkeySession,
                bearerToken: "session-1",
                deviceLabel: "Reader"
            ),
            session: session
        )
        let fetched = try await signedInClient.fetchSession()
        #expect(fetched?.email == "davi@example.com")
        try await signedInClient.signOut()
    }
}

private func makePasskeyStubSession(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    PasskeyStubURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PasskeyStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class PasskeyStubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private func passkeyRequestBody(from request: URLRequest) -> Data? {
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
