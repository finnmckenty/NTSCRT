import XCTest
import Metal
@testable import CrtCore

/// One field down the chain: the shader gets half the lines, each standing
/// for two rows. Everything sized by the picture has to keep its shape;
/// everything about lines has to see the real line count.
final class FieldLinesTests: XCTestCase {

    let field = DownscaleSpec(width: 480, height: 300, method: .nearest, lineHeight: 2)

    func testTheCameraStillCapturesTheWholeFrame() {
        XCTAssertEqual(field.pictureHeight, 600)
        let size = DigitalFrameInput.captureSize(width: 1080, height: 1350, downscale: field)
        XCTAssertEqual(size.width, 480)
        XCTAssertEqual(size.height, 600)
    }

    func testSnappedExportsKeepThePicturesShape() {
        let s = ScanlineGrid.snappedSize(inputWidth: 480, inputHeight: 300, targetHeight: 1350, lineHeight: 2)
        XCTAssertEqual(s.height % 300, 0, "whole field lines: \(s)")
        XCTAssertEqual(Double(s.width) / Double(s.height), 480.0 / 600, accuracy: 0.01, "4:5, not 8:5")
        // Square lines behave as before.
        let sq = ScanlineGrid.snappedSize(inputWidth: 480, inputHeight: 600, targetHeight: 1350)
        XCTAssertEqual(sq.width, 480 * sq.height / 600)
    }

    func testSupersamplingFollowsTheTargetsShape() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // 800 rows for 300 lines is 2.67 rows a line: supersampled.
        let pass = try XCTUnwrap(SupersampledPass.make(device: device, chainInput: (480, 300),
                                                       target: (640, 800)))
        XCTAssertEqual(pass.renderHeight % 300, 0)
        XCTAssertEqual(Double(pass.renderWidth) / Double(pass.renderHeight), 640.0 / 800, accuracy: 0.01)
        // Square lines: the same size as before the change.
        let sq = try XCTUnwrap(SupersampledPass.make(device: device, chainInput: (320, 240),
                                                     target: (500, 375)))
        XCTAssertEqual(sq.renderWidth, 320 * sq.renderHeight / 240)
    }
}
