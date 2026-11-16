import Foundation

package enum QuickLaunchSelection {
    package static func resolvedID(_ preferred: String?, visibleIDs: [String]) -> String? {
        guard !visibleIDs.isEmpty else { return nil }
        return visibleIDs.first(where: { $0 == preferred }) ?? visibleIDs.first
    }

    package static func movedID(_ current: String?, by offset: Int, visibleIDs: [String]) -> String? {
        guard !visibleIDs.isEmpty else { return nil }
        let selected = resolvedID(current, visibleIDs: visibleIDs)
        let index = visibleIDs.firstIndex(where: { $0 == selected }) ?? 0
        return visibleIDs[min(max(index + offset, 0), visibleIDs.count - 1)]
    }
}
