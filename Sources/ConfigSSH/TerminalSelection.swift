import ConfigSSHCore
import Foundation

@MainActor
enum TerminalSelection {
    static func resolved(_ raw: String?, from capabilities: [TerminalCapability]) -> TerminalProfile? {
        if let id = TerminalProfile.canonicalID(raw ?? ""),
           let matched = capabilities.first(where: { $0.id == id }) { return matched.profile }
        return capabilities.first(where: { $0.supportsWindow })?.profile
    }
}
