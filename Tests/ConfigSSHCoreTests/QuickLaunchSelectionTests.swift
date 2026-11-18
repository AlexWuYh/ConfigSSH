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

final class SearchHighlightTests: XCTestCase {
    private func matches(_ query: String, in text: String) -> [String] {
        SearchHighlight.ranges(of: query, in: text).map { String(text[$0]) }
    }

    func testHighlightsEveryTermCaseInsensitively() {
        XCTAssertEqual(matches("API", in: "api.example.net"), ["api"])
        XCTAssertEqual(matches("eng prod", in: "Engineering · production"), ["Eng", "prod"])
        XCTAssertEqual(matches("e", in: "web-example"), ["e", "e", "e"])
        XCTAssertEqual(matches("cafe", in: "Café"), ["Café"], "diacritics are ignored")
    }

    func testOverlappingAndTouchingMatchesMerge() {
        XCTAssertEqual(matches("ab bc", in: "abc"), ["abc"])
        XCTAssertEqual(matches("ab cd", in: "abcd"), ["abcd"])
    }

    func testNoQueryOrNoMatchHighlightsNothing() {
        XCTAssertTrue(matches("", in: "api").isEmpty)
        XCTAssertTrue(matches("   ", in: "api").isEmpty)
        XCTAssertTrue(matches("zzz", in: "api").isEmpty)
    }

    func testAvatarInitial() {
        XCTAssertEqual(SearchHighlight.initial(of: "api"), "A")
        XCTAssertEqual(SearchHighlight.initial(of: " nas"), "N")
        XCTAssertEqual(SearchHighlight.initial(of: ""), "#")
    }
}
