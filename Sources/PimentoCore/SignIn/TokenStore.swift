#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif
import Foundation
#if canImport(Security)
import Security
#endif

/// An account signed in with Pimento's own sign-in. No secrets: the refresh
/// token is stored next to it, the access tokens only in memory.
public struct SignedInAccount: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// `<object id>.<home tenant id>` (MSAL's home account ID).
    public var id: String
    public var objectId: String
    public var homeTenantId: String
    /// The tenant signed in to (the id token's `tid`): where tokens go by default.
    public var tenantId: String
    public var username: String?
    public var name: String?
    /// The app registration the refresh token belongs to.
    public var clientId: String
    public var signedInAt: Date

    public init(objectId: String, homeTenantId: String, tenantId: String, username: String?, name: String?,
                clientId: String, signedInAt: Date) {
        self.id = "\(objectId).\(homeTenantId)"
        self.objectId = objectId
        self.homeTenantId = homeTenantId
        self.tenantId = tenantId
        self.username = username
        self.name = name
        self.clientId = clientId
        self.signedInAt = signedInAt
    }

    /// "Alex Wilber <alex@contoso.example>", or whatever part is known.
    public var displayName: String {
        switch (name, username) {
        case let (n?, u?): "\(n) <\(u)>"
        case let (n?, nil): n
        case let (nil, u?): u
        default: objectId
        }
    }
}

/// Where refresh tokens are kept: the Keychain on macOS, a file elsewhere,
/// memory in tests.
public protocol TokenStore: Sendable {
    /// What the Settings window and `pimento whoami` list (no secrets read).
    func accounts() throws -> [SignedInAccount]
    func refreshToken(for accountId: String) throws -> String?
    /// Adds or replaces the account and its refresh token.
    func save(_ account: SignedInAccount, refreshToken: String) throws
    /// After a refresh: replaces the account's refresh token with `rotated`
    /// only while the stored one is still `expected` (compare and swap).
    /// Never adds an account, so one signed out meanwhile (by this process or
    /// another) stays signed out. Returns whether it replaced the token.
    func replaceRefreshToken(_ accountId: String, expected: String, with rotated: String) throws -> Bool
    func remove(_ accountId: String) throws
    /// Removes every account (Sign Out All), also ones `accounts()` cannot read.
    func removeAll() throws
    /// For Settings and `--help`: "Keychain", "~/.config/pimento/tokens.json".
    var label: String { get }
}

public extension TokenStore {
    func removeAll() throws {
        for account in try accounts() { try remove(account.id) }
    }
}


/// Keeps everything in memory (tests, previews).
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (SignedInAccount, String)] = [:]

    public init() {}

    public var label: String { "memory" }

    public func accounts() throws -> [SignedInAccount] {
        lock.withLock { entries.values.map(\.0).sorted { $0.signedInAt > $1.signedInAt } }
    }

    public func refreshToken(for accountId: String) throws -> String? { lock.withLock { entries[accountId]?.1 } }

    public func save(_ account: SignedInAccount, refreshToken: String) throws {
        lock.withLock { entries[account.id] = (account, refreshToken) }
    }

    public func replaceRefreshToken(_ accountId: String, expected: String, with rotated: String) throws -> Bool {
        lock.withLock {
            guard let entry = entries[accountId], entry.1 == expected else { return false }
            entries[accountId] = (entry.0, rotated)
            return true
        }
    }

    public func remove(_ accountId: String) throws { _ = lock.withLock { entries.removeValue(forKey: accountId) } }
}

/// `~/.config/pimento/tokens.json` (mode 600, folder 700): the store for
/// platforms without a Keychain, or with `PIMENTO_TOKEN_STORE=file`. Less
/// secure than the Keychain: anything running as you can read it.
public struct FileTokenStore: TokenStore {
    public static let fileVariable = "PIMENTO_TOKEN_FILE"

    public let url: URL

    public init(url: URL) { self.url = url }

    public var label: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    /// `$XDG_CONFIG_HOME/pimento`, else `~/.config/pimento` (macOS, Linux);
    /// `%APPDATA%\Pimento` on Windows.
    public static func configDirectory(
        environment: [String: String], home: String = NSHomeDirectory(), platform: HostPlatform = .current
    ) -> URL {
        let path = platform == .windows
            ? PimentoPaths.dataDirectoryPath(environment: environment, home: home, platform: platform)
            : platform.join(PimentoPaths.xdgConfigHome(environment: environment, home: home, platform: platform), "pimento")
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The default file as help texts show it, with how it is protected.
    public static func displayLocation(platform: HostPlatform = .current) -> String {
        platform == .windows
            ? PimentoPaths.displayFile("tokens.json", platform: platform) + ", in your user profile"
            : "~/.config/pimento/tokens.json, mode 600"
    }

    public static func location(
        environment: [String: String], home: String = NSHomeDirectory(), platform: HostPlatform = .current
    ) -> URL {
        if let custom = PimentoPaths.nonEmpty(environment[fileVariable]) {
            return URL(fileURLWithPath: PimentoPaths.expandTilde(custom, home: home, platform: platform))
        }
        return configDirectory(environment: environment, home: home, platform: platform).appendingPathComponent("tokens.json")
    }

    struct Entry: Codable {
        var account: SignedInAccount
        var refreshToken: String
    }

    struct File: Codable {
        var version = 1
        var accounts: [Entry] = []
    }

    func read() throws -> File {
        guard FileManager.default.fileExists(atPath: url.path) else { return File() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(File.self, from: Data(contentsOf: url))
        } catch {
            throw SignInError.storage("\(label): \(error.localizedDescription)")
        }
    }

    func write(_ file: File) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do { try PrivateFile.write(try encoder.encode(file), to: url) } catch {
            throw SignInError.storage("\(label): \(error.localizedDescription)")
        }
    }

