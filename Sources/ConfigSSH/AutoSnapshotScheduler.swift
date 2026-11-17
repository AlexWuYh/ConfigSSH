import ConfigSSHCore
import Foundation

/// Runs the automatic config snapshot at launch and then hourly; the core service decides
/// whether a snapshot is actually due and whether the config changed.
@MainActor
final class AutoSnapshotScheduler {
    static let shared = AutoSnapshotScheduler()

    static let intervalKey = "autoSnapshotInterval"
    static let keepKey = "autoSnapshotKeep"
    static let lastResultKey = "autoSnapshotLastResult"

    private var timer: Timer?
    private var running = false

    func start() {
        guard timer == nil else { return }
        runNow()
        let timer = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in AutoSnapshotScheduler.shared.runNow() }
        }
        timer.tolerance = 300
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func runNow() {
        let defaults = UserDefaults.standard
        let interval = AutoSnapshotInterval(rawValue: defaults.string(forKey: Self.intervalKey) ?? "") ?? .daily
        guard interval != .off, !running else { return }
        let stored = defaults.integer(forKey: Self.keepKey)
        let keep = stored == 0 ? AutoSnapshotService.defaultKeep : stored
        let root = ConfigSSHPaths.rootURL
        let folder = ConfigSSHPaths.localSnapshotFolder
        running = true
        Task {
            let message = await Task.detached(priority: .background) { () -> String? in
                let scan = ConfigReader(rootURL: root).scan()
                guard scan.availability == .available else { return nil }
                do {
                    switch try AutoSnapshotService().runIfDue(scan: scan, folder: folder, interval: interval, keep: keep) {
                    case .created: return "已自动创建快照"
                    case .unchanged: return "配置未变化，跳过"
                    case .notDue, .disabled: return nil
                    }
                } catch {
                    return "失败：\(error.localizedDescription)"
                }
            }.value
            running = false
            if let message {
                let stamp = Date().formatted(date: .numeric, time: .shortened)
                defaults.set("\(stamp) · \(message)", forKey: Self.lastResultKey)
            }
        }
    }
}
