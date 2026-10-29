import Foundation
@testable import PimentoCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ name: String, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }

    static func eligibilities() throws -> [EligibilityScheduleInstance] {
        try decode("eligibilities", as: ARMList<EligibilityScheduleInstance>.self).value
    }

    static func assignments() throws -> [AssignmentScheduleInstance] {
        try decode("assignments", as: ARMList<AssignmentScheduleInstance>.self).value
    }

    /// "Now" the fixtures are written against: 2026-10-29T12:00:00Z.
    static let now = AzureDate.parse("2026-10-29T12:00:00Z")!

    static let userOID = "11111111-2222-3333-4444-555555555555"

    static func rows() throws -> [EligibleRole] {
        try RoleMatcher.rows(eligibilities: eligibilities(), assignments: assignments(), now: now)
    }

    static func role(_ scopeName: String, _ roleName: String) throws -> EligibleRole {
        let all = try rows()
        guard let r = all.first(where: { $0.scopeName == scopeName && $0.roleName == roleName }) else {
            throw CocoaError(.keyValueValidation)
        }
        return r
    }
}

/// Unsigned JWT with the given claims (ARM verifies signatures; we only read claims).
func fakeToken(_ claims: [String: Any]) -> String {
    func b64(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    let header = b64(try! JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"]))
    let payload = b64(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).sig"
}

struct StaticTokenProvider: TokenProvider {
    var token = fakeToken(["oid": Fixture.userOID, "name": "Test User", "upn": "test@example.com"])
    func accessToken() async throws -> String { token }
}

/// Records requests and answers from a handler; tracks peak concurrency.
actor RecordingTransport: HTTPTransport {
    typealias Handler = @Sendable (URLRequest) throws -> (Data, Int)

    private(set) var requests: [URLRequest] = []
    private(set) var inFlight = 0
    private(set) var peakInFlight = 0
    let delayNanos: UInt64
    let handler: Handler

    init(delayNanos: UInt64 = 0, handler: @escaping Handler) {
        self.delayNanos = delayNanos
        self.handler = handler
    }

    nonisolated func send(_ request: URLRequest) async throws -> (Data, Int) {
        await begin(request)
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        await end()
        return try handler(request)
    }

    private func begin(_ request: URLRequest) {
        requests.append(request)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
    }

    private func end() { inFlight -= 1 }
}
