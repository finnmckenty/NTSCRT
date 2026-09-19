import Foundation
import CoreGraphics

/// Small image measurements shared by the tests and the in-app export checks.
public enum ImageStats {

    /// Mean absolute luminance step between vertically adjacent pixels
    /// (0–255 scale) over the middle of the image. Scanlines make this large;
    /// flat or smoothly varying content keeps it near zero — so it tells
    /// "CRT shader on" from "off" without caring about codec noise.
    public static func rowModulation(of image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 8, h > 8 else { return 0 }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        func luminance(_ x: Int, _ y: Int) -> Double {
            let i = (y * w + x) * 4
            return 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1])
                + 0.0722 * Double(bytes[i + 2])
        }
        let x0 = w / 4, x1 = 3 * w / 4, y0 = h / 5, y1 = 4 * h / 5
        var total = 0.0
        var n = 0
        for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 48)) {
            for y in y0..<(y1 - 1) {
                total += abs(luminance(x, y) - luminance(x, y + 1))
                n += 1
            }
        }
        return n > 0 ? total / Double(n) : 0
    }
}
