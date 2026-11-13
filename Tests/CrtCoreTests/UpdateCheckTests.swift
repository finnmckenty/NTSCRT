import XCTest
@testable import CrtCore

/// The update check's version rules and GitHub parsing (the same cases as
/// port/app/src/update.rs's tests).
final class UpdateCheckTests: XCTestCase {

    func testVersionsReadFromTagsAndDescribeStrings() {
        XCTAssertEqual(UpdateCheck.parseVersion("v0.22.1"), [0, 22, 1])
        XCTAssertEqual(UpdateCheck.parseVersion("0.22.1-3-gf1f92f1-dirty"), [0, 22, 1])
        XCTAssertEqual(UpdateCheck.parseVersion("1.0"), [1, 0, 0])
        XCTAssertNil(UpdateCheck.parseVersion("dev"))
        XCTAssertNil(UpdateCheck.parseVersion("f1f92f1"))
    }

    private func release(_ v: String) -> UpdateCheck.Release {
        .init(version: v, page: UpdateCheck.releasesPage, notes: "")
    }

    func testOnlyANewerReleaseIsOffered() {
        XCTAssertEqual(UpdateCheck.compare(current: "0.22.1", latest: release("0.23.0")), .newer(release("0.23.0")))
        XCTAssertEqual(UpdateCheck.compare(current: "0.22.1", latest: release("0.22.10")), .newer(release("0.22.10")))
        XCTAssertEqual(UpdateCheck.compare(current: "0.22.1", latest: release("0.22.1")), .upToDate(latest: "0.22.1"))
        // Built after 0.22.1 but not released yet: still 0.22.1.
        XCTAssertEqual(UpdateCheck.compare(current: "0.22.1-2-gabc", latest: release("0.22.1")), .upToDate(latest: "0.22.1"))
        XCTAssertEqual(UpdateCheck.compare(current: "0.23.0", latest: release("0.22.1")), .upToDate(latest: "0.22.1"))
        // No version (a bare dev binary): offered.
        XCTAssertEqual(UpdateCheck.compare(current: "dev", latest: release("0.22.1")), .newer(release("0.22.1")))
    }

    func testGitHubsAnswerBecomesAReleaseWithPlainNotes() throws {
        let json = #"""
        {"tag_name": "v0.23.0",
         "html_url": "https://github.com/finnmckenty/NTSCRT/releases/tag/v0.23.0",
         "body": "## Windows preview\r\n\r\n- **Smoother playback.** Uses `ntscrt.exe`.\r\n  - nested"}
        """#
        let r = try UpdateCheck.release(from: Data(json.utf8))
        XCTAssertEqual(r.version, "0.23.0")
        XCTAssertEqual(r.page.absoluteString, "https://github.com/finnmckenty/NTSCRT/releases/tag/v0.23.0")
        XCTAssertEqual(r.notes, "Windows preview\n\n• Smoother playback. Uses ntscrt.exe.\n  • nested")
        XCTAssertThrowsError(try UpdateCheck.release(from: Data("{}".utf8)))
    }
}
