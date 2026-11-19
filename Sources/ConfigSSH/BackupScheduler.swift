import ConfigSSHCore
import Foundation
import Observation

/// Keeps backups current while ConfigSSH runs.
///
/// Every few seconds it asks the file system (`lstat` only) whether any config file changed; a
/// change starts a short debounce, after which `BackupCoordinator` decides what is due: the daily
/// encrypted snapshot and/or an upload to iCloud. It also checks once an hour and whenever the
/// settings or the passphrase change. Nothing here runs `Match exec` or `ssh -G`.
@MainActor
@Observable
final class BackupScheduler {
    static let shared = BackupScheduler()

    private(set) var isRunning = false
    private(set) var state = BackupSettings.loadState()
    private(set) var statusMessage = UserDefaults.standard.string(forKey: BackupSettings.statusKey) ?? ""
    private(set) var problems: [String] = []
    private(set) var notes: [String] = []
    private(set) var hasPassphrase = BackupPassphraseStore.isSet

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var signature: [String]?
    @ObservationIgnored private var sources: [URL] = []
    @ObservationIgnored private var lastChangeAt: Date?
    @ObservationIgnored private var lastFullCheck = Date.distantPast
    @ObservationIgnored private var recheckAt: Date?
    @ObservationIgnored private var runAgain = false

    func start() {
        guard timer == nil else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .backupPassphraseChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.passphraseChanged() }
        })
        observers.append(center.addObserver(forName: .backupSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.requestRun() }
        })
        observers.append(center.addObserver(forName: .configSSHConfigChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.configChanged() }
        })
        let timer = Timer(timeInterval: 4, repeats: true) { _ in Task { @MainActor in BackupScheduler.shared.tick() } }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    // MARK: Triggers

    private func passphraseChanged() {
        hasPassphrase = BackupPassphraseStore.isSet
        requestRun()
    }

    private func configChanged() {
        lastChangeAt = Date()
        requestRun()
    }

    private func requestRun() {
        lastFullCheck = .distantPast
        tick()
    }

    private func tick() {
        guard BackupSettings.plan.isEnabled else { return }
        let now = Date()
        let current = ConfigStatSignature.make(rootURL: ConfigSSHPaths.rootURL, sources: sources)
        var due = false
        if let signature, signature != current { lastChangeAt = now; due = true }
        if signature == nil { due = true }
        signature = current
        if now.timeIntervalSince(lastFullCheck) >= 3600 { due = true }
        if let recheckAt, now >= recheckAt { due = true }
        if due { run() }
    }

    // MARK: Runs

    private func run() {
        guard !isRunning else { runAgain = true; return }
        let plan = BackupSettings.plan
        guard plan.isEnabled else { return }
        isRunning = true
        lastFullCheck = Date()
        recheckAt = nil
        let environment = BackupSettings.makeEnvironment()
        // Read only now that a pass really needs it (cached after the first read).
        let secret = BackupPassphraseStore.read()
        let before = state
        let changedAt = lastChangeAt
        let root = ConfigSSHPaths.rootURL
        Task {
            let outcome = await Task.detached(priority: .utility) { () -> (BackupState, BackupReport, [URL]) in
                let scan = ConfigReader(rootURL: root).scan()
                let result = BackupCoordinator.run(plan: plan, scan: scan, passphrase: secret, environment: environment,
                                                   state: before, lastChangeAt: changedAt)
                return (result.state, result.report, scan.sources.map(\.url))
            }.value
            finish(state: outcome.0, report: outcome.1, sources: outcome.2)
        }
    }

    /// "立即备份": a manual encrypted snapshot, plus an iCloud upload when sync is on.
    func backupNow() {
        guard !isRunning else { return }
        let secret = BackupPassphraseStore.read()
        let encrypt = BackupSettings.plan.encryptSnapshots
        if secret == nil && encrypt {
            problems = ["请先设置备份口令"]
            return
        }
        isRunning = true
        let environment = BackupSettings.makeEnvironment()
        let before = state
        let includeCloud = BackupSettings.plan.syncToICloud
        let root = ConfigSSHPaths.rootURL
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (BackupState, BackupReport, [URL]) in
                let scan = ConfigReader(rootURL: root).scan()
                let result = BackupCoordinator.backupNow(scan: scan, passphrase: secret, encryptSnapshots: encrypt,
                                                         environment: environment, state: before, includeCloud: includeCloud)
                return (result.state, result.report, scan.sources.map(\.url))
            }.value
            finish(state: outcome.0, report: outcome.1, sources: outcome.2)
            NotificationCenter.default.post(name: .backupSnapshotsChanged, object: nil)
        }
    }

    private func finish(state newState: BackupState, report: BackupReport, sources newSources: [URL]) {
        state = newState
        BackupSettings.save(newState)
        sources = newSources
        problems = report.errors
        notes = report.notes
        recheckAt = report.recheckAt
        isRunning = false
        if report.didSomething {
            var parts: [String] = []
            if report.snapshotURL != nil { parts.append(BackupSettings.plan.encryptSnapshots ? "已创建加密快照" : "已创建快照（未加密）") }
            if let count = report.pushedFileCount { parts.append("已同步 \(count) 个文件到 iCloud") }
            let message = ChineseDate.short(Date()) + " · " + parts.joined(separator: "，")
            statusMessage = message
            UserDefaults.standard.set(message, forKey: BackupSettings.statusKey)
            if report.snapshotURL != nil { NotificationCenter.default.post(name: .backupSnapshotsChanged, object: nil) }
        }
        if runAgain {
            runAgain = false
            run()
        }
    }
}

extension Notification.Name {
    static let backupSnapshotsChanged = Notification.Name("ConfigSSH.backupSnapshotsChanged")
}
