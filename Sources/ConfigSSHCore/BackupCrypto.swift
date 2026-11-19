import CryptoKit
import Foundation
import Security

/// What an encrypted backup file holds.
package enum BackupKind: String, Codable, Sendable {
    case snapshot
    case export
}

/// The unencrypted part of a backup file: enough to list it without a passphrase. It is bound
/// into the authentication data, so changing it makes decryption fail.
package struct BackupHeader: Equatable, Sendable {
    package let kind: BackupKind
    package let createdAt: Date
    package let isAutomatic: Bool
    /// False for a snapshot the user chose to keep unencrypted: the same file, readable by anyone
    /// who can open it. Everything else (exports, iCloud) is always encrypted.
    package let isEncrypted: Bool
}

/// AES-GCM backup files (`.cssh`) with a PBKDF2-SHA256 key from a passphrase.
///
/// One envelope format serves local snapshots and exports. Cloud device slots keep their own
/// older envelope (`CloudConfigCrypto`) so files already in iCloud stay readable.
package enum BackupCrypto {
    package static let minimumPassphraseLength = 12
    package static let maximumFileSize = 96 * 1_024 * 1_024
    private static let formatName = "ConfigSSH-backup"

    private struct Envelope: Codable {
        let format: String
        let version: Int
        let kind: BackupKind
        let createdAt: Int
        let isAutomatic: Bool
        /// Absent in files written before unencrypted snapshots existed, which are all encrypted.
        let encrypted: Bool?
        let salt: Data
        let sealed: Data
    }

    package static func passphraseProblem(_ passphrase: String) -> String? {
        passphrase.count < minimumPassphraseLength ? "口令至少需要 \(minimumPassphraseLength) 个字符" : nil
    }

    package static func seal(_ plaintext: Data, kind: BackupKind, passphrase: String,
                             createdAt: Date = Date(), isAutomatic: Bool = false) throws -> Data {
        if let problem = passphraseProblem(passphrase) { throw ConfigEditError.invalid(problem) }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ConfigEditError.io("无法生成加密随机数") }
        let key = try CloudConfigCrypto.deriveKey(passphrase: passphrase, salt: salt)
        let stamp = Int(createdAt.timeIntervalSince1970)
        let sealed = try AES.GCM.seal(plaintext, using: key,
                                      authenticating: authenticatedData(kind: kind, createdAt: stamp, isAutomatic: isAutomatic))
        guard let combined = sealed.combined else { throw ConfigEditError.io("无法生成加密文件") }
        let envelope = Envelope(format: formatName, version: 1, kind: kind, createdAt: stamp,
                                isAutomatic: isAutomatic, encrypted: true, salt: salt, sealed: combined)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Reads the header without a passphrase. Throws when the data is not a ConfigSSH backup.
    package static func header(of data: Data) throws -> BackupHeader {
        let envelope = try decodeEnvelope(data)
        return BackupHeader(kind: envelope.kind, createdAt: Date(timeIntervalSince1970: TimeInterval(envelope.createdAt)),
                            isAutomatic: envelope.isAutomatic, isEncrypted: envelope.encrypted ?? true)
    }

    /// An unencrypted snapshot: the same envelope with the content in the clear. Only local
    /// snapshots may be written this way; exports and the cloud copy never are.
    package static func sealPlain(_ plaintext: Data, createdAt: Date = Date(), isAutomatic: Bool = false) throws -> Data {
        let envelope = Envelope(format: formatName, version: 1, kind: .snapshot, createdAt: Int(createdAt.timeIntervalSince1970),
                                isAutomatic: isAutomatic, encrypted: false, salt: Data(), sealed: plaintext)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    /// Reads an unencrypted snapshot. Refuses an encrypted one rather than returning ciphertext.
    package static func openPlain(_ data: Data) throws -> (header: BackupHeader, plaintext: Data) {
        let envelope = try decodeEnvelope(data, allowPlain: true)
        guard envelope.encrypted == false, envelope.kind == .snapshot else { throw ConfigEditError.invalid("这份备份是加密的，需要口令才能打开") }
        return (BackupHeader(kind: envelope.kind, createdAt: Date(timeIntervalSince1970: TimeInterval(envelope.createdAt)),
                             isAutomatic: envelope.isAutomatic, isEncrypted: false), envelope.sealed)
    }

    /// Decrypts and authenticates. A wrong passphrase and a damaged file look the same, so the
    /// message names both.
    package static func open(_ data: Data, passphrase: String, expectedKind: BackupKind) throws -> (header: BackupHeader, plaintext: Data) {
        let envelope = try decodeEnvelope(data)
        guard envelope.encrypted != false else { throw ConfigEditError.invalid("这份备份没有加密，不需要口令") }
        guard envelope.kind == expectedKind else {
            throw ConfigEditError.invalid(envelope.kind == .export ? "这是导出文件，不是本机快照" : "这是快照文件，不是导出文件")
        }
        let key = try CloudConfigCrypto.deriveKey(passphrase: passphrase, salt: envelope.salt)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let plaintext = try AES.GCM.open(box, using: key,
                                             authenticating: authenticatedData(kind: envelope.kind, createdAt: envelope.createdAt,
                                                                                isAutomatic: envelope.isAutomatic))
            let header = BackupHeader(kind: envelope.kind, createdAt: Date(timeIntervalSince1970: TimeInterval(envelope.createdAt)),
                                      isAutomatic: envelope.isAutomatic, isEncrypted: true)
            return (header, plaintext)
        } catch {
            throw ConfigEditError.unsafe("解密失败：口令不正确，或文件已损坏")
        }
    }

    private static func decodeEnvelope(_ data: Data, allowPlain: Bool = false) throws -> Envelope {
        guard data.count <= maximumFileSize else { throw ConfigEditError.unsafe("备份文件超过大小限制") }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.format == formatName else {
            throw ConfigEditError.invalid("不是 ConfigSSH 的加密备份文件")
        }
        let isPlain = envelope.encrypted == false
        guard envelope.version == 1, isPlain ? (envelope.salt.isEmpty && !envelope.sealed.isEmpty)
                                              : (envelope.salt.count == 16 && envelope.sealed.count >= 28) else {
            throw ConfigEditError.unsafe("备份文件的格式版本不受支持，请升级 ConfigSSH 后再试")
        }
        // A plain snapshot is only ever a snapshot; an export or any other kind that claims to be
        // unencrypted is refused outright.
        guard !isPlain || envelope.kind == .snapshot else { throw ConfigEditError.unsafe("导出文件必须加密") }
        return envelope
    }

    private static func authenticatedData(kind: BackupKind, createdAt: Int, isAutomatic: Bool) -> Data {
        Data("\(formatName)-v1|\(kind.rawValue)|\(createdAt)|\(isAutomatic ? 1 : 0)".utf8)
    }
}
