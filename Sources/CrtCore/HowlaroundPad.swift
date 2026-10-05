import CoreGraphics

/// The vanishing-point control drawn over the Screen Loop preview: a green
/// dot where the tunnel converges at the start of the render, a blue ring
/// where the drift takes it by the end, and an arrow between them. This is
/// its geometry and its editing rules, kept apart from the view so they can
/// be tested; the view draws it and hands it the mouse and the arrow keys.
///
/// Points are in the settings' units — from the middle of the frame, in
/// fractions of its width and height, y down — so the line drawn on the
/// picture is the line the tunnel follows, whatever the frame's shape.
public struct HowlaroundPad: Equatable, Sendable {
    public enum Handle: Equatable, Sendable {
        /// The green dot: the vanishing point.
        case start
        /// The blue ring: where it drifts to.
        case end
        /// The arrow: both together.
        case both
    }

    /// Where the picture is drawn, in points (y down).
    public var frame: CGRect
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>

    public init(frame: CGRect, start: SIMD2<Double>, end: SIMD2<Double>) {
        self.frame = frame
        self.start = start
        self.end = end
    }

    public init(frame: CGRect, settings: HowlaroundSettings) {
        self.init(frame: frame, start: settings.vanishingPoint, end: settings.driftTarget)
    }

    /// The settings that put the vanishing point and the drift where the pad has them.
    public var values: [String: Double] {
        HowlaroundSettings.values(vanishingPoint: start, driftTarget: end)
    }

    /// No drift: the ring sits on the dot.
    public var stacked: Bool { start == end }

    // MARK: sizes, in points

    /// The green dot's radius, and the blue ring's (to the middle of its line).
    public static let dotRadius: CGFloat = 6
    public static let ringRadius: CGFloat = 10
    /// How far from each part a click still takes hold of it. The middle of
    /// the dot is always the dot, even inside the ring sitting on it.
    public static let grabDot: CGFloat = 12
    public static let grabRing: CGFloat = 14
    public static let grabStackedRing: CGFloat = 16
    public static let grabArrow: CGFloat = 5
    static let grabDotCore: CGFloat = 7
    /// A dragged point lands on the other one this close (no drift), and on
    /// the middle of the frame this close.
    static let snapToOther: CGFloat = 10
    static let snapToMiddle: CGFloat = 6

    // MARK: geometry

    /// Where a point is drawn.
    public func point(_ p: SIMD2<Double>) -> CGPoint {
        CGPoint(x: frame.minX + (CGFloat(p.x) + 0.5) * frame.width,
                y: frame.minY + (CGFloat(p.y) + 0.5) * frame.height)
    }

    public var startPoint: CGPoint { point(start) }
    public var endPoint: CGPoint { point(end) }

    /// Points stay inside the frame.
    static func clamped(_ p: SIMD2<Double>) -> SIMD2<Double> {
        pointwiseMin(pointwiseMax(p, SIMD2(repeating: -0.5)), SIMD2(repeating: 0.5))
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// How far `p` is from the arrow, between its ends.
    private func distanceToArrow(_ p: CGPoint) -> CGFloat {
        let a = startPoint, b = endPoint
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        guard length2 > 0 else { return Self.distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2))
        return Self.distance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// What a click at `p` takes hold of, if anything. Inside the ring
    /// sitting on the dot, the dot's middle moves the vanishing point and
    /// the rest of the ring pulls a drift out of it.
    public func handle(at p: CGPoint) -> Handle? {
        let toDot = Self.distance(p, startPoint), toRing = Self.distance(p, endPoint)
        if toDot <= Self.grabDotCore { return .start }
        if stacked { return toRing <= Self.grabStackedRing ? .end : nil }
        if toRing <= Self.grabRing { return .end }
        if toDot <= Self.grabDot { return .start }
        return distanceToArrow(p) <= Self.grabArrow ? .both : nil
    }

    // MARK: editing

    /// The pad after dragging `handle` by `translation` points from where it
    /// was when the drag began (`self`). The dot moves the vanishing point
    /// and leaves the ring where it is — unless the ring sits on it, when
    /// there's no drift to keep and it comes along. The ring moves where the
    /// drift goes; the arrow moves both, as far as the frame lets them. A
    /// dragged point lands on the other when it comes close (no drift), and
    /// on the middle of the frame.
    public func dragged(_ handle: Handle, by translation: CGSize) -> HowlaroundPad {
        guard translation != .zero else { return self }       // a click: nothing moves, nothing snaps
        let d = SIMD2(Double(translation.width / max(1, frame.width)),
                      Double(translation.height / max(1, frame.height)))
        var p = self
        switch handle {
        case .start:
            p.start = snapped(Self.clamped(start + d), onto: stacked ? nil : end)
            if stacked { p.end = p.start }
        case .end:
            p.end = snapped(Self.clamped(end + d), onto: start)
        case .both:
            p.moveBoth(by: d)
        }
        return p
    }

    private func snapped(_ q: SIMD2<Double>, onto other: SIMD2<Double>?) -> SIMD2<Double> {
        if let other, Self.distance(point(q), point(other)) <= Self.snapToOther { return other }
        if Self.distance(point(q), point(.zero)) <= Self.snapToMiddle { return .zero }
        return q
    }

    private mutating func moveBoth(by d: SIMD2<Double>) {
        let lo = SIMD2(repeating: -0.5) - pointwiseMin(start, end)
        let hi = SIMD2(repeating: 0.5) - pointwiseMax(start, end)
        let step = pointwiseMin(pointwiseMax(d, lo), hi)
        start += step
        end += step
    }

    /// A double-click: on the dot, the vanishing point goes to the middle
    /// (with the ring, if it sits on it); on the ring, the drift goes.
    public func doubleClicked(_ handle: Handle) -> HowlaroundPad {
        var p = self
        switch handle {
        case .start:
            p.start = .zero
            if stacked { p.end = .zero }
        case .end:
            p.end = start
        case .both:
            break
        }
        return p
    }

    /// The arrow keys: `dx` steps right and `dy` steps down (negative for
    /// left and up), each `step` of the width or height. A drag without the
    /// snapping, except that a point nudged within half a step of the other
    /// lands on it, so no drift can be reached from the keyboard too.
    public func nudged(_ handle: Handle, dx: Int, dy: Int, step: Double) -> HowlaroundPad {
        let d = SIMD2(Double(dx), Double(dy)) * step
        func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
            abs(a.x - b.x) < step / 2 && abs(a.y - b.y) < step / 2
        }
        var p = self
        switch handle {
        case .start:
            p.start = Self.clamped(start + d)
            if stacked {
                p.end = p.start
            } else if close(p.start, end) {
                p.start = end
            }
        case .end:
            p.end = Self.clamped(end + d)
            if close(p.end, start) { p.end = start }
        case .both:
            p.moveBoth(by: d)
        }
        return p
    }
}
