import AppKit
import ConfigSSHCore
import Foundation

extension Notification.Name {
    static let configSSHTerminalProfilesChanged = Notification.Name("ConfigSSH.terminalProfilesChanged")
}

@MainActor
final class TerminalCatalog {
    static let shared = TerminalCatalog()
    private let storageKey = "terminalProfilesV1"
    private var cachedInstalled: [TerminalProfile]?
    private var loading: Task<[TerminalProfile], Never>?
    private var generation = 0

    private struct DiscoveredApp: Sendable {
        let url: URL
        let identifier: String
        let name: String
    }

    private init() { }

    /// Profiles already discovered, without touching the disk. `nil` until the first load.
    var cachedProfiles: [TerminalProfile]? { cachedInstalled }

    /// Synchronous fallback for call sites that must validate immediately (e.g. saving a
    /// profile). UI refreshes use `loadInstalled()` so the app scan stays off the main actor.
    func installed() -> [TerminalProfile] {
        if let cachedInstalled { return cachedInstalled }
        let sorted = profiles(from: Self.discoverApplications())
        cachedInstalled = sorted
        return sorted
    }

    func loadInstalled() async -> [TerminalProfile] {
        if let cachedInstalled { return cachedInstalled }
        if let loading { return await loading.value }
        let started = generation
        let task = Task { @MainActor [weak self] () -> [TerminalProfile] in
            let discovered = await Task.detached(priority: .utility) { Self.discoverApplications() }.value
            guard let self else { return [] }
            let built = self.profiles(from: discovered)
            if self.generation == started { self.cachedInstalled = built }
            return built
        }
        loading = task
        let result = await task.value
        if generation == started { loading = nil }
        return cachedInstalled ?? result
    }

    private func profiles(from discovered: [DiscoveredApp]) -> [TerminalProfile] {
        let saved = savedProfiles()
        var profiles: [TerminalProfile] = []
        for app in discovered {
            var profile = saved[app.identifier] ?? defaultProfile(identifier: app.identifier, name: app.name, url: app.url)
            profile.appPath = app.url.path
            profile.displayName = app.name
            profiles.append(profile)
        }
        for profile in saved.values where !profiles.contains(where: { $0.id == profile.id }) {
            if FileManager.default.fileExists(atPath: profile.appPath) {
                profiles.append(profile)
            }
        }
        return profiles.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private nonisolated static func discoverApplications() -> [DiscoveredApp] {
        applicationURLs().compactMap { url in
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  isTerminal(bundle: bundle) else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return DiscoveredApp(url: url, identifier: identifier, name: name)
        }
    }

    func refresh() {
        cachedInstalled = nil
        loading = nil
        generation += 1
        NotificationCenter.default.post(name: .configSSHTerminalProfilesChanged, object: nil)
    }

    func save(_ profile: TerminalProfile) throws {
        var profiles = savedProfiles()
        guard profiles[profile.id] != nil || installed().contains(where: { $0.id == profile.id }) else {
            throw TerminalLaunchError.unavailable("只允许配置已安装的终端应用")
        }
        profiles[profile.id] = profile
        let data = try JSONEncoder().encode(Array(profiles.values))
        UserDefaults.standard.set(data, forKey: storageKey)
        refresh()
    }

    func addApplication(at url: URL) throws {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier else {
            throw TerminalLaunchError.unavailable("请选择有效的 macOS 终端应用")
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        var profiles = savedProfiles()
        profiles[identifier] = profiles[identifier] ?? defaultProfile(identifier: identifier, name: name, url: url)
        let data = try JSONEncoder().encode(Array(profiles.values))
        UserDefaults.standard.set(data, forKey: storageKey)
        refresh()
    }

    func automaticProfile(for profile: TerminalProfile) -> TerminalProfile {
        defaultProfile(identifier: profile.id, name: profile.displayName,
                       url: URL(fileURLWithPath: profile.appPath))
    }

    private func savedProfiles() -> [String: TerminalProfile] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let profiles = try? JSONDecoder().decode([TerminalProfile].self, from: data) else { return [:] }
        return profiles.reduce(into: [:]) { $0[$1.id] = $1 }
    }

    private nonisolated static func applicationURLs() -> [URL] {
        var found: [String: URL] = [:]
        let folders = [URL(fileURLWithPath: "/Applications"),
                       URL(fileURLWithPath: "/Applications/Utilities"),
                       URL(fileURLWithPath: "/System/Applications"),
                       URL(fileURLWithPath: "/System/Applications/Utilities"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Utilities")]
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                let candidates: [URL]
                if entry.pathExtension == "app" { candidates = [entry] }
                else { candidates = (try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil))?
                    .filter { $0.pathExtension == "app" } ?? [] }
                for url in candidates {
                    guard let identifier = Bundle(url: url)?.bundleIdentifier else { continue }
                    found[identifier] = url
                }
            }
        }
        for identifier in ["com.apple.Terminal", "com.mitchellh.ghostty", "io.appmakes.otty"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                found[identifier] = url
            }
        }
        return Array(found.values)
    }

    private nonisolated static func isTerminal(bundle: Bundle) -> Bool {
        let identifier = bundle.bundleIdentifier ?? ""
        if ["com.apple.Terminal", "com.mitchellh.ghostty", "io.appmakes.otty"].contains(identifier) { return true }
        let category = (bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? "").lowercased()
        if category.contains("terminal") { return true }
        let name = ((bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "").lowercased()
        return ["terminal", "iterm", "kitty", "wezterm", "alacritty", "warp", "hyper", "tabby", "rio"].contains {
            name.contains($0)
        }
    }

    private func defaultProfile(identifier: String, name: String, url: URL) -> TerminalProfile {
        switch identifier {
        case "io.appmakes.otty":
            return TerminalProfile(id: identifier, displayName: name, appPath: url.path,
                                   strategy: .ottyCLI,
                                   executablePath: url.appendingPathComponent("Contents/MacOS/otty-cli").path)
        case "com.mitchellh.ghostty":
            return TerminalProfile(id: identifier, displayName: name, appPath: url.path,
                                   strategy: .ghosttyAppleScript)
        case "com.apple.Terminal":
            return TerminalProfile(id: identifier, displayName: name, appPath: url.path,
                                   strategy: .macOSTerminal)
        default:
            return TerminalProfile(id: identifier, displayName: name, appPath: url.path,
                                   strategy: .unconfigured)
        }
    }
}
