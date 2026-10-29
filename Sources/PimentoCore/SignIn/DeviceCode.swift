import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The device authorization response (RFC 8628 §3.2): what the user types where.
public struct DeviceCodeChallenge: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Int
    /// Seconds between polls.
    public let interval: Int
    /// Microsoft's own sentence ("To sign in, use a web browser to open …").
    public let message: String?

    public init(deviceCode: String, userCode: String, verificationURL: URL, expiresIn: Int, interval: Int, message: String?) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.expiresIn = expiresIn
        self.interval = interval
        self.message = message
    }

    static func parse(_ data: Data) -> DeviceCodeChallenge? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let device = o["device_code"] as? String, let user = o["user_code"] as? String,
              let uri = (o["verification_uri"] as? String) ?? (o["verification_url"] as? String),
              let url = URL(string: uri), url.scheme == "https" else { return nil }
        func int(_ key: String) -> Int? { (o[key] as? Int) ?? (o[key] as? String).flatMap(Int.init) }
        return DeviceCodeChallenge(deviceCode: device, userCode: user, verificationURL: url,
                                   expiresIn: int("expires_in") ?? 900, interval: max(1, int("interval") ?? 5),
                                   message: o["message"] as? String)
    }
}

/// The polling rules of RFC 8628 §3.5, as a value: feed it each token
/// endpoint answer, it says whether to wait (and how long) or stop.
public struct DeviceCodePoller: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case wait(seconds: Int)
        case done(TokenResponse)
        case failed(SignInError)
    }

    public private(set) var interval: Int
    public let deadline: Date

    public init(challenge: DeviceCodeChallenge, startedAt: Date) {
        interval = max(1, challenge.interval)
        deadline = startedAt.addingTimeInterval(TimeInterval(challenge.expiresIn))
    }

    /// The next step after an answer `(data, status)` received at `now`.
    public mutating func next(status: Int, data: Data, now: Date) -> Step {
        if status == 200 {
            guard let tokens = TokenResponse.parse(data) else { return .failed(.invalidResponse("no access token")) }
            return .done(tokens)
        }
        guard let info = OAuthErrorInfo.parse(data) else {
            return .failed(.invalidResponse("HTTP \(status) " + String(decoding: data.prefix(200), as: UTF8.self)))
        }
        switch info.error {
        case "authorization_pending":
            return waitOrExpire(now: now)
        case "slow_down":
            // RFC 8628 §3.5: add 5 seconds to this and every later interval.
            interval += 5
            return waitOrExpire(now: now)
        case "expired_token", "code_expired":
            return .failed(.deviceCodeExpired)
        case "authorization_declined", "access_denied":
            return .failed(.declined)
        case "bad_verification_code":
            return .failed(.invalidResponse("the device code was not recognised"))
        default:
            return .failed(info.needsInteraction ? .interactionRequired(info) : .oauth(info))
        }
    }

    /// The first wait, before any poll.
    public var firstWait: Step { .wait(seconds: interval) }

    private func waitOrExpire(now: Date) -> Step {
        now >= deadline ? .failed(.deviceCodeExpired) : .wait(seconds: interval)
    }
}
