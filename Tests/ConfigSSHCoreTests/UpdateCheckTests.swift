import Foundation
import XCTest
@testable import ConfigSSHCore

final class UpdateCheckTests: XCTestCase {
    private func json(_ releases: [(tag: String, draft: Bool, pre: Bool, url: String?)]) -> Data {
        let items = releases.map { release in
            """
            {"tag_name":"\(release.tag)","html_url":"\(release.url ?? "https://github.com/AlexWuYh/ConfigSSH/releases/tag/\(release.tag)")",\
            "draft":\(release.draft),"prerelease":\(release.pre),"published_at":"2026-11-17T08:00:00Z"}
            """
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    func testVersionParsingAndOrdering() {
        XCTAssertEqual(UpdateCheck.parseVersion("v0.1.0"), [0, 1, 0])
        XCTAssertEqual(UpdateCheck.parseVersion("1.10"), [1, 10])
        XCTAssertNil(UpdateCheck.parseVersion("v1.0.0-beta"))
        XCTAssertNil(UpdateCheck.parseVersion("latest"))
        XCTAssertNil(UpdateCheck.parseVersion("1..2"))
        XCTAssertTrue(UpdateCheck.isNewer([0, 10, 0], than: [0, 9, 9]))
        XCTAssertFalse(UpdateCheck.isNewer([1, 0], than: [1, 0, 0]))
        XCTAssertTrue(UpdateCheck.isNewer([1, 0, 1], than: [1, 0]))
    }

    func testPicksNewestPublishedReleaseIncludingPrereleases() throws {
        let data = json([("v0.1.0", false, true, nil), ("v0.3.0", true, false, nil),
                         ("v0.2.0", false, true, nil), ("nightly", false, false, nil)])
        guard case .updateAvailable(let release) = try UpdateCheck.evaluate(apiResponse: data, currentVersion: "0.1.0") else {
            return XCTFail("expected an update")
        }
        XCTAssertEqual(release.tag, "v0.2.0", "drafts and non-version tags are ignored")
        XCTAssertTrue(release.isPrerelease)
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/AlexWuYh/ConfigSSH/releases/tag/v0.2.0")
    }

    func testUpToDateWhenCurrentIsNewestOrNewer() throws {
        XCTAssertEqual(try UpdateCheck.evaluate(apiResponse: json([("v0.1.0", false, true, nil)]), currentVersion: "0.1.0"),
                       .upToDate(current: "0.1.0"))
        XCTAssertEqual(try UpdateCheck.evaluate(apiResponse: json([("v0.1.0", false, true, nil)]), currentVersion: "0.2.0"),
                       .upToDate(current: "0.2.0"))
        XCTAssertEqual(try UpdateCheck.evaluate(apiResponse: Data("[]".utf8), currentVersion: "0.1.0"),
                       .upToDate(current: "0.1.0"))
    }

    func testReleasePagesOutsideTheRepositoryAreIgnored() throws {
        let data = json([("v9.0.0", false, false, "https://example.com/ConfigSSH.zip"),
                         ("v8.0.0", false, false, "http://github.com/AlexWuYh/ConfigSSH/releases/tag/v8.0.0"),
                         ("v7.0.0", false, false, "https://github.com/someone/else/releases/tag/v7.0.0")])
        XCTAssertEqual(try UpdateCheck.evaluate(apiResponse: data, currentVersion: "0.1.0"), .upToDate(current: "0.1.0"))
    }

    func testMalformedResponseAndVersionThrow() {
        XCTAssertThrowsError(try UpdateCheck.evaluate(apiResponse: Data("{\"message\":\"rate limited\"}".utf8), currentVersion: "0.1.0"))
        XCTAssertThrowsError(try UpdateCheck.evaluate(apiResponse: Data("[]".utf8), currentVersion: "dev"))
    }
}

final class ProjectLinksTests: XCTestCase {
    func testPublicLinksAreHTTPSAndPointAtTheProject() {
        XCTAssertEqual(ProjectLinks.website.absoluteString, "https://configssh.wuewa.cn")
        for url in [ProjectLinks.website, ProjectLinks.repository, ProjectLinks.releases, ProjectLinks.license, ProjectLinks.author] {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
        }
        XCTAssertTrue(ProjectLinks.repository.path.hasSuffix("/ConfigSSH"))
        XCTAssertTrue(ProjectLinks.releases.absoluteString.hasPrefix(ProjectLinks.repository.absoluteString))
        XCTAssertTrue(ProjectLinks.license.absoluteString.hasPrefix(ProjectLinks.repository.absoluteString))
        XCTAssertEqual(ProjectLinks.author.host, "github.com")
    }
}
