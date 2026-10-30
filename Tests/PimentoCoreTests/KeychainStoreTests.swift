#if canImport(Security)
import Foundation
import Security
import Testing
@testable import PimentoCore

/// Generic password items in memory, matched on class, service and account
/// the way `SecItem*` matches them: the token store's tests never touch the
/// login keychain.
final class FakeKeychain: KeychainItems, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [[String: Any]] = []
    /// Like some keychains: a delete removes only the first match.
    let deletesOneAtATime: Bool

    init(deletesOneAtATime: Bool = false) { self.deletesOneAtATime = deletesOneAtATime }

    var count: Int { lock.withLock { items.count } }

    func insert(_ item: [String: Any]) { lock.withLock { items.append(item) } }

    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        for key in [kSecClass, kSecAttrService, kSecAttrAccount] as [CFString] {
            guard let wanted = query[key as String] else { continue }
            guard let have = item[key as String], (have as AnyObject).isEqual(wanted) else { return false }
        }
        return true
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        let q = query as! [String: Any]
        let found = lock.withLock { items.filter { matches($0, q) } }
        guard !found.isEmpty else { return errSecItemNotFound }
        if q[kSecReturnData as String] as? Bool == true {
            result?.pointee = found[0][kSecValueData as String] as CFTypeRef?
        } else {
            let attributes = found.map { $0.filter { $0.key != kSecValueData as String } }
            result?.pointee = (q[kSecMatchLimit as String] as AnyObject?)?.isEqual(kSecMatchLimitAll) == true
                ? attributes as CFArray : attributes[0] as CFDictionary
        }
        return errSecSuccess
    }

    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
        let q = query as! [String: Any], a = attributes as! [String: Any]
        return lock.withLock {
            var hit = false
            for i in items.indices where matches(items[i], q) {
                items[i].merge(a) { $1 }
                hit = true
            }
            return hit ? errSecSuccess : errSecItemNotFound
        }
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        insert(attributes as! [String: Any])
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        let q = query as! [String: Any]
        return lock.withLock {
            guard let first = items.firstIndex(where: { matches($0, q) }) else { return errSecItemNotFound }
            if deletesOneAtATime { items.remove(at: first) } else { items.removeAll { matches($0, q) } }
            return errSecSuccess
        }
    }
}

@Suite("Sign-in: Keychain store (fake keychain)")
struct KeychainStoreTests {
    static let service = "io.github.example.pimento-tests"

    func account(_ n: Int) -> SignedInAccount {
        SignedInAccount(objectId: "o\(n)", homeTenantId: "t", tenantId: "t", username: "user\(n)@example.com", name: nil,
                        clientId: testClientId, signedInAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)))
    }

    /// An item of the service whose account info cannot be decoded.
    func damaged(_ account: String, generic: Data?) -> [String: Any] {
        var item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data("rt".utf8)]
        item[kSecAttrGeneric as String] = generic
        return item
    }

    @Test func savesListsAndRemovesThroughTheKeychainCalls() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(service: Self.service, keychain: keychain)
        try store.save(account(1), refreshToken: "rt-1")
        try store.save(account(2), refreshToken: "rt-2")
        try store.save(account(1), refreshToken: "rt-1b")
        #expect(keychain.count == 2)
        #expect(try store.accounts().map(\.id) == [account(2).id, account(1).id])
        #expect(try store.refreshToken(for: account(1).id) == "rt-1b")
        try store.remove(account(2).id)
        #expect(try store.accounts().map(\.id) == [account(1).id])
    }

    @Test(arguments: [false, true])
    func signOutAllRemovesItemsWhoseInfoCannotBeRead(deletesOneAtATime: Bool) throws {
        let keychain = FakeKeychain(deletesOneAtATime: deletesOneAtATime)
        let store = KeychainTokenStore(service: Self.service, keychain: keychain)
        try store.save(account(1), refreshToken: "rt-1")
        keychain.insert(damaged("garbled", generic: Data("not json".utf8)))
        keychain.insert(damaged("no-info", generic: nil))
        // Another app's item stays.
        keychain.insert([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "other.service",
                         kSecAttrAccount as String: "x", kSecValueData as String: Data("secret".utf8)])
        // Only the readable one is listed…
        #expect(try store.accounts().map(\.id) == [account(1).id])
        // …but Sign Out All removes all three.
        try store.removeAll()
        #expect(try store.accounts().isEmpty)
        #expect(keychain.count == 1)
        #expect(try store.refreshToken(for: "garbled") == nil)
        #expect(try KeychainTokenStore(service: "other.service", keychain: keychain).refreshToken(for: "x") == "secret")
        // Nothing left: still fine.
        try store.removeAll()
    }

    @Test func theBrokersSignOutAllUsesIt() async throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(service: Self.service, keychain: keychain)
        keychain.insert(damaged("garbled", generic: Data("{}".utf8)))
        let broker = TokenBroker(store: store, transport: RecordingTransport { _ in (Data(), 500) })
        try await broker.signOutAll()
        #expect(keychain.count == 0)
    }
}
#endif
