import Foundation
import XCTest
@testable import ConfigSSHCore

final class HostListSelectionTests: XCTestCase {
    private func host(_ id: String, group: String) -> HostRecord {
        HostRecord(
            id: id,
            alias: id,
            sourceOrder: 0,
            sourceURL: URL(fileURLWithPath: "/fixture/config.d/\(group)/\(id).conf"),
            sourceLine: 1,
            byteRange: 0..<0,
            explicitOptions: [],
            readOnlyReasons: []
        )
    }

    func testCollapsingSelectedGroupMovesSelectionToVisibleHost() {
        let grouped = host("grouped", group: "Work")
        let ungrouped = host("ungrouped", group: "None")
        let hosts = [grouped, ungrouped]
        let group: (HostRecord) -> String = { $0.id == "ungrouped" ? "未分组" : "Work" }

        XCTAssertEqual(HostListSelection.resolvedID(currentID: ungrouped.id, visibleHosts: hosts,
                                                   collapsedGroups: ["未分组"], groupForHost: group), grouped.id)
        XCTAssertNil(HostListSelection.resolvedID(currentID: ungrouped.id, visibleHosts: hosts,
                                                 collapsedGroups: ["未分组", "Work"], groupForHost: group))
        XCTAssertEqual(HostListSelection.resolvedID(currentID: ungrouped.id, visibleHosts: hosts,
                                                   collapsedGroups: [], groupForHost: group), ungrouped.id)
    }

    func testSelectionOutsideCurrentFilterUsesFirstDisplayedHost() {
        let first = host("first", group: "Work")
        let second = host("second", group: "Work")
        XCTAssertEqual(HostListSelection.resolvedID(currentID: nil, visibleHosts: [first, second],
                                                   collapsedGroups: [], groupForHost: { _ in "Work" }), first.id)
        let result = HostListSelection.resolvedID(currentID: "hidden", visibleHosts: [first, second],
                                                  collapsedGroups: [], groupForHost: { _ in "Work" })
        XCTAssertEqual(result, first.id)
    }
}
