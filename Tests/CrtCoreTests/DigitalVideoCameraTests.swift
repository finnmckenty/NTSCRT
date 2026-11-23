import XCTest
@testable import CrtCodec
import CrtCore

/// The camera's tone in its four parts (one slider, CCD response, sets
/// them all), and the camcorder's one-chip sensor: cyan, yellow, magenta
/// and green filters read two rows at a time, with color on alternate lines.
extension DigitalVideoTests {

    private func rgbAt(_ px: [UInt8], _ x: Int, _ y: Int, _ w: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * w + x) * 4
        return (Int(px[i + 2]), Int(px[i + 1]), Int(px[i]))
    }

    private func spread(_ p: (r: Int, g: Int, b: Int)) -> Int { max(p.r, p.g, p.b) - min(p.r, p.g, p.b) }

    private func picture(_ w: Int, _ h: Int, _ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let c = color(x, y), i = (y * w + x) * 4
                px[i] = c.2; px[i + 1] = c.1; px[i + 2] = c.0
            }
        }
        return px
    }

    // MARK: - the four parts of CCD response

    func testAutoExposureOnlyOpensUpWhileThereIsLightToSpare() {
        let camera = CCDResponse(strength: 1)
        // Daylight (no gain in use): all the way to the target, up to 4×.
        XCTAssertEqual(camera.exposureGain(meteredMean: 0.2, sensorGain: 1), 2, accuracy: 1e-4)
        XCTAssertEqual(camera.exposureGain(meteredMean: 0.02, sensorGain: 1), 4, accuracy: 1e-4)
        // Night (gain already at its 8× top): nothing left to open.
        XCTAssertEqual(camera.exposureGain(meteredMean: 0.02, sensorGain: 8), 1, accuracy: 1e-4)
        // In between: as far as the gain that's left.
        XCTAssertEqual(camera.exposureGain(meteredMean: 0.02, sensorGain: 4), 2, accuracy: 1e-4)
        XCTAssertEqual(camera.exposureGain(meteredMean: 0.02, sensorGain: 1.5), 4, accuracy: 1e-4)
        // Stopping down is always possible.
        XCTAssertEqual(camera.exposureGain(meteredMean: 0.8, sensorGain: 8), 0.5, accuracy: 1e-4)
        XCTAssertEqual(CCDResponse(strength: 0.5).exposureGain(meteredMean: 0.1, sensorGain: 1), 2, accuracy: 1e-4)
    }

    func testANightSceneStaysNight() {
        // Dark, with a few lamps: the old single curve exposed this up to
        // gray daylight (black at 100). Now only the levels and a little
        // flare lift it.
        let night = picture(64, 48) { x, y in
            (x - 32) * (x - 32) + (y - 20) * (y - 20) < 9 ? (255, 250, 230) : (12, 12, 18)
        }
        let out = camera(night, 64, 48, ["ccd_response": 1])
        let dark = out.y.data[40 * out.y.width + 6]
        XCTAssertLessThan(dark, 40, "the dark stays dark: \(dark)")
        XCTAssertGreaterThan(dark, 20, "at DV's lifted black")
        XCTAssertGreaterThan(out.y.data[20 * out.y.width + 32], 240, "the lamp stays white")
        // The same picture in daylight tones is re-exposed.
        let day = picture(64, 48) { x, y in
            (x - 32) * (x - 32) + (y - 20) * (y - 20) < 9 ? (255, 250, 230) : (120, 120, 126)
        }
        let lit = camera(day, 64, 48, ["ccd_response": 1])
        XCTAssertGreaterThan(lit.y.data[40 * lit.y.width + 6], 165)
    }

    func testLevelsAreDVsRangeShownAsStored() {
        let camera = CCDResponse(strength: 1)
        XCTAssertEqual(camera.black, 16)
        // The camera's clip (109% of white) lands on 255, white on 235.
        XCTAssertEqual(camera.black + 255 * camera.lumaScale, 255, accuracy: 1e-3)
        XCTAssertEqual(camera.black + 255 / 1.09 * camera.lumaScale, 235, accuracy: 0.3)
        // Color: ±112 for 100%, so ±122 at the clip.
        XCTAssertEqual(127.5 * camera.chromaScale, 1.09 * 112, accuracy: 0.1)
        XCTAssertEqual(CCDResponse(strength: 0).black, 0)
        XCTAssertEqual(CCDResponse(strength: 0).chromaScale, 1)
    }

    func testTheFourPartsAreSeparate() {
        var camera = CCDResponse(strength: 0)
        XCTAssertFalse(camera.isOn)
        camera.levels = 1
        XCTAssertTrue(camera.isOn)
        XCTAssertEqual(camera.black, 16)
        XCTAssertEqual(camera.exposureGain(meteredMean: 0.05, sensorGain: 1), 1)
        XCTAssertEqual(camera.knee(240), 240)
        XCTAssertEqual(camera.flareLight(meteredMean: 0.5), 0)
        camera = CCDResponse(strength: 0)
        camera.highlights = 1
        XCTAssertLessThan(camera.knee(240), 240)
        XCTAssertEqual(camera.black, 0)
        // The source's white is taken to be at this camera's clip, so it
        // comes out white; below 235 nothing is assumed.
        XCTAssertEqual(camera.clipLight, 2.37, accuracy: 0.02)
        XCTAssertEqual(camera.recovered(top: 255, low: 255), camera.clipLight)
        XCTAssertEqual(camera.recovered(top: 230, low: 230), 1)
        XCTAssertEqual(camera.knee(DigitalVideoRenderer.linearToSRGB(camera.clipLight)), 255, accuracy: 0.01)
        // One channel at the top is a color, not a blown highlight.
        XCTAssertEqual(camera.recovered(top: 255, low: 30), 1, accuracy: 0.03)
        XCTAssertEqual(CCDResponse(strength: 0).recovered(top: 255, low: 255), 1)
        camera = CCDResponse(strength: 0)
        camera.flare = 1
        XCTAssertGreaterThan(camera.flareLight(meteredMean: 0.5), 0)
        XCTAssertEqual(camera.knee(240), 240)
    }

    // MARK: - the camcorder's one chip

    func testComplementaryFiltersGetFlatColorRight() {
        for color: (UInt8, UInt8, UInt8) in [(200, 120, 40), (30, 30, 30), (255, 255, 255), (0, 180, 255), (128, 0, 64)] {
            let flat = picture(32, 24) { _, _ in color }
            var out = flat
            DigitalVideoRenderer.complementary(&out, width: 32, height: 24)
            XCTAssertEqual(out, flat, "\(color)")
        }
        // The four filters' sums over a block are the brightness signal:
        // 2R + 3G + 2B for each pair of pixels over a pair of rows.
        var sum: Float = 0
        for y in 0..<2 { for x in 0..<2 { sum += DigitalVideoRenderer.complementarySite(x, y, 0.5, 0.25, 0.125) } }
        XCTAssertEqual(sum, 2 * 0.5 + 3 * 0.25 + 2 * 0.125, accuracy: 1e-6)
    }

    /// Each line has one of the two color signals and borrows the other
    /// from the line before in its field, so where the picture changes down
    /// the frame the two disagree: a gray edge gets a colored fringe.
    func testColorComesALineLateAtHorizontalEdges() {
        let w = 32, h = 32
        let edge = picture(w, h) { _, y in y < 15 ? (40, 40, 40) : (210, 210, 210) }
        var out = edge
        DigitalVideoRenderer.complementary(&out, width: w, height: h)
        var fringe = 0
        for y in 0..<h {
            let s = spread(rgbAt(out, 10, y, w))
            if (12...17).contains(y) { fringe = max(fringe, s) } else { XCTAssertLessThanOrEqual(s, 1, "line \(y)") }
        }
        XCTAssertGreaterThan(fringe, 40)
        // And every pixel of a line shows the same thing: nothing across.
        for y in 0..<h { XCTAssertEqual(out[(y * w + 4) * 4 + 2], out[(y * w + 25) * 4 + 2], "line \(y)") }
    }

    /// A sharp edge across the line is a difference between neighboring
    /// pixels, which is how the sensor carries color: false color there,
    /// and nowhere else.
    func testSharpVerticalEdgesPickUpFalseColor() {
        let w = 32, h = 24
        let edge = picture(w, h) { x, _ in x < 15 ? (40, 40, 40) : (210, 210, 210) }
        var out = edge
        DigitalVideoRenderer.complementary(&out, width: w, height: h)
        var fringe = 0
        for x in 0..<w {
            let s = spread(rgbAt(out, x, 12, w))
            if (11...18).contains(x) { fringe = max(fringe, s) } else { XCTAssertLessThanOrEqual(s, 1, "column \(x)") }
        }
        XCTAssertGreaterThan(fringe, 25)
    }

    /// Rows are read two at a time, summed: a line one row tall comes out
    /// two lines tall. And a row holds only two of the four filters, so the
    /// line can't be told from a colored one: thin horizontal detail takes
    /// on color, which color depending on the row it falls on.
    func testFieldIntegrationSpreadsAThinLineOverTwoAndColorsIt() {
        let w = 32, h = 24
        for row in [12, 13] {
            let line = picture(w, h) { _, y in y == row ? (255, 255, 255) : (0, 0, 0) }
            var out = line
            DigitalVideoRenderer.complementary(&out, width: w, height: h)
            func light(_ y: Int) -> Float {
                let p = rgbAt(out, 16, y, w)
                let l = DigitalVideoRenderer.srgbToLinear
                return 0.2126 * l[p.r] + 0.7152 * l[p.g] + 0.0722 * l[p.b]
            }
            XCTAssertEqual(light(row - 1), light(row), accuracy: 0.25, "row \(row)")
            XCTAssertGreaterThan(light(row - 1), 0.25); XCTAssertLessThan(light(row - 1), 0.85)
            XCTAssertGreaterThan(light(row), 0.25); XCTAssertLessThan(light(row), 0.85)
            XCTAssertLessThan(light(row - 4), 0.02)
            XCTAssertGreaterThan(spread(rgbAt(out, 16, row, w)), 30, "colored")
        }
        // Two rows of it are every filter: white again in the middle.
        let band = picture(w, h) { _, y in (10...15).contains(y) ? (255, 255, 255) : (0, 0, 0) }
        var out = band
        DigitalVideoRenderer.complementary(&out, width: w, height: h)
        let middle = rgbAt(out, 16, 13, w)
        XCTAssertEqual(middle.r, 255); XCTAssertEqual(middle.g, 255); XCTAssertEqual(middle.b, 255)
    }

    /// One chip's grain goes through its color reconstruction: weaker and
    /// finer in brightness than three chips', and in color no longer
    /// independent from pixel to pixel — it comes in blotches along the
    /// line, shared with the next line of the same field but not with the
    /// line between (the other field's own exposure).
    func testOneChipGrainIsBlotchyInColor() {
        let w = 96, h = 64
        guard let grain = DigitalVideoRenderer.sensorGrain(.complementary, width: w, height: h, index: 7) else {
            return XCTFail("no grain")
        }
        func luma(_ i: Int) -> Float { 0.299 * grain.r[i] + 0.587 * grain.g[i] + 0.114 * grain.b[i] }
        func color(_ i: Int) -> Float { grain.r[i] - grain.g[i] }
        func correlation(_ f: (Int) -> Float, dx: Int, dy: Int) -> Float {
            var ab: Float = 0, aa: Float = 0, bb: Float = 0
            for y in 4..<(h - 4) {
                for x in 4..<(w - 4) {
                    let a = f(y * w + x), b = f((y + dy) * w + x + dx)
                    ab += a * b; aa += a * a; bb += b * b
                }
            }
            return ab / (aa * bb).squareRoot()
        }
        var mean: Float = 0, power: Float = 0
        for i in 0..<(w * h) { mean += luma(i); power += luma(i) * luma(i) }
        XCTAssertEqual(mean / Float(w * h), 0, accuracy: 0.05)
        // Brightness grain at Sensor noise 100%, against three chips' 7.
        XCTAssertLessThan(DigitalVideoRenderer.photositeNoise * (power / Float(w * h)).squareRoot(), 7)
        XCTAssertGreaterThan(correlation(color, dx: 1, dy: 0), 0.5, "blotches along the line")
        XCTAssertGreaterThan(correlation(color, dx: 0, dy: 2), 0.2, "shared with the field's next line")
        XCTAssertEqual(correlation(color, dx: 0, dy: 1), 0, accuracy: 0.15, "not with the other field's")
        // The same every time for a frame, different from frame to frame.
        XCTAssertEqual(DigitalVideoRenderer.sensorGrain(.complementary, width: w, height: h, index: 7)!.r, grain.r)
        XCTAssertNotEqual(DigitalVideoRenderer.sensorGrain(.complementary, width: w, height: h, index: 8)!.r, grain.r)
        // The webcam's mosaic shares neighbors too, less; three chips have
        // no reconstruction to go through.
        let mosaic = DigitalVideoRenderer.sensorGrain(.mosaic, width: w, height: h, index: 7)!
        var ab: Float = 0, aa: Float = 0
        for y in 0..<h { for x in 0..<(w - 1) { let i = y * w + x; ab += mosaic.r[i] * mosaic.r[i + 1]; aa += mosaic.r[i] * mosaic.r[i] } }
        XCTAssertGreaterThan(ab / aa, 0.2)
        XCTAssertNil(DigitalVideoRenderer.sensorGrain(.threeChips, width: w, height: h, index: 7))
        // A flat field of photosites reconstructs flat.
        let flat = DigitalVideoRenderer.mosaicColors([Float](repeating: 1, count: w * h), width: w, height: h)
        XCTAssertEqual(flat.r.min()!, 1, accuracy: 1e-6); XCTAssertEqual(flat.b.max()!, 1, accuracy: 1e-6)
    }

    func testThreeChipsGrainIsUnchangedAndOneChipsDiffers() {
        let px = [UInt8](repeating: 128, count: 64 * 48 * 4)
        let three = camera(px, 64, 48, ["sensor_noise": 0.5])
        let again = camera(px, 64, 48, ["sensor_noise": 0.5, "sensor": 0])
        XCTAssertEqual(three.y.data[1000], again.y.data[1000])
        let one = camera(px, 64, 48, ["sensor_noise": 0.5, "sensor": 2])
        func deviation(_ p: CodecPlane) -> Float {
            var s: Float = 0
            for y in 0..<48 { for x in 0..<64 { let d = p.data[y * p.width + x] - 128; s += d * d } }
            return (s / Float(64 * 48)).squareRoot()
        }
        XCTAssertGreaterThan(deviation(one.y), 0.5)
        XCTAssertLessThan(deviation(one.y), deviation(three.y), "less brightness grain")
        XCTAssertGreaterThan(deviation(one.cr), 1, "but color grain")
    }

    func testOneChipSensorsLookTheSameJumpedToAsPlayed() {
        for sensor in [1.0, 2] {
            checkJumpsMatchPlaying(DigitalSettings(values: ["frame_rate": 30, "sensor": sensor, "sensor_noise": 0.5,
                                                            "low_light_noise": 0.5, "fields": 2, "aliasing": 0.4,
                                                            "keyframe_interval": 0.5, "quality": 0.6,
                                                            "ccd_response": 0.7, "data_loss": 0.3]),
                                   cut: 16, "sensor \(sensor)")
        }
    }

    // MARK: - what the stage starts with

    /// A new window's Digital video settings are the MiniDV tape look: a
    /// one-chip camcorder with DV's color. Every control has a value, each
    /// within its control's range.
    func testTheStageStartsAsAMiniDVCamcorder() {
        let start = DigitalSettings(values: DigitalParam.startingValues)
        XCTAssertEqual(start.sensor, .complementary)
        XCTAssertEqual(start.chroma, .quarterWide)
        XCTAssertEqual(start.codec, .dct)
        XCTAssertEqual(start.fields, .oneField)
        XCTAssertEqual(start["chroma_upsampling"], 1)
        XCTAssertEqual(start["keyframe_interval"], 0)
        XCTAssertEqual(start["ccd_response"], 0.1615, accuracy: 1e-3)
        XCTAssertEqual(start.generations, 0); XCTAssertEqual(start.bitsPerPixel, 0); XCTAssertEqual(start.blockSize, 8)
        for p in DigitalParam.all {
            guard let v = DigitalParam.startingValues[p.id] else { XCTFail("no starting value for \(p.id)"); continue }
            switch p.kind {
            case .slider(let lo, let hi, _, _): XCTAssertTrue((lo...hi).contains(v), p.id)
            case .choice(let names): XCTAssertTrue((0..<names.count).contains(Int(v)), p.id)
            }
        }
        // The controls' own defaults are something else: formats build on those.
        XCTAssertEqual(DigitalParam.defaultValues["sensor"], 0)
        XCTAssertNotNil(DigitalFormat.matching(values: DigitalFormat.byID["minidv"]!.values, width: 720))
    }
}
