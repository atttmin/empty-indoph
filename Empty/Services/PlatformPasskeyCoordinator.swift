//
//  PlatformPasskeyCoordinator.swift
//  Empty
//

import AuthenticationServices
import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

@MainActor
final class PlatformPasskeyCoordinator: NSObject {
    func register(options: ServerPasskeyRegistrationOptions) async throws -> ServerPasskeyRegistrationFinishRequest {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingPartyID)
        let request = try provider.createCredentialRegistrationRequest(
            challenge: WebAuthnBase64URL.decode(options.challenge, error: ServerPasskeyClientError.invalidChallenge),
            name: options.userName,
            userID: WebAuthnBase64URL.decode(options.userID, error: ServerPasskeyClientError.invalidUserID)
        )
        let authorization = try await perform(request: request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestationObject = credential.rawAttestationObject
        else {
            throw ASAuthorizationError(.failed)
        }
        return ServerPasskeyRegistrationFinishRequest(
            credentialID: WebAuthnBase64URL.encode(credential.credentialID),
            clientDataJSON: WebAuthnBase64URL.encode(credential.rawClientDataJSON),
            attestationObject: WebAuthnBase64URL.encode(attestationObject)
        )
    }

    func authenticate(options: ServerPasskeyAuthenticationOptions) async throws -> ServerPasskeyAuthenticationFinishRequest {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: options.relyingPartyID)
        let request = try provider.createCredentialAssertionRequest(
            challenge: WebAuthnBase64URL.decode(options.challenge, error: ServerPasskeyClientError.invalidChallenge)
        )
        let authorization = try await perform(request: request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw ASAuthorizationError(.failed)
        }
        return ServerPasskeyAuthenticationFinishRequest(
            credentialID: WebAuthnBase64URL.encode(credential.credentialID),
            clientDataJSON: WebAuthnBase64URL.encode(credential.rawClientDataJSON),
            authenticatorData: WebAuthnBase64URL.encode(credential.rawAuthenticatorData),
            signature: WebAuthnBase64URL.encode(credential.signature),
            userID: credential.userID.map(WebAuthnBase64URL.encode)
        )
    }

    private func perform(request: ASAuthorizationRequest) async throws -> ASAuthorization {
        let adapter = AuthorizationDelegateAdapter()
        return try await adapter.perform(request: request)
    }
}

@MainActor
private final class AuthorizationDelegateAdapter: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    func perform(request: ASAuthorizationRequest) async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        continuation?.resume(returning: authorization)
        continuation = nil
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        #if os(iOS)
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
           let window = scene.windows.first(where: { $0.isKeyWindow }) {
            return window
        }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return UIWindow(windowScene: scene)
        }
        return UIWindow(frame: UIScreen.main.bounds)
        #elseif os(macOS)
        return NSApp.keyWindow ?? NSWindow()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

private enum WebAuthnBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ value: String, error: ServerPasskeyClientError) throws -> Data {
        var padded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder != 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: padded) else {
            throw error
        }
        return data
    }
}
