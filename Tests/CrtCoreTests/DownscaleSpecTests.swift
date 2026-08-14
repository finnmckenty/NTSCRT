import XCTest
@testable import CrtCore

/// Guards the downscale width loaded from a look/preset file.
///
/// Look files are user-editable JSON shared between machines, so the width
/// can arrive as 0, a negative number, or an absurdly large value. Before the
/// clamp, any of those flowed straight into `MTLTextureDescriptor` →
/// `makeTexture` (which returns nil for invalid dimensions) → a force-unwrap
/// in `Pipeline.obtainDownscaleTexture` that trapped the render thread the
/// next time the chain ran. The UI's Stepper/IntField already bound the width
/// to 16...4096; this test pins the load path to the same range.
final class DownscaleSpecTests: XCTestCase {

    func testClampsBelowTheMinimum() {
        XCTAssertEqual(DownscaleSpec.clampedWidth(0), 16)
        XCTAssertEqual(DownscaleSpec.clampedWidth(-5), 16)
        XCTAssertEqual(DownscaleSpec.clampedWidth(Int.min), 16)
    }

    func testClampsAboveTheMaximum() {
        XCTAssertEqual(DownscaleSpec.clampedWidth(4097), 4096)
        XCTAssertEqual(DownscaleSpec.clampedWidth(100_000), 4096)
        XCTAssertEqual(DownscaleSpec.clampedWidth(Int.max), 4096)
    }

    func testPassesThroughInBoundsValues() {
        XCTAssertEqual(DownscaleSpec.clampedWidth(16), 16)
        XCTAssertEqual(DownscaleSpec.clampedWidth(320), 320)
        XCTAssertEqual(DownscaleSpec.clampedWidth(4096), 4096)
    }
}
