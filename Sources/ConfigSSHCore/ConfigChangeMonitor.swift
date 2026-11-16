import Foundation

package enum ConfigChangeMonitor {
    package static func fingerprint(_ scan: ConfigScan) -> String {
        let availability: String
        switch scan.availability {
        case .available: availability = "available"
        case .missing: availability = "missing"
        case .unreadable(let reason): availability = "unreadable:\(reason)"
        }
        let sources = scan.sources.sorted { $0.url.path < $1.url.path }
            .map { "\($0.url.standardizedFileURL.path):\($0.sha256)" }
        let issues = scan.issues.map { "\($0.location):\($0.message)" }.sorted()
        return ([availability] + sources + issues).joined(separator: "\u{1F}")
    }

    package static func fingerprint(rootURL: URL) -> String {
        fingerprint(ConfigReader(rootURL: rootURL).scan())
    }
}
