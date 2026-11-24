import XCTest
import Metal
import AVFoundation
@testable import CrtCore

/// One frame index means one picture on every path: counting decoded frames
/// from the start (playback, exports), scrubbing to the index, and starting
/// a reader there. The clips carry their frame number in the picture (twelve
/// black or white columns, one per bit), so each path's frame can be read
/// back. At 29.97 and 23.976 fps the paths that ask the decoder for a time
/// used to ask for index / round(fps): the frame before from index 1, two
/// before from index 1001.
final class VideoFrameTimeTests: XCTestCase {

    private var context: MetalContext!
    private var tmp: URL!

    override func setUpWithError() throws {
        context = try MetalContext()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("frametime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: the clip

    private static let width = 288, height = 160, bits = 12

    /// `frames` frames, each `frameDuration` long, numbered in the picture.
    /// The file keeps time in `frameDuration`'s units unless `timescale`
    /// says otherwise (600: frame times rounded to 1/600 s).
    private func makeClip(_ name: String, frames: Int, frameDuration: CMTime,
                          timescale: CMTimeScale? = nil) async throws -> VideoSource {
        let url = tmp.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Self.width, AVVideoHeightKey: Self.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 400_000,
                                              AVVideoMaxKeyFrameIntervalKey: 60],
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Self.width, kCVPixelBufferHeightKey as String: Self.height,
        ])
        input.mediaTimeScale = timescale ?? frameDuration.timescale
        writer.add(input)
        XCTAssertTrue(writer.startWriting(), "\(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)
        let column = Self.width / Self.bits
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adaptor.pixelBufferPool), &made)
            let pb = try XCTUnwrap(made)
            CVPixelBufferLockBaseAddress(pb, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
            let rowBytes = CVPixelBufferGetBytesPerRow(pb)
            for x in 0..<Self.width {
                let v: UInt8 = (i >> (x / column)) & 1 == 1 ? 235 : 16
                for c in 0..<3 { base[x * 4 + c] = v }
                base[x * 4 + 3] = 255
            }
            for y in 1..<Self.height { memcpy(base + y * rowBytes, base, Self.width * 4) }
            CVPixelBufferUnlockBaseAddress(pb, [])
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(i))))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames)))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return try await VideoSource(url: url, device: context.device)
    }

    // MARK: reading a frame's number

    private func number(bgra px: UnsafePointer<UInt8>, rowBytes: Int) -> Int {
        let column = Self.width / Self.bits
        var n = 0
        for b in 0..<Self.bits where px[(Self.height / 2) * rowBytes + (b * column + column / 2) * 4 + 1] > 128 {
            n |= 1 << b
        }
        return n
    }

    private func number(_ texture: MTLTexture) -> Int {
        XCTAssertEqual(texture.width, Self.width)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return number(bgra: bytes, rowBytes: texture.width * 4)
    }

    private func number(_ image: CGImage) throws -> Int {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return number(bgra: bytes, rowBytes: image.width * 4)
    }

    // MARK: every path, the same frame

    private func checkEveryPath(_ clip: VideoSource, frames: Int, frameDuration: CMTime,
                                indices: [Int], timeAccuracy: Double = 1e-6, _ label: String) async throws {
        XCTAssertEqual(clip.totalFrames, frames, label)
        XCTAssertEqual(clip.frameSeconds, frameDuration.seconds, accuracy: timeAccuracy / Double(frames), label)

        // Counting from the start, as playback and the exporters do.
        let reader = try clip.makeSequentialReader()
        var count = 0, times: [Double] = []
        while let frame = reader.nextFrame() {
            if number(frame.texture) != count { XCTFail("\(label): decoded frame \(count) shows \(number(frame.texture))") }
            times.append(frame.presentationTime.seconds)
            count += 1
        }
        XCTAssertEqual(count, frames, label)

        for i in indices {
            // The index's time is the time the decoder gives that frame.
            XCTAssertEqual(clip.seconds(ofFrame: i), times[i], accuracy: timeAccuracy, "\(label): frame \(i)'s time")
            XCTAssertEqual(clip.time(ofFrame: i).seconds, times[i], accuracy: timeAccuracy, "\(label): frame \(i)'s time")
            // Scrubbing.
            let scrubbed = try await clip.frame(atIndex: i)
            XCTAssertEqual(number(scrubbed), i, "\(label): scrubbed to \(i)")
            let whole = try await clip.cgImage(atIndex: i)
            XCTAssertEqual(try number(whole), i, "\(label): the whole frame at \(i)")
            // A reader starting there, and the frame after it.
            let from = try clip.makeSequentialReader(startingAtFrame: i)
            let first = try XCTUnwrap(from.nextFrame(), "\(label): a reader from \(i)")
            XCTAssertEqual(number(first.texture), i, "\(label): a reader from \(i)")
            XCTAssertEqual(first.presentationTime.seconds, times[i], accuracy: timeAccuracy, "\(label): a reader from \(i)")
            if i + 1 < frames {
                XCTAssertEqual(number(try XCTUnwrap(from.nextFrame()).texture), i + 1, "\(label): after \(i)")
            }
        }
    }

    func testAt2997FpsEveryPathShowsTheSameFrame() async throws {
        let d = CMTime(value: 1001, timescale: 30000)
        let clip = try await makeClip("2997.mp4", frames: 1300, frameDuration: d)
        XCTAssertEqual(clip.frameRate, 29.97, accuracy: 0.001)
        // 1 and 1001 are where index / 30 falls one and two frames short;
        // 1299 is the last frame, past the end by that rule's reckoning.
        try await checkEveryPath(clip, frames: 1300, frameDuration: d,
                                 indices: [0, 1, 2, 29, 30, 500, 1000, 1001, 1002, 1298, 1299], "29.97")
    }

    func testAt23976FpsEveryPathShowsTheSameFrame() async throws {
        let d = CMTime(value: 1001, timescale: 24000)
        let clip = try await makeClip("23976.mp4", frames: 1100, frameDuration: d)
        try await checkEveryPath(clip, frames: 1100, frameDuration: d,
                                 indices: [0, 1, 23, 24, 999, 1000, 1001, 1099], "23.976")
    }

    /// A file that keeps time in 1/600 s can't hold 1001/30000: its frames
    /// sit up to 0.8 ms off the grid, and its shortest frame (1/30 s) isn't
    /// the spacing. Still the same frame on every path.
    func testAt2997FpsInAFileWithCoarseTimeEveryPathShowsTheSameFrame() async throws {
        let d = CMTime(value: 1001, timescale: 30000)
        let clip = try await makeClip("2997-600.mp4", frames: 1300, frameDuration: d, timescale: 600)
        try await checkEveryPath(clip, frames: 1300, frameDuration: d,
                                 indices: [0, 1, 2, 500, 1000, 1001, 1002, 1299], timeAccuracy: 1e-3, "29.97 in 1/600 s")
    }

    func testWholeFrameRatesAreUnchanged() async throws {
        let d = CMTime(value: 1, timescale: 25)
        let clip = try await makeClip("25.mp4", frames: 80, frameDuration: d)
        try await checkEveryPath(clip, frames: 80, frameDuration: d, indices: [0, 1, 24, 25, 26, 79], "25")
    }

    /// Playback started mid-clip (the reader's start time, then counting):
    /// the frame it calls N is frame N, at frame N's time.
    func testPlaybackStartedMidClipNumbersItsFramesAsScrubbingDoes() async throws {
        let d = CMTime(value: 1001, timescale: 30000)
        let clip = try await makeClip("play.mp4", frames: 1100, frameDuration: d)
        let config = PlaybackPipeline.Config(enabled: false, baseJSON: nil, perFrameJSON: nil, generation: 0, digital: nil)
        let pipe = PlaybackPipeline(source: clip, device: context.device, startFrame: 1050, config: config)
        pipe.start()
        defer { pipe.stop() }
        for expected in 1050..<1056 {
            var out: PlaybackPipeline.Output?
            for _ in 0..<300 where out == nil {
                out = pipe.takeOldest(generation: 0)
                if out == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            let frame = try XCTUnwrap(out)
            XCTAssertEqual(frame.frameIndex, expected)
            XCTAssertEqual(number(frame.clean), expected, "playback's frame \(expected)")
            XCTAssertEqual(frame.mediaTime, clip.seconds(ofFrame: expected), accuracy: 1e-6)
        }
    }

    // MARK: which frame length

    func testTheTracksFrameLengthIsUsedOnlyWhenItFitsTheClip() {
        func length(_ value: CMTimeValue, _ scale: CMTimeScale, rate: Double, seconds: Double,
                    span: (steps: Int, seconds: Double)?) -> (seconds: Double, exact: CMTime?) {
            VideoSource.frameLength(minFrameDuration: CMTime(value: value, timescale: scale),
                                    nominalRate: rate, durationSeconds: seconds, sampleSpan: span)
        }
        let ntsc = CMTime(value: 1001, timescale: 30000)
        // Constant rate: the track's own fraction (an hour of 29.97).
        XCTAssertEqual(length(1001, 30000, rate: 29.97003, seconds: 3600.0,
                              span: (107891, 107891 * 1001.0 / 30000)).exact, ntsc)
        // A long last frame lowers a short clip's average rate; the frames
        // before it are where the track says.
        XCTAssertEqual(length(1, 30, rate: 100 / (101.0 / 30), seconds: 101.0 / 30, span: (99, 99.0 / 30)).exact,
                       CMTime(value: 1, timescale: 30))
        // 29.97 kept in 1/600 s: the shortest frame is 1/30 s, the spacing
        // isn't. Whatever the length of the clip, the middle of frame i by
        // the chosen length is inside frame i.
        for frames in [100, 200, 300, 500, 1000, 2098] {
            let times = (0..<frames).map { (Double($0) * 1001 / 30000 * 600).rounded() / 600 }
            let l = length(20, 600, rate: 29.97, seconds: times[frames - 1] + 1.0 / 30, span: (frames - 1, times[frames - 1]))
            for i in 0..<(frames - 1) {
                let middle = (Double(i) + 0.5) * l.seconds
                if middle < times[i] || middle >= times[i + 1] { XCTFail("\(frames) frames: frame \(i)'s middle is outside it") }
            }
            if frames > 300 { XCTAssertNil(l.exact, "\(frames) frames") }
        }
        // Frames of varying length (a phone, a screen recording): the
        // average spacing, not the shortest frame.
        let varying = length(1, 60, rate: 29.83, seconds: 60, span: (1789, 59.97))
        XCTAssertNil(varying.exact)
        XCTAssertEqual(varying.seconds, 59.97 / 1789, accuracy: 1e-12)
        // No sample table: the track's fraction only when it fits the
        // clip's length; else the nominal rate.
        XCTAssertEqual(length(1001, 30000, rate: 29.97003, seconds: 660.66, span: nil).exact, ntsc)
        XCTAssertNil(length(20, 600, rate: 29.97, seconds: 70, span: nil).exact)
        XCTAssertEqual(length(20, 600, rate: 29.97, seconds: 70, span: nil).seconds, 1 / 29.97, accuracy: 1e-12)
        XCTAssertNil(length(1, 60, rate: 29.83, seconds: 60, span: nil).exact)
        // No usable track value either.
        let none = VideoSource.frameLength(minFrameDuration: .invalid, nominalRate: 25, durationSeconds: 10, sampleSpan: nil)
        XCTAssertNil(none.exact)
        XCTAssertEqual(none.seconds, 0.04, accuracy: 1e-12)
    }

    /// 29.97 in 1/600 s again, but short: a clip this length is within a
    /// frame of 30 fps by its length alone.
    func testAShortClipWithCoarseTimeShowsTheSameFrameOnEveryPath() async throws {
        let d = CMTime(value: 1001, timescale: 30000)
        let clip = try await makeClip("short-600.mp4", frames: 700, frameDuration: d, timescale: 600)
        try await checkEveryPath(clip, frames: 700, frameDuration: d,
                                 indices: [0, 1, 350, 520, 600, 698, 699], timeAccuracy: 1e-3, "29.97 in 1/600 s, short")
    }
}
