import AppKit
import ConfigSSHCore
import Foundation

extension Notification.Name {
    static let backupPassphraseChanged = Notification.Name("ConfigSSH.backupPassphraseChanged")
    static let backupSettingsChanged = Notification.Name("ConfigSSH.backupSettingsChanged")
}

/// The one passphrase that protects every encrypted backup made on this Mac: local snapshots,
/// exports and the iCloud copy. It lives only in this Mac's Keychain, never in iCloud.
enum BackupPassphraseStore {
    #if DEBUG
    /// Debug preview keeps it in memory so the screens can be shown without touching the Keychain.
    nonisolated(unsafe) private static var previewValue: String? = {
        ConfigSSHPaths.isPreviewMode ? ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_PASSPHRASE"] : nil
    }()
    #endif

    static func read() -> String? {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return previewValue }
        #endif
        return (try? CloudSyncSecretStore.read()) ?? nil
    }

    static func save(_ value: String) throws {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { previewValue = value; notify(); return }
        #endif
        try CloudSyncSecretStore.save(value)
        notify()
    }

    static func remove() throws {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { previewValue = nil; notify(); return }
        #endif
        try CloudSyncSecretStore.remove()
        notify()
    }

    private static func notify() {
        NotificationCenter.default.post(name: .backupPassphraseChanged, object: nil)
    }
}

/// Where this Mac's iCloud Drive and the ConfigSSH folder inside it are.
enum ICloudLocation {
    static let folderKey = "snapshotICloudFolder"

    static var driveRoot: URL {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode {
            return ConfigSSHPaths.rootURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("iCloudDrive")
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    static var backupFolder: URL {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return driveRoot.appendingPathComponent("ConfigSSH") }
        #endif
        let chosen = UserDefaults.standard.string(forKey: folderKey) ?? ""
        return chosen.isEmpty ? driveRoot.appendingPathComponent("ConfigSSH") : URL(fileURLWithPath: chosen)
    }

    static var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: driveRoot.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    enum Choice {
        case chosen(String)
        case rejected(String)
    }

    /// Lets the user pick a folder inside iCloud Drive; nil when the panel is cancelled.
    @MainActor
    static func choose() -> Choice? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = driveRoot
        guard panel.runModal() == .OK, let selected = panel.url else { return nil }
        let path = selected.standardizedFileURL.path
        guard path == driveRoot.path || path.hasPrefix(driveRoot.path + "/") else {
            return .rejected("请选择 iCloud Drive 内的文件夹，不能选择其他位置。")
        }
        return .chosen(path)
    }
}

/// The automatic-backup switches, saved in UserDefaults and shared by the settings page and the
/// scheduler. One master switch covers every destination.
enum BackupSettings {
    static let enabledKey = "backupAutoEnabled"
    static let frequencyKey = "backupSnapshotFrequency"
    static let iCloudKey = "backupSyncICloud"
    static let keepKey = "backupKeepAutomatic"
    static let acceptIncompleteKey = "backupAcceptIncompleteCloud"
    static let stateKey = "backupState"
    static let statusKey = "backupLastStatus"

    static var plan: BackupPlan {
        let defaults = UserDefaults.standard
        return BackupPlan(
            isEnabled: defaults.bool(forKey: enabledKey),
            snapshotFrequency: SnapshotFrequency(rawValue: defaults.string(forKey: frequencyKey) ?? "") ?? .daily,
            syncToICloud: defaults.bool(forKey: iCloudKey))
    }

    static var keepAutomatic: Int {
        let stored = UserDefaults.standard.integer(forKey: keepKey)
        return stored == 0 ? AutoSnapshotService.defaultKeep : stored
    }

    static var acceptsIncompleteMirror: Bool { UserDefaults.standard.bool(forKey: acceptIncompleteKey) }

    static func loadState() -> BackupState {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let state = try? JSONDecoder().decode(BackupState.self, from: data) else { return BackupState() }
        return state
    }

    static func save(_ state: BackupState) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey) }
    }

    static var deviceName: String { ProcessInfo.processInfo.hostName }

    @MainActor
    static var appVersion: String { UpdateChecker.currentVersion ?? "" }

    @MainActor
    static func makeEnvironment() -> BackupEnvironment {
        let available = ICloudLocation.isAvailable
        var cloud: BackupCloudTarget?
        if available, let deviceID = try? CloudDeviceIdentity.currentID() {
            cloud = BackupCloudTarget(
                service: CloudConfigSyncService(folder: ICloudLocation.backupFolder, cloudRoot: ICloudLocation.driveRoot),
                deviceID: deviceID, deviceName: deviceName, acceptsIncompleteMirror: acceptsIncompleteMirror)
        }
        return BackupEnvironment(snapshotFolder: ConfigSSHPaths.localSnapshotFolder, keepAutomatic: keepAutomatic,
                                 appVersion: appVersion, deviceName: deviceName, cloud: cloud, iCloudAvailable: available)
    }
}

/// Dates in the app's own language, whatever the system region is: "2026年11月19日 13:04".
enum ChineseDate {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()

    static func short(_ date: Date) -> String { formatter.string(from: date) }

    static func full(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE HH:mm:ss"
        return formatter.string(from: date)
    }
}