    public func accounts() throws -> [SignedInAccount] {
        try read().accounts.map(\.account).sorted { $0.signedInAt > $1.signedInAt }
    }

    public func refreshToken(for accountId: String) throws -> String? {
        try read().accounts.first { $0.account.id == accountId }?.refreshToken
    }

    /// Runs a read-modify-write of the file holding `tokens.json.lock`, so
    /// the app and the CLI saving at the same time do not lose an account.
    func locked<T>(_ body: () throws -> T) throws -> T {
        let lock: FileLock
        do { lock = try FileLock(url: FileLock.lockURL(for: url)) } catch {
            throw SignInError.storage("\(label): \(error.localizedDescription)")
        }
        defer { lock.unlock() }
        return try body()
    }

    public func save(_ account: SignedInAccount, refreshToken: String) throws {
        try locked {
            var file = try read()
            file.accounts.removeAll { $0.account.id == account.id }
            file.accounts.append(Entry(account: account, refreshToken: refreshToken))
            try write(file)
        }
    }

    /// Under the file lock: another process signing out cannot be undone.
    public func replaceRefreshToken(_ accountId: String, expected: String, with rotated: String) throws -> Bool {
        try locked {
            var file = try read()
            guard let i = file.accounts.firstIndex(where: { $0.account.id == accountId }),
                  file.accounts[i].refreshToken == expected else { return false }
            file.accounts[i].refreshToken = rotated
            try write(file)
            return true
        }
    }

    public func remove(_ accountId: String) throws {
        try locked { try removeUnlocked(accountId) }
    }

    private func removeUnlocked(_ accountId: String) throws {
        var file = try read()
        let before = file.accounts.count
        file.accounts.removeAll { $0.account.id == accountId }
        guard file.accounts.count != before else { return }
        if file.accounts.isEmpty {
            // Signing out must not report success while the refresh token is still on disk.
            do { try FileManager.default.removeItem(at: url) } catch {
                throw SignInError.storage("\(label): \(error.localizedDescription)")
            }
        } else {
            try write(file)
        }
    }
}

/// Writes files only you can read: folder 700, file 600 from creation (a
/// temporary file opened with mode 600, then renamed over the target). On
/// Windows there are no POSIX modes: the file is written atomically into the
/// folder, which is in your user profile (`%APPDATA%`) and inherits its ACL.
enum PrivateFile {
    /// Creates `dir` (700 on POSIX) when it does not exist yet.
    static func createDirectory(_ dir: URL) throws {
        guard !FileManager.default.fileExists(atPath: dir.path) else { return }
        #if os(Windows)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #else
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #endif
    }

    static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try createDirectory(dir)
        #if os(Windows)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        try data.write(to: temp, options: .withoutOverwriting)
        do { try replace(url, with: temp) } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        #else
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(8))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temp.path]) }
        let ok = data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = Foundation.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            // On the descriptor, not by path after the rename (the name could be swapped meanwhile).
            _ = fchmod(fd, 0o600)
            _ = fsync(fd)
            return true
        }
        _ = close(fd)
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        #endif
    }

    #if os(Windows)
    /// How often a replace is tried while another program holds the file.
    static let replaceAttempts = 40

    /// Renames `temp` over `target` (`MoveFileExW`, replacing it, written
    /// through). Antivirus scanners and indexers open a file just written
    /// without letting it be renamed or deleted for a moment, so a sharing
    /// or access violation is retried for about two seconds before it counts.
    /// Foundation's `.atomic` gave up at once ("You don't have permission",
    /// Windows error 32), losing the write.
    static func replace(_ target: URL, with temp: URL) throws {
        func path(_ url: URL) -> String { url.withUnsafeFileSystemRepresentation { String(cString: $0!) } }
        let from = path(temp), to = path(target)
        var attempt = 0
        while true {
            let moved = from.withCString(encodedAs: UTF16.self) { source in
                to.withCString(encodedAs: UTF16.self) { destination in
                    MoveFileExW(source, destination, DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH))
                }
            }
            if moved { return }
            let code = GetLastError()
            let transient = code == DWORD(ERROR_SHARING_VIOLATION) || code == DWORD(ERROR_ACCESS_DENIED)
                || code == DWORD(ERROR_LOCK_VIOLATION)
            attempt += 1
            guard transient, attempt < replaceAttempts else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [
                    NSFilePathErrorKey: target.path,
                    NSLocalizedFailureReasonErrorKey: "Windows error \(code) replacing the file",
                ])
            }
            Sleep(DWORD(min(10 * attempt, 100)))
        }
    }
    #endif
}

