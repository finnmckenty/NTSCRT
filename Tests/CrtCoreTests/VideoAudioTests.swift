import XCTest
@testable import CrtCore

/// The rule a clip's sound follows while its picture plays (AudioSync).
final class VideoAudioTests: XCTestCase {

    /// Show `count` frames at `fps`, the picture running at `speed` × real
    /// time, from media time `from` and clock time `clock`. Returns what the
    /// sound was told, with the clock time of each instruction.
    private func play(_ sync: inout AudioSync, from: Double = 0, clock: Double = 100,
                      fps: Double = 30, speed: Double = 1, count: Int) -> [(at: Double, action: AudioSync.Action)] {
        var out: [(Double, AudioSync.Action)] = []
        for i in 0..<count {
            let h = clock + Double(i) / (fps * speed)
            let action = sync.frameShown(mediaTime: from + Double(i) / fps, clock: h)
            if action != .none { out.append((h, action)) }
        }
        return out
    }

    func testTheSoundStartsWithTheFirstFrameAndIsLeftAloneAtRealTime() {
        var sync = AudioSync()
        let told = play(&sync, from: 2.5, count: 300)
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?.action, .play(at: 2.5))
        XCTAssertFalse(sync.silent)
    }

    /// Frames arrive a little early or late (a display refresh, a busy
    /// moment) and some are dropped; none of that moves the sound.
    func testJitterAndDroppedFramesDontMoveTheSound() {
        var sync = AudioSync()
        var moves = 0
        for i in 0..<300 where i % 3 != 1 {             // every third frame dropped
            let jitter = Double((i * 7919) % 41 - 20) / 1000   // ±20 ms
            if sync.frameShown(mediaTime: Double(i) / 30, clock: 50 + Double(i) / 30 + jitter) != .none {
                moves += 1
            }
        }
        XCTAssertEqual(moves, 1, "only the start")
    }

    func testALoopWrapOrASeekStartsTheSoundThere() {
        var sync = AudioSync()
        _ = play(&sync, count: 60)                                   // 0…2 s
        // The clip wraps: the next frame is the first again.
        XCTAssertEqual(sync.frameShown(mediaTime: 0, clock: 102), .play(at: 0))
        // A seek forward.
        XCTAssertEqual(sync.frameShown(mediaTime: 7, clock: 102.033), .play(at: 7))
        XCTAssertFalse(sync.silent, "jumps say nothing about speed")
    }

    /// A clip shorter than a second wraps several times a second; that must
    /// not read as playback running slow.
    func testAShortLoopKeepsItsSound() {
        var sync = AudioSync()
        var clock = 10.0
        for _ in 0..<20 {
            for i in 0..<12 {                                        // 0.4 s at 30 fps
                let action = sync.frameShown(mediaTime: Double(i) / 30, clock: clock)
                XCTAssertNotEqual(action, .silence)
                if i == 0 { XCTAssertEqual(action, .play(at: 0)) }
                clock += 1.0 / 30
            }
        }
        XCTAssertFalse(sync.silent)
    }

    func testOneStallRestartsTheSoundWhereThePictureIs() {
        var sync = AudioSync()
        _ = play(&sync, count: 30)                                   // 0…1 s
        // Half a second goes by with nothing shown, then the next frame.
        XCTAssertEqual(sync.frameShown(mediaTime: 1.0, clock: 101.5), .play(at: 1.0))
        let after = play(&sync, from: 1.0 + 1.0 / 30, clock: 101.5 + 1.0 / 30, count: 300)
        XCTAssertTrue(after.isEmpty)
        XCTAssertFalse(sync.silent)
    }

    /// Playback slower than real time (the Digital video codec can't keep
    /// up): the sound goes quiet rather than restart several times a second.
    func testAPictureRunningSlowGoesSilent() {
        var sync = AudioSync()
        let told = play(&sync, speed: 0.6, count: 600)
        XCTAssertTrue(sync.silent)
        XCTAssertEqual(told.last?.action, .silence)
        // It starts, restarts once at the first slip, and goes quiet at the
        // second — within a second at this speed.
        XCTAssertEqual(told.count, 3)
        XCTAssertLessThan(told.last!.at - 100, 1.0)
    }

    func testTheSoundComesBackOnceThePictureHoldsRealTime() {
        var sync = AudioSync()
        _ = play(&sync, speed: 0.6, count: 120)
        XCTAssertTrue(sync.silent)
        // Real time from here (say the loop now plays from the frame cache).
        let clock = 100 + 120 / (30 * 0.6)
        let told = play(&sync, from: 4, clock: clock, count: 150)
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told[0].action, .play(at: 4 + (told[0].at - clock)), "it starts where the picture is by then")
        XCTAssertEqual(told[0].at - clock, AudioSync.resumeAfter, accuracy: 0.1)
        XCTAssertFalse(sync.silent)
    }

    /// Slightly slow counts too: it slips past the tolerance again and again.
    func testSlightlySlowPlaybackGoesSilentToo() {
        var sync = AudioSync()
        _ = play(&sync, speed: 0.95, count: 300)
        XCTAssertTrue(sync.silent)
    }

    func testResetForgetsEverything() {
        var sync = AudioSync()
        _ = play(&sync, speed: 0.5, count: 120)
        XCTAssertTrue(sync.silent)
        sync.reset()
        XCTAssertFalse(sync.silent)
        XCTAssertEqual(sync.frameShown(mediaTime: 3, clock: 500), .play(at: 3))
    }
}
