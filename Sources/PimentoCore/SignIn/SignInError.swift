import Foundation

/// Why Pimento's own sign-in (or a token for it) failed.
public enum SignInError: Error, Equatable, LocalizedError {
    /// No account is signed in (or the chosen one is gone).
    case notSignedIn
    /// Pimento sign-in needs an app registration's client ID.
    case missingClientId
    case invalidClientId(String)
    /// The token endpoint wants the user to sign in again (expired or revoked
    /// session, MFA, Conditional Access). `claims` goes with the next sign-in.
    case interactionRequired(OAuthErrorInfo)
    /// Any other error from the identity platform.
    case oauth(OAuthErrorInfo)
    case network(String)
    case invalidResponse(String)
    /// The redirect carried another `state`, or the id token another `nonce`.
    case stateMismatch
    case nonceMismatch
    case timedOut
    case cancelled
    /// The device code expired before the user finished.
    case deviceCodeExpired
    case declined
    /// The loopback listener could not start.
    case loopback(String)
    /// The Keychain or the token file could not be read or written.
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            "Not signed in with Pimento. Sign in under Settings › Account, or run `pimento login`."
        case .missingClientId:
            "Pimento sign-in needs the client ID of your app registration. Set it under Settings › Account, "
                + "with --client-id or $\(AuthSourceResolver.clientIdVariable) (README › Pimento sign-in)."
        case .invalidClientId(let v):
            "“\(v)” is not a client ID. Use the Application (client) ID GUID of the app registration."
        case .interactionRequired(let info):
            info.message.hasSuffix(".") || info.message.hasSuffix(")") ? "\(info.message) Sign in again." : "\(info.message). Sign in again."
        case .oauth(let info): info.message
        case .network(let m): "Could not reach \(MicrosoftIdentity.host): \(m)"
        case .invalidResponse(let m): "Unexpected answer from \(MicrosoftIdentity.host): \(m)"
        case .stateMismatch: "The sign-in answer did not match the request (state). Sign in again."
        case .nonceMismatch: "The sign-in answer did not match the request (nonce). Sign in again."
        case .timedOut: "Sign-in timed out. Try again."
        case .cancelled: "Sign-in was cancelled."
        case .deviceCodeExpired: "The code expired before sign-in finished. Run it again."
        case .declined: "Sign-in was declined."
        case .loopback(let m):
            "Could not listen on localhost for the sign-in answer: \(m). Use the device code instead: "
                + "`pimento login --device-code`, or Sign In with Code… in the app."
        case .storage(let m): "Could not access the saved sign-in: \(m)"
        }
    }

    /// Signing in again is the likely fix.
    public var needsLogin: Bool {
        switch self {
        case .notSignedIn, .interactionRequired, .deviceCodeExpired, .stateMismatch, .nonceMismatch, .timedOut: true
        case .oauth(let info): info.needsInteraction
        default: false
        }
    }

    /// A claims challenge to pass to the next interactive sign-in.
    public var claims: String? {
        if case .interactionRequired(let info) = self { return info.claims }
        return nil
    }

    /// Maps a token endpoint error response.
    static func from(status: Int, data: Data) -> SignInError {
        guard let info = OAuthErrorInfo.parse(data) else {
            return .invalidResponse("HTTP \(status) " + String(decoding: data.prefix(200), as: UTF8.self))
        }
        return info.needsInteraction ? .interactionRequired(info) : .oauth(info)
    }
}
