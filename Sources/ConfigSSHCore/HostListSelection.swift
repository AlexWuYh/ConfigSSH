import Foundation

package enum HostListSelection {
    package static func resolvedID(
        currentID: String?,
        visibleHosts: [HostRecord],
        collapsedGroups: Set<String>,
        groupForHost: (HostRecord) -> String
    ) -> String? {
        let displayed = visibleHosts.filter { !collapsedGroups.contains(groupForHost($0)) }
        return displayed.first(where: { $0.id == currentID })?.id ?? displayed.first?.id
    }
}
