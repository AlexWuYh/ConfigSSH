import Foundation
import XCTest
@testable import ConfigSSHCore

final class QuickLaunchSelectionTests: XCTestCase {
    func testSelectionFollowsHostIDWhenResultsChange() {
        XCTAssertEqual(QuickLaunchSelection.resolvedID("second", visibleIDs: ["first", "second"]), "second")
        XCTAssertEqual(QuickLaunchSelection.resolvedID("second", visibleIDs: ["first"]), "first")
        XCTAssertNil(QuickLaunchSelection.resolvedID("second", visibleIDs: []))
    }

    func testArrowNavigationIsClampedAndNeverOutOfBounds() {
        XCTAssertEqual(QuickLaunchSelection.movedID(nil, by: 1, visibleIDs: ["one", "two"]), "two")
        XCTAssertEqual(QuickLaunchSelection.movedID("two", by: 1, visibleIDs: ["one", "two"]), "two")
        XCTAssertEqual(QuickLaunchSelection.movedID("one", by: -1, visibleIDs: ["one", "two"]), "one")
        XCTAssertNil(QuickLaunchSelection.movedID("one", by: 1, visibleIDs: []))
    }
}