#if canImport(Security)
/// Generic password items in the login Keychain, service
/// `io.github.melvin2306.pimento`, one per account: the refresh token is the
/// secret, the account info (no secret) is in the item's generic attribute, so
/// listing accounts reads no secret. Accessible after first unlock, this device
/// only. The app and the CLI share the items; macOS asks once per binary (and
/// again after an update of an ad-hoc signed build) before handing out the secret.
public struct KeychainTokenStore: TokenStore {
    public static let defaultService = "io.github.melvin2306.pimento"

    public let service: String
    let keychain: KeychainItems

    public init(service: String = KeychainTokenStore.defaultService) { self.init(service: service, keychain: SystemKeychain()) }

    /// `keychain`: the Security framework, or a fake in tests (which must
    /// never touch the login keychain).
    init(service: String, keychain: KeychainItems) {
        self.service = service
        self.keychain = keychain
    }

    public var label: String { "Keychain" }

    func query(_ extra: [CFString: Any] = [:]) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        for (k, v) in extra { q[k as String] = v }
        return q
    }

    static func failure(_ status: OSStatus) -> SignInError {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
        return .storage("Keychain: \(text)")
    }

    public func accounts() throws -> [SignedInAccount] {
        var result: CFTypeRef?
        let status = keychain.copyMatching(query([kSecMatchLimit: kSecMatchLimitAll, kSecReturnAttributes: true]) as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw Self.failure(status) }
        let items = (result as? [[String: Any]]) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return items.compactMap { item in
            (item[kSecAttrGeneric as String] as? Data).flatMap { try? decoder.decode(SignedInAccount.self, from: $0) }
        }.sorted { $0.signedInAt > $1.signedInAt }
    }

    public func refreshToken(for accountId: String) throws -> String? {
        var result: CFTypeRef?
        let status = keychain.copyMatching(query([kSecAttrAccount: accountId, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]) as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status) }
        return (result as? Data).map { String(decoding: $0, as: UTF8.self) }
    }

    public func save(_ account: SignedInAccount, refreshToken: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let info = try encoder.encode(account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(refreshToken.utf8),
            kSecAttrGeneric as String: info,
            kSecAttrLabel as String: "\(AppInfo.name) sign-in (\(account.username ?? account.objectId))",
            kSecAttrDescription as String: "\(AppInfo.name) refresh token",
        ]
        let status = keychain.update(query([kSecAttrAccount: account.id]) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Self.failure(status) }
        var add = query([kSecAttrAccount: account.id, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly])
        for (k, v) in attributes { add[k] = v }
        let added = keychain.add(add as CFDictionary)
        guard added == errSecSuccess else { throw Self.failure(added) }
    }

    /// Compares the stored secret, then updates the existing item only
    /// (`SecItemUpdate`, never `SecItemAdd`): an item deleted meanwhile, by
    /// this process or another, is not created again.
    public func replaceRefreshToken(_ accountId: String, expected: String, with rotated: String) throws -> Bool {
        guard try refreshToken(for: accountId) == expected else { return false }
        let status = keychain.update(query([kSecAttrAccount: accountId]) as CFDictionary,
                                     [kSecValueData as String: Data(rotated.utf8)] as CFDictionary)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw Self.failure(status) }
        return true
    }

    public func remove(_ accountId: String) throws {
        let status = keychain.delete(query([kSecAttrAccount: accountId]) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
    }

    /// Deletes every item of the service, whatever its account info: an item
    /// whose info cannot be read (damaged, or from a newer Pimento) is not in
    /// `accounts()`, and would otherwise outlive Sign Out All. Repeated until
    /// none is left, as a delete may remove only the first match.
    public func removeAll() throws {
        for _ in 0..<10_000 {
            let status = keychain.delete(query() as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw Self.failure(status) }
        }
        throw SignInError.storage("Keychain: items of \(service) kept coming back")
    }
}

/// The Security framework calls `KeychainTokenStore` makes.
protocol KeychainItems: Sendable {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
    func add(_ attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

/// The login keychain.
struct SystemKeychain: KeychainItems {
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus { SecItemCopyMatching(query, result) }
    func update(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus { SecItemUpdate(query, attributes) }
    func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}
#endif

public enum TokenStores {
    public static let storeVariable = "PIMENTO_TOKEN_STORE"

    /// The Keychain where there is one, unless `PIMENTO_TOKEN_STORE=file`;
    /// the token file otherwise.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> TokenStore {
        let wantsFile = environment[storeVariable]?.lowercased() == "file"
        #if canImport(Security)
        if !wantsFile { return KeychainTokenStore() }
        #endif
        return FileTokenStore(url: FileTokenStore.location(environment: environment))
    }
}
