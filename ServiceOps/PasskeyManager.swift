import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class PasskeyManager: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    func register(baseURL: String, accessToken: String) async throws -> PasskeyRecord {
        let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: accessToken)
        let envelope = try await client.passkeyRegistrationOptions()
        guard let challenge = Data(base64URLEncoded: envelope.options.challenge) else {
            throw ServiceOpsAPIError.decoding("ServiceOps returned an invalid passkey challenge.")
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: envelope.options.rp.id
        )
        guard let userID = Data(base64URLEncoded: envelope.options.user.id) else {
            throw ServiceOpsAPIError.decoding("ServiceOps returned an invalid passkey user identifier.")
        }
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: envelope.options.user.name,
            userID: userID
        )
        let authorization = try await perform(request)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject else {
            throw ServiceOpsAPIError.decoding("The device did not return a passkey registration credential.")
        }
        return try await client.completePasskeyRegistration(
            challengeId: envelope.challengeId,
            credential: PasskeyCredentialPayload(
                id: credential.credentialID.base64URLEncodedString,
                rawId: credential.credentialID.base64URLEncodedString,
                response: PasskeyCredentialResponse(
                    clientDataJSON: credential.rawClientDataJSON.base64URLEncodedString,
                    attestationObject: attestation.base64URLEncodedString,
                    authenticatorData: nil, signature: nil, userHandle: nil
                )
            ),
            name: UIDevice.current.name + " passkey"
        )
    }

    func authenticate(baseURL: String) async throws -> MobileAuthResponse {
        let client = try ServiceOpsAPIClient(baseURLString: baseURL, token: "")
        let envelope = try await client.passkeyAuthenticationOptions()
        guard let challenge = Data(base64URLEncoded: envelope.options.challenge) else {
            throw ServiceOpsAPIError.decoding("ServiceOps returned an invalid passkey challenge.")
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: envelope.options.rpId
        )
        let authorization = try await perform(provider.createCredentialAssertionRequest(challenge: challenge))
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw ServiceOpsAPIError.decoding("The device did not return a passkey assertion.")
        }
        return try await client.completePasskeyAuthentication(
            challengeId: envelope.challengeId,
            credential: PasskeyCredentialPayload(
                id: credential.credentialID.base64URLEncodedString,
                rawId: credential.credentialID.base64URLEncodedString,
                response: PasskeyCredentialResponse(
                    clientDataJSON: credential.rawClientDataJSON.base64URLEncodedString,
                    attestationObject: nil,
                    authenticatorData: credential.rawAuthenticatorData.base64URLEncodedString,
                    signature: credential.signature.base64URLEncodedString,
                    userHandle: credential.userID.base64URLEncodedString
                )
            )
        )
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
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
        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = windowScenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }

        if let windowScene = windowScenes.first {
            return ASPresentationAnchor(windowScene: windowScene)
        }

        preconditionFailure("Passkey authorization requires an active window scene.")
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        self.init(base64Encoded: text)
    }

    var base64URLEncodedString: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
