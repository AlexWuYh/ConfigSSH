import AppKit
import ConfigSSHCore
import Foundation
import Observation

/// Checks GitHub Releases for a newer ConfigSSH. Only asks GitHub for the public release list;
/// nothing about the user's hosts or config is sent. Never downloads or installs anything.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let autoCheckKey = "checkUpdatesAtLaunch"

    enum State: Equatable {
        case idle
        case checking
        case finished(UpdateCheck.Result, Date)
        case failed(String)
    }

    private(set) var state: State = .idle

    /// `CFBundleShortVersionString`; SwiftPM debug runs have no Info.plist and report "开发版".
    static var currentVersion: String? {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode, let version = ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_VERSION"] {
            return version
        }
        #endif
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    func checkAtLaunchIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.autoCheckKey) else { return }
        check()
    }

    func check() {
        guard state != .checking else { return }
        guard let version = Self.currentVersion else {
            state = .failed("开发版无法检查更新：当前构建没有版本号。")
            return
        }
        state = .checking
        Task {
            state = await Self.fetch(currentVersion: version)
        }
    }

    private static func fetch(currentVersion: String) async -> State {
        var request = URLRequest(url: UpdateCheck.releasesAPIURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ConfigSSH/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed("GitHub 没有返回有效响应。") }
            switch http.statusCode {
            case 200: break
            case 403, 429: return .failed("GitHub 访问次数受限，请稍后再试。")
            default: return .failed("GitHub 返回状态码 \(http.statusCode)。")
            }
            return .finished(try UpdateCheck.evaluate(apiResponse: data, currentVersion: currentVersion), Date())
        } catch let error as URLError {
            return .failed("无法连接 GitHub：\(error.localizedDescription)")
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
