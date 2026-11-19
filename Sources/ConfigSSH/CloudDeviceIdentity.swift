import ConfigSSHCore
import Foundation
import Security

enum CloudDeviceIdentity {
    private static let service = "cn.wuewa.configssh.cloud-device-id"

    /// The ID is not secret, so besides the Keychain it is mirrored in preferences and cached for
    /// the run. Reading data from the Keychain asks the user for access, and a backup pass must not
    /// trigger that prompt every time it needs to know which device it is.
    private static let mirrorKey = "cloudDeviceIDMirror"
    nonisolated(unsafe) private static var cached: UUID?
    private static let lock = NSLock()

    static func currentID() throws -> UUID {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return UUID(uuidString: "00000000-0000-4000-8000-000000000001")! }
        #endif
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        if let text = UserDefaults.standard.string(forKey: mirrorKey), let mirrored = UUID(uuidString: text) {
            cached = mirrored
            return mirrored
        }
        let id = try keychainID()
        UserDefaults.standard.set(id.uuidString, forKey: mirrorKey)
        cached = id
        return id
    }

    private static func keychainID() throws -> UUID {
        if let existing = try read() { return existing }
        let generated = UUID()
        let data = Data(generated.uuidString.utf8)
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "local-installation",
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: data
        ] as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try read() { return existing }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法在本机钥匙串保存设备标识"])
        }
        return generated
    }

    private static func read() throws -> UUID? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: "local-installation",
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              let id = UUID(uuidString: value) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法读取本机云端设备标识"])
        }
        return id
    }
}

enum CloudSyncSecretStore {
    private static let service = "cn.wuewa.configssh.cloud-passphrase"
    private static let account = "shared-config-passphrase"

    /// Whether a passphrase is saved. Asking only for attributes never shows the access prompt,
    /// which reading the secret itself can.
    static func exists() -> Bool {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    static func read() throws -> String? {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return nil }
        #endif
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法读取本机钥匙串中的加密口令"])
        }
        return value
    }

    static func save(_ value: String) throws {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return }
        #endif
        let data = Data(value.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let existing = SecItemCopyMatching(query as CFDictionary, nil)
        let status: OSStatus
        if existing == errSecItemNotFound {
            var attributes = query
            attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecValueData] = data
            status = SecItemAdd(attributes as CFDictionary, nil)
        } else if existing == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        } else {
            status = existing
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法保存加密口令到本机钥匙串"])
        }
    }

    static func remove() throws {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return }
        #endif
        let status = SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法从本机钥匙串移除加密口令"])
        }
    }
}
