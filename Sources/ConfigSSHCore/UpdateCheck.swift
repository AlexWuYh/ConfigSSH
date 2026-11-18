import Foundation

/// Version comparison and GitHub Releases parsing for "检查更新". The network request itself
/// lives in the app; this part is pure so it can be tested without network access.
package enum UpdateCheck {
    package static let repositoryURL = URL(string: "https://github.com/AlexWuYh/ConfigSSH")!
    package static let releasesPageURL = URL(string: "https://github.com/AlexWuYh/ConfigSSH/releases")!
    /// Includes prereleases: every published build so far is an unsigned prerelease.
    package static let releasesAPIURL = URL(string: "https://api.github.com/repos/AlexWuYh/ConfigSSH/releases?per_page=20")!

    package struct Release: Equatable, Sendable {
        package let tag: String
        package let version: [Int]
        package let pageURL: URL
        package let isPrerelease: Bool
        package let publishedAt: Date?
    }

    package enum Result: Equatable, Sendable {
        case upToDate(current: String)
        case updateAvailable(Release)
    }

    /// Parses `v1.2.3` / `1.2.3`; anything else (including suffixes like `-beta`) returns nil.
    package static func parseVersion(_ text: String) -> [Int]? {
        var value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.map { part -> Int? in
            guard !part.isEmpty, part.count <= 6, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part)
        }
        guard numbers.allSatisfy({ $0 != nil }) else { return nil }
        return numbers.compactMap { $0 }
    }

    package static func isNewer(_ candidate: [Int], than current: [Int]) -> Bool {
        let count = max(candidate.count, current.count)
        for index in 0..<count {
            let a = index < candidate.count ? candidate[index] : 0
            let b = index < current.count ? current[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private struct APIRelease: Decodable {
        let tag_name: String
        let html_url: String
        let draft: Bool
        let prerelease: Bool
        let published_at: String?
    }

    /// Picks the newest published release from the GitHub API response. Release pages must be on
    /// github.com under this repository; anything else is ignored.
    package static func evaluate(apiResponse data: Data, currentVersion: String) throws -> Result {
        guard let current = parseVersion(currentVersion) else {
            throw ConfigEditError.invalid("无法识别当前版本号：\(currentVersion)")
        }
        let releases: [APIRelease]
        do {
            releases = try JSONDecoder().decode([APIRelease].self, from: data)
        } catch {
            throw ConfigEditError.io("无法解析 GitHub 返回的版本信息")
        }
        let formatter = ISO8601DateFormatter()
        let candidates = releases.compactMap { release -> Release? in
            guard !release.draft, let version = parseVersion(release.tag_name),
                  let url = URL(string: release.html_url), url.scheme == "https", url.host == "github.com",
                  url.path.hasPrefix(releasesPageURL.path + "/") else { return nil }
            return Release(tag: release.tag_name, version: version, pageURL: url,
                           isPrerelease: release.prerelease,
                           publishedAt: release.published_at.flatMap(formatter.date(from:)))
        }
        guard let newest = candidates.max(by: { isNewer($1.version, than: $0.version) }),
              isNewer(newest.version, than: current) else {
            return .upToDate(current: currentVersion)
        }
        return .updateAvailable(newest)
    }
}
