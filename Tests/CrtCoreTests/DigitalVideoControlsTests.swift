import XCTest
@testable import CrtCodec
import CrtCore

/// The Digital video controls added after 0.27.5: both fields of an
/// interlaced camera, the one-chip sensor and vertical smear, blocky color
/// decode, DV tape loss patterns, what lost blocks show, bit errors, and
/// added motion. Each is off by default, so every earlier look is untouched;
/// each is checked for what it does to the picture, and that a frame still
/// looks the same however it's reached.
extension DigitalVideoTests {

    private func pixel(_ px: [UInt8], _ x: Int, _ y: Int, width: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(px[i + 2]), Int(px[i + 1]), Int(px[i]))
    }

    /// The picture the stage shows, at the capture size (the stage scales it
    /// back up with hard pixels: one sample per capture pixel).
    private func small(_ px: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: capture.width * capture.height * 4)
        let k = size.width / capture.width
        for y in 0..<capture.height {
            for x in 0..<capture.width {
                let s = ((y * k) * size.width + x * k) * 4, d = (y * capture.width + x) * 4
                for c in 0..<4 { out[d + c] = px[s + c] }
            }
        }
        return out
    }

    /// A still: the same pixels every frame, and no earlier frames to ask for.
    private func still(_ r: DigitalVideoRenderer, _ n: Int, _ s: DigitalSettings, picture: [UInt8]? = nil) -> [UInt8] {
        var px = picture ?? frame(0)
        px.withUnsafeMutableBytes {
            r.process(frame: n, pixels: $0.baseAddress!, width: size.width, height: size.height,
                      rowBytes: size.width * 4, captureSize: capture, sourceFPS: 30, settings: s)
        }
        return px
    }

    private var plain: [String: Double] {
        ["frame_rate": 30, "fields": 0, "sensor_noise": 0, "noise_reduction": 0, "quality": 0.95,
         "chroma": 0, "keyframe_interval": 0]
    }

    // MARK: - off by default

    func testNewControlsAreOffByDefault() {
        let d = DigitalParam.defaultValues
        for id in ["sensor", "smear", "chroma_upsampling", "loss_pattern", "concealment", "bit_errors", "mosh_motion"] {
            XCTAssertEqual(d[id], 0, id)
        }
        // Formats, and looks saved before the controls existed, don't name
        // them: they get the defaults.
        for f in DigitalFormat.all {
            let s = DigitalSettings(values: f.values)
            XCTAssertEqual(s["sensor"], 0); XCTAssertEqual(s["bit_errors"], 0); XCTAssertEqual(s["mosh_motion"], 0)
            XCTAssertNotNil(DigitalFormat.matching(values: s.values, width: f.width), f.id)
        }
        // Added motion alone (its speed isn't 0 by default) does nothing
        // until a motion is chosen.
        let base = DigitalSettings(values: plain.merging(["keyframe_interval": 1]) { _, n in n })
        var fast = base
        fast.values["mosh_speed"] = 1
        let a = DigitalVideoRenderer(), b = DigitalVideoRenderer()
        for n in 0..<12 { XCTAssertTrue(still(a, n, base) == still(b, n, fast), "frame \(n)") }
    }

    // MARK: - both fields

    func testWovenFieldsTakeAlternateLinesFromTwoMoments() {
        let optics = DigitalSettings(values: ["fields": 0])
        func sensed(_ n: Int) -> [UInt8] {
            var px = frame(n)
            return px.withUnsafeMutableBytes {
                DigitalVideoRenderer.sense($0.baseAddress!, width: size.width, height: size.height,
                                           rowBytes: size.width * 4, to: capture, optics: optics)
            }
        }
        let now = sensed(6), before = sensed(5)
        let woven = DigitalVideoRenderer.fields(now, before: before, size: capture, mode: .woven)
        let rowBytes = capture.width * 4
        for y in 0..<capture.height {
            let from = y % 2 == 0 ? now : before
            XCTAssertTrue(woven[(y * rowBytes)..<((y + 1) * rowBytes)] == from[(y * rowBytes)..<((y + 1) * rowBytes)], "line \(y)")
        }
        // The square moved between them: its edge is combed (adjacent lines
        // disagree) where a whole frame's is straight.
        func comb(_ p: [UInt8]) -> Int {
            var s = 0
            for y in 0..<(capture.height - 1) {
                for x in 0..<capture.width {
                    s += abs(Int(p[(y * capture.width + x) * 4 + 2]) - Int(p[((y + 1) * capture.width + x) * 4 + 2]))
                }
            }
            return s
        }
        XCTAssertGreaterThan(comb(woven), comb(now) + 2000)
        // Blended: the comb is mixed away into a double edge.
        let blended = DigitalVideoRenderer.fields(now, before: before, size: capture, mode: .blended)
        XCTAssertLessThan(comb(blended), comb(woven))
        XCTAssertNotEqual(blended, now)
        // With nothing before it (a still), the frame is whole.
        XCTAssertEqual(DigitalVideoRenderer.fields(now, before: now, size: capture, mode: .woven), now)
        XCTAssertEqual(DigitalVideoRenderer.fields(now, before: nil, size: capture, mode: .woven), now)
    }

    func testInterlacedFramesLookTheSameJumpedToAsPlayed() {
        for mode in [2.0, 3.0] {
            checkJumpsMatchPlaying(settings("minidv", ["fields": mode]), cut: 20, "fields \(mode), each frame alone")
            checkJumpsMatchPlaying(settings("video_call", ["fields": mode, "keyframe_interval": 0.5, "frame_rate": 30]),
                                   cut: 20, "fields \(mode), predicted")
            // A camera slower than the clip: the earlier field is still the
            // source frame just before the capture's.
            checkJumpsMatchPlaying(settings("webcam", ["fields": mode, "frame_rate": 15]), cut: 20,
                                   "fields \(mode), 15 fps")
        }
    }

    func testInterlacedFramesDifferFromProgressiveOnlyWhereThingsMove() {
        let woven = played(DigitalSettings(values: plain.merging(["fields": 2]) { _, n in n }), frames: 6)
        let whole = played(DigitalSettings(values: plain), frames: 6)
        XCTAssertTrue(woven[0] == whole[0], "the first frame has nothing before it")
        XCTAssertGreaterThan(meanDifference(woven[5], whole[5]), 0.2)
        // A still never combs.
        let a = DigitalVideoRenderer(), b = DigitalVideoRenderer()
        for n in 0..<4 {
            XCTAssertTrue(still(a, n, DigitalSettings(values: plain.merging(["fields": 2]) { _, n in n }))
                            == still(b, n, DigitalSettings(values: plain)), "frame \(n)")
        }
    }

    // MARK: - one chip

    func testOneChipKeepsFlatColorAndFringesEdges() {
        let w = 64, h = 32
        // Flat color: every pixel's guesses are right.
        var flat = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { flat[i * 4] = 40; flat[i * 4 + 1] = 120; flat[i * 4 + 2] = 200 }
        var out = flat
        DigitalVideoRenderer.mosaic(&out, width: w, height: h)
        XCTAssertEqual(out, flat)
        // A gray edge, one pixel off the mosaic's grid: beside it the three
        // colors are guessed from different places, so gray turns colored;
        // away from it nothing changes.
        var edge = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v: UInt8 = x < 31 ? 30 : 220; for c in 0..<3 { edge[(y * w + x) * 4 + c] = v } } }
        out = edge
        DigitalVideoRenderer.mosaic(&out, width: w, height: h)
        var falseColor = 0
        for y in 0..<h {
            for x in 0..<w {
                let p = pixel(out, x, y, width: w)
                let spread = max(p.r, p.g, p.b) - min(p.r, p.g, p.b)
                if (29...32).contains(x) { falseColor = max(falseColor, spread) } else { XCTAssertEqual(spread, 0, "(\(x), \(y))") }
            }
        }
        XCTAssertGreaterThan(falseColor, 60)
    }

    func testOneChipReadsItsColorsFromOnePlace() {
        // Three chips read red and blue a third of a pixel either side of
        // green (the rainbow moiré); one chip has no prism to offset them, so
        // before its mosaic the aliased reading of gray stripes stays gray.
        var px = stripes()
        let three = px.withUnsafeMutableBytes {
            DigitalVideoRenderer.sense($0.baseAddress!, width: 640, height: 64, rowBytes: 640 * 4, to: (160, 16),
                                       optics: DigitalSettings(values: ["aliasing": 0.5, "sensor": 0]))
        }
        XCTAssertTrue((0..<(160 * 16)).contains { three[$0 * 4] != three[$0 * 4 + 2] })
        // (With the mosaic the colors come back another way: from its guesses.)
        let one = px.withUnsafeMutableBytes {
            DigitalVideoRenderer.sense($0.baseAddress!, width: 640, height: 64, rowBytes: 640 * 4, to: (160, 16),
                                       optics: DigitalSettings(values: ["aliasing": 0.5, "sensor": 1]))
        }
        XCTAssertNotEqual(one, three)
    }

    // MARK: - vertical smear

    func testSmearStreaksTheColumnsOfBrightSpots() {
        let w = 96, h = 64
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) { for c in 0..<3 { px[i * 4 + c] = 25 } }
        for y in 28..<34 { for x in 40..<44 { for c in 0..<3 { px[(y * w + x) * 4 + c] = 255 } } }   // a lamp
        let g = CodecGeometry(width: w, height: h, chroma: .full)
        func luma(_ smear: Double) -> CodecPicture {
            DigitalVideoRenderer.capture(px, geometry: g, settings: DigitalSettings(values: [
                "sensor_noise": 0, "noise_reduction": 0, "smear": smear]), index: 0)
        }
        let none = luma(0), full = luma(1), half = luma(0.5)
        func y(_ p: CodecPicture, _ x: Int, _ yy: Int) -> Float { p.y.data[yy * p.y.width + x] }
        // The lamp's columns are lifted from top to bottom; others aren't.
        for yy in [2, 15, 50, 62] {
            XCTAssertGreaterThan(y(full, 41, yy), y(none, 41, yy) + 25, "row \(yy)")
            XCTAssertEqual(y(full, 10, yy), y(none, 10, yy), accuracy: 0.01)
            XCTAssertGreaterThan(y(full, 41, yy), y(half, 41, yy) + 5)
            XCTAssertGreaterThan(y(half, 41, yy), y(none, 41, yy) + 5)
        }
        // Nothing bright, nothing to smear.
        var dim = px
        for i in 0..<(w * h * 4) where dim[i] == 255 && i % 4 != 3 { dim[i] = 200 }
        XCTAssertNil(DigitalVideoRenderer.smear(dim, width: w, height: h, strength: 1))
        // A bright scene's camera has stopped down: the same lamp smears less.
        var day = px
        for i in 0..<(w * h) where day[i * 4] == 25 { for c in 0..<3 { day[i * 4 + c] = 180 } }
        let night = DigitalVideoRenderer.smear(px, width: w, height: h, strength: 1)!
        let sunny = DigitalVideoRenderer.smear(day, width: w, height: h, strength: 1)!
        XCTAssertGreaterThan(night[41], sunny[41] * 2)
    }

    // MARK: - blocky color

    func testBlockyColorDecodeRepeatsEachColorSample() {
        let w = 64, h = 32
        let g = CodecGeometry(width: w, height: h, chroma: .quarterWide)
        let pic = CodecPicture(geometry: g)
        for i in 0..<(pic.y.width * pic.y.height) { pic.y.data[i] = 128 }
        // Color stepping from one sample to the next.
        for cy in 0..<pic.cb.height { for cx in 0..<pic.cb.width { pic.cr.data[cy * pic.cr.width + cx] = cx % 2 == 0 ? 80 : 180 } }
        func reds(_ blocky: Double) -> [Int] {
            let out = DigitalVideoRenderer.render(pic, geometry: g, settings: DigitalSettings(values: [
                "chroma": 3, "chroma_upsampling": blocky]), step: 1)
            return (0..<w).map { Int(out[(8 * w + $0) * 4 + 2]) }
        }
        let blocky = reds(1), smooth = reds(0)
        // Blocky: four pixels the same, then a jump.
        for x in stride(from: 0, to: w, by: 4) { XCTAssertEqual(Set(blocky[x..<(x + 4)]).count, 1, "x \(x)") }
        XCTAssertGreaterThan(abs(blocky[4] - blocky[3]), 100)
        // Smooth: a ramp between samples.
        XCTAssertGreaterThanOrEqual(Set(smooth[4..<(w - 4)]).count, 4)
        XCTAssertLessThan(abs(smooth[4] - smooth[3]), 60)
        // Full-resolution color has nothing to scale: the control does nothing.
        let g4 = CodecGeometry(width: w, height: h, chroma: .full)
        let p4 = CodecPicture(geometry: g4)
        for i in 0..<(p4.cr.width * p4.cr.height) { p4.cr.data[i] = Float(80 + (i * 37) % 100) }
        XCTAssertEqual(DigitalVideoRenderer.render(p4, geometry: g4, settings: DigitalSettings(values: ["chroma": 0, "chroma_upsampling": 1]), step: 1),
                       DigitalVideoRenderer.render(p4, geometry: g4, settings: DigitalSettings(values: ["chroma": 0, "chroma_upsampling": 0]), step: 1))
    }

    // MARK: - loss patterns

    func testDVTracksLieOverFiveRectanglesAndHeadsOwnAlternateBands() {
        // DV's own size: 45 × 30 macroblocks, superblocks 9 × 3.
        let g = CodecGeometry(width: 720, height: 480, chroma: .quarterWide)
        // Every macroblock belongs to exactly one superblock.
        var seen = [Int](repeating: 0, count: g.mbCount)
        for r in 0..<10 { for c in 0..<5 { for b in DigitalCodec.dvSuperblock(row: r, column: c, geometry: g) { seen[b] += 1 } } }
        XCTAssertEqual(Set(seen), [1])
        // A whole track: five superblocks, one in each column, on rows of
        // the track's own parity.
        for track in 0..<10 {
            var lost = [Bool](repeating: false, count: g.mbCount)
            DigitalCodec.loseDVStretch(track: track, from: 0, to: 1, geometry: g, into: &lost)
            XCTAssertEqual(lost.filter { $0 }.count, 5 * 27, "track \(track)")
            var columns = Set<Int>(), rows = Set<Int>()
            for i in 0..<g.mbCount where lost[i] {
                columns.insert((i % g.mbCols) / 9)
                rows.insert((i / g.mbCols) / 3)
            }
            XCTAssertEqual(columns.count, 5)
            XCTAssertEqual(rows.count, 5)
            XCTAssertTrue(rows.allSatisfy { $0 % 2 == track % 2 }, "track \(track): rows \(rows.sorted())")
        }
        // A short stretch: the same few blocks of each of the five.
        var lost = [Bool](repeating: false, count: g.mbCount)
        DigitalCodec.loseDVStretch(track: 3, from: 0.5, to: 0.55, geometry: g, into: &lost)
        XCTAssertEqual(lost.filter { $0 }.count, 5 * 2)
        // A clogged head, fully: every odd band, and only those.
        let dirty = (0..<40).filter { $0 % DigitalCodec.tapeRefresh != 0 }
        for index in dirty {
            let mask = DigitalCodec.lostBlocks(amount: 1, index: index, geometry: g, pattern: .cloggedHead)!
            for i in 0..<g.mbCount where mask[i] { XCTAssertEqual((i / g.mbCols) / 3 % 2, 1) }
        }
        let share = dirty.map { DigitalCodec.lostBlocks(amount: 1, index: $0, geometry: g, pattern: .cloggedHead)!.filter { $0 }.count }
        XCTAssertGreaterThan(Double(share.reduce(0, +)) / Double(dirty.count * g.mbCount / 2), 0.85, "nearly all of the odd bands")
        // Now and then the tape reads clean, so a held patch never reaches
        // back further than that.
        for p in [DigitalCodec.LossPattern.dvTape, .cloggedHead] {
            XCTAssertNil(DigitalCodec.lostBlocks(amount: 1, index: 0, geometry: g, pattern: p))
            XCTAssertNil(DigitalCodec.lostBlocks(amount: 1, index: DigitalCodec.tapeRefresh, geometry: g, pattern: p))
        }
        // And small pictures still work (fewer superblocks than DV has).
        let tiny = CodecGeometry(width: 128, height: 96, chroma: .halfBoth)
        for p in [DigitalCodec.LossPattern.dvTape, .cloggedHead] {
            XCTAssertNotNil((1..<20).compactMap { DigitalCodec.lostBlocks(amount: 1, index: $0, geometry: tiny, pattern: p) }.first)
        }
    }

    func testTapePatternsHoldTheLastGoodPicture() {
        // Each frame on its own (DV). A fully clogged head's bands never get
        // new data: they stay at the first frame while the rest moves on.
        let clean = settings("minidv", ["sensor_noise": 0, "fields": 0, "aliasing": 0, "sharpening": 0, "ccd_response": 0])
        let clogged = DigitalSettings(values: clean.values.merging(["data_loss": 1, "loss_pattern": 2]) { _, n in n })
        let a = played(clean, frames: 14), b = played(clogged, frames: 14)
        XCTAssertTrue(a[0] == b[0], "the first frame has nothing to hold")
        let g = CodecGeometry(width: capture.width, height: capture.height, chroma: .quarterWide)
        var held = 0, lostSeen = 0
        for my in 0..<g.mbRows {
            for mx in 0..<g.mbCols {
                // Lost on every frame so far: still showing frame 0.
                guard (1...13).allSatisfy({ DigitalCodec.lostBlocks(amount: 1, index: $0, geometry: g, pattern: .cloggedHead)?[my * g.mbCols + mx] == true })
                else { continue }
                lostSeen += 1
                let k = size.width / capture.width
                var same = true
                for y in (my * 16 * k)..<min(size.height, (my + 1) * 16 * k) {
                    for x in (mx * 16 * k)..<min(size.width, (mx + 1) * 16 * k) where same {
                        let i = (y * size.width + x) * 4
                        same = b[13][i] == a[0][i] && b[13][i + 1] == a[0][i + 1] && b[13][i + 2] == a[0][i + 2]
                    }
                }
                if same { held += 1 }
            }
        }
        XCTAssertGreaterThan(lostSeen, 4)
        XCTAssertEqual(held, lostSeen, "blocks lost every frame still show the first")
        // Packets patch from the frame before instead: one frame stale.
        checkJumpsMatchPlaying(clogged, frames: 60, "clogged head")
        checkJumpsMatchPlaying(DigitalSettings(values: clean.values.merging(["data_loss": 0.7, "loss_pattern": 1]) { _, n in n }),
                               frames: 60, "DV tape")
    }

    // MARK: - what lost blocks show

    func testConcealmentFillsLostBlocks() {
        let base = settings("minidv", ["sensor_noise": 0, "fields": 0, "aliasing": 0, "sharpening": 0,
                                       "ccd_response": 0, "saturation": 1, "white_balance": 0, "tint": 0,
                                       "data_loss": 0.9, "chroma": 0])
        let g = CodecGeometry(width: capture.width, height: capture.height, chroma: .full)
        let n = 4
        let lost = DigitalCodec.lostBlocks(amount: 0.9, index: n, geometry: g)!
        func shown(_ mode: Double) -> [UInt8] {
            small(played(DigitalSettings(values: base.values.merging(["concealment": mode]) { _, n in n }), frames: n + 1)[n])
        }
        let patch = shown(0), gray = shown(1), green = shown(2), stretched = shown(3)
        var checked = 0
        for my in 1..<g.mbRows {
            for mx in 0..<g.mbCols where lost[my * g.mbCols + mx] {
                checked += 1
                for (dx, dy) in [(0, 0), (15, 15), (7, 9)] {
                    let x = mx * 16 + dx, y = my * 16 + dy
                    guard x < capture.width, y < capture.height else { continue }
                    let a = pixel(gray, x, y, width: capture.width)
                    XCTAssertTrue(a == (128, 128, 128), "gray at (\(x), \(y)): \(a)")
                    let b = pixel(green, x, y, width: capture.width)
                    XCTAssertTrue(b.g > 100 && b.r == 0 && b.b == 0, "green at (\(x), \(y)): \(b)")
                    // Stretched: the same as the pixel above, all the way up
                    // to the row over the gap.
                    let c = pixel(stretched, x, y, width: capture.width)
                    let above = pixel(stretched, x, y - 1, width: capture.width)
                    if dy > 0 { XCTAssertTrue(c == above, "stretched at (\(x), \(y))") }
                }
            }
        }
        XCTAssertGreaterThan(checked, 3)
        XCTAssertNotEqual(patch, gray)
        // Where nothing was lost, all four agree.
        for my in 0..<g.mbRows {
            for mx in 0..<g.mbCols where !lost[my * g.mbCols + mx] {
                let x = mx * 16 + 8, y = my * 16 + 8
                guard x < capture.width, y < capture.height else { continue }
                XCTAssertTrue(pixel(patch, x, y, width: capture.width) == pixel(green, x, y, width: capture.width))
            }
        }
        // Between keyframes too, and the same however reached.
        for mode in [1.0, 2.0, 3.0] {
            checkJumpsMatchPlaying(settings("video_call", ["keyframe_interval": 0.5, "frame_rate": 30, "data_loss": 0.6,
                                                           "concealment": mode]), cut: 16, "concealment \(mode)")
        }
    }

    // MARK: - bit errors

    func testBitErrorsAreWhatWrongCoefficientsDecodeTo() {
        let g = CodecGeometry(width: 64, height: 48, chroma: .halfBoth)
        func flat() -> CodecPicture {
            let p = CodecPicture(geometry: g)
            for i in 0..<(p.y.width * p.y.height) { p.y.data[i] = 100 }
            return p
        }
        // A wrong coefficient: its cosine pattern in that block, nothing
        // outside it — the same as decoding the block with it.
        var p = flat()
        DigitalCodec.damage(p, with: [.coefficient(plane: 0, tileX: 2, tileY: 1, u: 3, v: 0, amount: 400)], geometry: g)
        var coef = [Float](repeating: 0, count: 64), block = coef, tmp = coef
        coef[0] = (100 - 128) * 8; coef[3] = 400
        DigitalCodec.basis.withUnsafeBufferPointer { DigitalCodec.inverseDCT(coef, &block, stride: 8, &tmp, $0.baseAddress!) }
        for y in 0..<p.y.height {
            for x in 0..<p.y.width {
                let v = p.y.data[y * p.y.width + x]
                if (16..<24).contains(x), (8..<16).contains(y) {
                    XCTAssertEqual(v, (block[(y - 8) * 8 + (x - 16)] + 128).rounded().clamped(0, 255), accuracy: 0.01)
                } else {
                    XCTAssertEqual(v, 100)
                }
            }
        }
        // A wrong average: that macroblock's row from there on.
        p = flat()
        DigitalCodec.damage(p, with: [.average(plane: 0, mbX: 2, mbY: 1, amount: 50, toEnd: false)], geometry: g)
        for y in 0..<g.lumaH {
            for x in 0..<g.lumaW {
                XCTAssertEqual(p.y.data[y * p.y.width + x], (16..<32).contains(y) && x >= 32 ? 150 : 100, "(\(x), \(y))")
            }
        }
        // …or, with nothing to reset it, the rest of the picture.
        p = flat()
        DigitalCodec.damage(p, with: [.average(plane: 0, mbX: 2, mbY: 1, amount: 50, toEnd: true)], geometry: g)
        XCTAssertEqual(p.y.data[40 * p.y.width + 5], 150)
        XCTAssertEqual(p.y.data[20 * p.y.width + 5], 100)
        // The rest of a row displaced.
        p = flat()
        for x in 0..<g.lumaW { for y in 0..<g.lumaH { p.y.data[y * p.y.width + x] = Float(x) } }
        DigitalCodec.damage(p, with: [.displaced(mbX: 1, mbY: 0, by: 1)], geometry: g)
        XCTAssertEqual(p.y.data[40], 24, "row 0: block 2 shows block 1's pixels")
        XCTAssertEqual(p.y.data[20], 20, "the first block of the gap keeps what it had")
        XCTAssertEqual(p.y.data[16 * p.y.width + 40], 40, "the next row is untouched")
    }

    func testBitErrorsFlashAloneAndLingerBetweenKeyframes() {
        // Each frame on its own: damage, and none of it carried over.
        let clean = settings("minidv", ["sensor_noise": 0])
        let hurt = DigitalSettings(values: clean.values.merging(["bit_errors": 0.6]) { _, n in n })
        let a = played(clean, frames: 6), b = played(hurt, frames: 6)
        XCTAssertGreaterThan((0..<6).filter { a[$0] != b[$0] }.count, 3)
        // More is more.
        let worse = played(DigitalSettings(values: clean.values.merging(["bit_errors": 1]) { _, n in n }), frames: 6)
        let mild = played(DigitalSettings(values: clean.values.merging(["bit_errors": 0.2]) { _, n in n }), frames: 6)
        func total(_ p: [[UInt8]]) -> Double { (0..<6).map { meanDifference(a[$0], p[$0]) }.reduce(0, +) }
        XCTAssertGreaterThan(total(worse), total(b))
        XCTAssertGreaterThan(total(b), total(mild))
        XCTAssertGreaterThan(total(mild), 0)
        // Between keyframes: gone at each keyframe, building in between.
        let stream = settings("early_web", ["keyframe_interval": 0.5, "frame_rate": 30, "fixed_bitrate": 0])
        let damaged = DigitalSettings(values: stream.values.merging(["bit_errors": 0.5]) { _, n in n })
        let c = played(stream, frames: 31), d = played(damaged, frames: 31)
        XCTAssertTrue(c[0] == d[0]); XCTAssertTrue(c[15] == d[15]); XCTAssertTrue(c[30] == d[30])
        XCTAssertGreaterThan(meanDifference(c[14], d[14]), meanDifference(c[2], d[2]))
        checkJumpsMatchPlaying(damaged, cut: 16, "bit errors, predicted")
        checkJumpsMatchPlaying(hurt, cut: 16, "bit errors, each frame alone")
    }

    // MARK: - added motion

    func testAddedMotionAveragesItsSpeedInWholePixels() {
        let g = CodecGeometry(width: 320, height: 240, chroma: .halfBoth)
        // Pan at 100%: a fortieth of the width (8 px) every frame, every block.
        let pan = DigitalCodec.addedMotion(kind: 1, speed: 1, index: 5, geometry: g)!
        XCTAssertTrue(pan.allSatisfy { $0.dx == -8 && $0.dy == 0 })
        // A slow one moves on some frames only, and adds up right.
        var moved = 0
        for k in 1...80 { moved += Int(DigitalCodec.addedMotion(kind: 1, speed: 0.05, index: k, geometry: g)?[0].dx ?? 0) }
        XCTAssertEqual(moved, -32, "0.4 px a frame for 80 frames")
        // Zoom: outward from the middle, nothing at the middle.
        let zoom = DigitalCodec.addedMotion(kind: 3, speed: 1, index: 5, geometry: g)!
        let left = zoom[7 * g.mbCols], right = zoom[7 * g.mbCols + g.mbCols - 1]
        XCTAssertGreaterThan(left.dx, 0); XCTAssertLessThan(right.dx, 0)     // (vectors point at where a block reads from)
        // Swirl: across at the top and bottom, opposite ways.
        let swirl = DigitalCodec.addedMotion(kind: 4, speed: 1, index: 5, geometry: g)!
        XCTAssertEqual(swirl[10].dx.signum(), -swirl[(g.mbRows - 1) * g.mbCols + 10].dx.signum())
        XCTAssertNotEqual(swirl[10].dx, 0)
        // Off, or at no speed: nothing.
        XCTAssertNil(DigitalCodec.addedMotion(kind: 0, speed: 1, index: 5, geometry: g))
        XCTAssertNil(DigitalCodec.addedMotion(kind: 1, speed: 0, index: 5, geometry: g))
    }

    func testAddedMotionMeltsAStillUntilTheNextKeyframe() {
        // A still: bars, so sideways motion shows.
        let (w, h) = size
        var bars = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v: UInt8 = (x / 32) % 2 == 0 ? 40 : 210; for c in 0..<3 { bars[(y * w + x) * 4 + c] = v } } }
        let base = DigitalSettings(values: plain.merging(["keyframe_interval": 0.5, "chroma": 2]) { _, n in n })
        let pan = DigitalSettings(values: base.values.merging(["mosh_motion": 1, "mosh_speed": 0.5]) { _, n in n })
        let a = DigitalVideoRenderer(), b = DigitalVideoRenderer()
        let calm = (0..<31).map { still(a, $0, base, picture: bars) }
        let pushed = (0..<31).map { still(b, $0, pan, picture: bars) }
        // Keyframes (0, 15, 30) put it right; in between it slides further
        // every frame.
        XCTAssertTrue(calm[0] == pushed[0]); XCTAssertTrue(calm[15] == pushed[15]); XCTAssertTrue(calm[30] == pushed[30])
        XCTAssertGreaterThan(meanDifference(calm[4], pushed[4]), 2)
        XCTAssertGreaterThan(meanDifference(calm[10], pushed[10]), meanDifference(calm[4], pushed[4]))
        // It's the picture moved, not noise: 10 frames at 1.6 px a frame is
        // 16 px to the right (at the capture's 128 across).
        let moved = small(pushed[10]), orig = small(calm[10])
        var agree = 0, count = 0
        for x in 32..<120 {
            count += 1
            if abs(Int(moved[(40 * capture.width + x) * 4 + 1]) - Int(orig[(40 * capture.width + x - 16) * 4 + 1])) < 30 { agree += 1 }
        }
        XCTAssertGreaterThan(Double(agree) / Double(count), 0.9)
        // With the keyframes thrown away it never comes back.
        let mosh = DigitalSettings(values: pan.values.merging(["datamosh": 1]) { _, n in n })
        let c = DigitalVideoRenderer()
        let melted = (0..<31).map { still(c, $0, mosh, picture: bars) }
        XCTAssertGreaterThan(meanDifference(calm[30], melted[30]), 2)
        // A frame jumped to is the frame played to.
        for n in [22, 7, 30] { XCTAssertTrue(still(DigitalVideoRenderer(), n, mosh, picture: bars) == melted[n], "frame \(n)") }
        // On a clip it rides on the clip's own motion.
        checkJumpsMatchPlaying(settings("datamosh", ["keyframe_interval": 0.5, "mosh_motion": 4, "mosh_speed": -0.7]),
                               cut: 16, "swirl on a clip")
    }
}
