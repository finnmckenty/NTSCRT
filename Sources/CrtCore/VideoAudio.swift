import Foundation
import AVFoundation
import CrtAppBridge

/// Decides what a clip's sound does while its picture plays.
///
/// The picture is the master: playback shows frames on a wall-clock
/// schedule, loops, seeks, and slows down when a stage can't keep up (the
/// Digital video codec, a rotated clip's seek-decode). The sound follows
/// it. Told when each frame is shown, this keeps the line the sound runs
/// along (media time against the clock) and says when to move it:
///
///   - the picture jumped (a seek, the loop's wrap): start again there;
///   - the picture slipped behind the clock once (a stall): start again
///     where it is;
///   - it keeps slipping (playback slower than real time): be silent until
///     it has held real time for a while — sound that restarts several
///     times a second is worse than none, and After Effects mutes a
///     preview that isn't real time for the same reason.
///
/// No player in here, so it can be tested.
public struct AudioSync {
    public enum Action: Equatable {
        case none
        /// Play from this media time, starting now.
        case play(at: Double)
        case silence
    }

    /// How far the picture may sit from the sound's line before the sound
    /// moves. Frames are shown within a display refresh of when they are
    /// due, so real-time playback stays well inside this.
    public static let tolerance = 0.08
    /// Two slips within this long means playback isn't real time.
    public static let slipWindow = 5.0
    /// Silent, the picture has to hold real time this long to get its
    /// sound back.
    public static let resumeAfter = 2.0

    private var anchor: (clock: Double, media: Double)?
    private var lastMedia = 0.0
    private var lastSlip: Double?
    /// When the picture last slipped (or playback began).
    private var steadySince = 0.0
    public private(set) var silent = false

    public init() {}

    /// Forget where the sound was (playback stopped, or restarted somewhere
    /// else): the next frame starts it.
    public mutating func reset() { self = AudioSync() }

    /// A frame with this media time went on screen at `clock` (seconds, any
    /// steady clock).
    public mutating func frameShown(mediaTime m: Double, clock h: Double) -> Action {
        guard let a = anchor else {
            anchor = (h, m)
            lastMedia = m
            steadySince = h
            return .play(at: m)
        }
        let error = m - (a.media + (h - a.clock))
        let backwards = m < lastMedia
        lastMedia = m
        let onLine = !backwards && abs(error) <= Self.tolerance
        if !onLine { anchor = (h, m) }
        // Behind the clock without having gone backwards: the picture ran
        // slow. Anything else off the line is a jump (a seek, the loop's
        // wrap), which says nothing about speed.
        if !backwards && error < -Self.tolerance {
            let again = lastSlip.map { h - $0 <= Self.slipWindow } ?? false
            lastSlip = h
            steadySince = h
            if silent { return .none }
            if again {
                silent = true
                return .silence
            }
            return .play(at: m)
        }
        if silent {
            guard h - steadySince >= Self.resumeAfter else { return .none }
            silent = false
            lastSlip = nil
            anchor = (h, m)
            return .play(at: m)
        }
        return onLine ? .none : .play(at: m)
    }
}

/// Plays a video file's sound along with the picture NTSCRT shows.
///
/// An AVPlayer on the clip's first audio track alone (the track the
/// exporter writes), slaved to the host clock: each start pins a media time
/// to "now", so the sound holds the picture's schedule with nothing to
/// drift. No controls: it plays at the system volume whenever the video
/// plays. Driven from the main thread, like the rest of playback.
public final class VideoAudio {
    private let player: AVPlayer
    private var sync = AudioSync()
    /// CRT_AUDIO_MUTE=1: run everything at zero volume (checks and benches).
    static let muted = ProcessInfo.processInfo.environment["CRT_AUDIO_MUTE"] == "1"

    /// nil when the file has no sound (or it can't be played).
    ///
    /// Returns once the player is ready. Started before that,
    /// setRate(_:time:atHostTime:) raises an Objective-C exception, which
    /// AppKit swallows on the main thread along with the playback task
    /// that made the call — the picture stopped for good (a rotated clip
    /// played the moment it loaded stalled 5 runs in 8).
    @MainActor
    public static func make(for asset: AVAsset) async -> VideoAudio? {
        if ProcessInfo.processInfo.environment["CRT_AUDIO_OFF"] == "1" { return nil }
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange),
              range.duration > .zero else { return nil }
        // Only the audio: a player on the whole file would decode the
        // picture too. The track keeps its place in the file's time.
        let sound = AVMutableComposition()
        guard let copy = sound.addMutableTrack(withMediaType: .audio,
                                               preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? copy.insertTimeRange(range, of: track, at: range.start)) != nil else { return nil }
        let audio = VideoAudio(item: AVPlayerItem(asset: sound))
        let began = ContinuousClock.now
        while audio.player.currentItem?.status == .unknown {
            guard began.duration(to: .now) < .seconds(10) else { return nil }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if PlaybackPipeline.perfLog {
            fputs("[audio] ready after \(began.duration(to: .now))\n", stderr)
        }
        return audio.isReady ? audio : nil
    }

    private init(item: AVPlayerItem) {
        player = AVPlayer(playerItem: item)
        // Starting at a host time needs this off; a local file never stalls.
        player.automaticallyWaitsToMinimizeStalling = false
        // A clip whose sound ends before its picture just goes quiet until
        // the loop wraps.
        player.actionAtItemEnd = .none
        if Self.muted { player.volume = 0 }
    }

    private var isReady: Bool {
        !broken && player.status == .readyToPlay && player.currentItem?.status == .readyToPlay
    }
    /// The player raised an exception: leave it alone from here on.
    private var broken = false

    private static var now: CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// The picture just showed the frame at this media time.
    public func frameShown(mediaTime: Double) {
        guard isReady else { return }
        let now = Self.now
        switch sync.frameShown(mediaTime: mediaTime, clock: CMTimeGetSeconds(now)) {
        case .none: break
        case .play(let t):
            let player = self.player
            let failure = CrtCatchException {
                player.setRate(1, time: CMTime(seconds: max(0, t), preferredTimescale: 48_000),
                               atHostTime: now)
            }
            if let failure {
                broken = true
                fputs("[audio] stopped: \(failure)\n", stderr)
            }
        case .silence:
            player.rate = 0
        }
    }

    /// The picture is about to start somewhere else: quiet until its next
    /// frame.
    public func restart() {
        player.rate = 0
        sync.reset()
    }

    public func stop() { restart() }

    /// For the playback log: how far the sound is from where the picture
    /// puts it (seconds, + = sound ahead), or nil when it isn't playing.
    public func offset(fromMediaTime mediaTime: Double) -> Double? {
        guard player.rate != 0 else { return nil }
        return CMTimeGetSeconds(player.currentTime()) - mediaTime
    }
    public var isSilenced: Bool { sync.silent }
}
