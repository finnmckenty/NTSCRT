import SwiftUI
import CrtCore

/// The Screen Loop's vanishing point and drift, set on the preview itself:
/// drag the green dot to where the copies should converge, and pull the blue
/// ring out of it to where the vanishing point drifts over the render. The
/// arrow between them moves both, and has a head at each end when the move
/// loops (out and back). The faint dashed ring around the green dot is the
/// area it would cover as Handheld wanders it. Double-click the dot for the middle, the ring for no
/// drift; arrow keys nudge whichever was clicked last (Shift: 10%). The
/// rules and the geometry are HowlaroundPad's.
struct VanishingPointPad: View {
    @Environment(AppState.self) private var state
    /// The draft's size in pixels: where the picture sits in the view.
    let pictureSize: CGSize
    /// Room around the picture for dots at its edges, in points.
    let margin: CGFloat

    /// The drag in progress: what it holds, the pad when it began, and
    /// where it began (a new start location is a new drag, should an end
    /// ever go missing).
    @State private var drag: (handle: HowlaroundPad.Handle, from: HowlaroundPad, at: CGPoint)?
    @State private var selected: HowlaroundPad.Handle = .start
    @FocusState private var focused: Bool
    /// The pad takes the arrow keys only once a dot has been clicked: if it
    /// could be focused from the start, the panel would open with it focused
    /// and a stray arrow key would move the vanishing point.
    @State private var takesKeys = false

    static let green = Color(red: 0.25, green: 0.86, blue: 0.42)
    static let blue = Color(red: 0.27, green: 0.56, blue: 1.0)

    var body: some View {
        GeometryReader { geo in
            let settings = state.howlaroundSettings
            let pad = HowlaroundPad(frame: Self.fitted(pictureSize, in: geo.size, margin: margin),
                                    settings: settings)
            ZStack {
                drawing(pad, settings).allowsHitTesting(false)
                grabAreas(pad)
            }
            .opacity(settings.tvInView ? 1 : 0.35)
            .allowsHitTesting(settings.tvInView)
            .onAppear { Self.lastFrame = geo.frame(in: .global); Self.lastPad = pad }
            .onChange(of: pad) { _, new in Self.lastFrame = geo.frame(in: .global); Self.lastPad = new }
        }
    }

    /// Where the picture sits: the draft, fitted and centered in the view
    /// less its margin — as the player fits it.
    static func fitted(_ picture: CGSize, in area: CGSize, margin: CGFloat) -> CGRect {
        let room = CGSize(width: max(1, area.width - 2 * margin), height: max(1, area.height - 2 * margin))
        guard picture.width > 0, picture.height > 0 else {
            return CGRect(origin: CGPoint(x: margin, y: margin), size: room)
        }
        let scale = min(room.width / picture.width, room.height / picture.height)
        let size = CGSize(width: picture.width * scale, height: picture.height * scale)
        return CGRect(x: margin + (room.width - size.width) / 2, y: margin + (room.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// For the in-app check (CRT_PAD_E2E): where the pad was last drawn, in
    /// window coordinates (top left, y down), and its geometry.
    @MainActor static var lastFrame: CGRect = .zero
    @MainActor static var lastPad: HowlaroundPad?

    // MARK: drawing

    private func drawing(_ pad: HowlaroundPad, _ settings: HowlaroundSettings) -> some View {
        let reach = settings.handheldReach(length: state.howlRenderLength)
        let loop = settings.loop
        let showSelection = focused
        let dragging = drag != nil
        return Canvas { ctx, _ in
            let s = pad.startPoint, e = pad.endPoint, frame = pad.frame
            let shadow = Color.black.opacity(0.5)

            // How far the hands take the vanishing point: the area the green
            // dot would cover if it followed it (the wander, plus the dot's
            // own size — at the default Handheld the wander alone is smaller
            // than the dot).
            if reach.x > 0 || reach.y > 0 {
                let grow = HowlaroundPad.dotRadius + 2
                let rx = CGFloat(reach.x) * frame.width + grow, ry = CGFloat(reach.y) * frame.height + grow
                let ellipse = Path(ellipseIn: CGRect(x: s.x - rx, y: s.y - ry, width: 2 * rx, height: 2 * ry))
                ctx.fill(ellipse, with: .color(.white.opacity(0.07)))
                ctx.stroke(ellipse, with: .color(.black.opacity(0.3)), lineWidth: 2.5)
                ctx.stroke(ellipse, with: .color(.white.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            // While dragging, the frame's middle, which points snap to.
            if dragging {
                var guides = Path()
                guides.move(to: CGPoint(x: frame.midX, y: frame.minY))
                guides.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
                guides.move(to: CGPoint(x: frame.minX, y: frame.midY))
                guides.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                ctx.stroke(guides, with: .color(.white.opacity(0.22)), lineWidth: 1)
            }

            // The arrow, from the dot's edge to the ring's (a head at each
            // end when the move goes out and back).
            if !pad.stacked {
                let dx = e.x - s.x, dy = e.y - s.y
                let length = max(0.001, hypot(dx, dy))
                let u = CGPoint(x: dx / length, y: dy / length)
                let from = HowlaroundPad.dotRadius + 3, to = length - HowlaroundPad.ringRadius - 3
                if to - from > 4 {
                    let a = CGPoint(x: s.x + u.x * from, y: s.y + u.y * from)
                    let b = CGPoint(x: s.x + u.x * to, y: s.y + u.y * to)
                    var arrow = Path()
                    arrow.move(to: a)
                    arrow.addLine(to: b)
                    func head(at tip: CGPoint, pointing d: CGPoint) {
                        let size: CGFloat = min(9, (to - from) / 2), half: CGFloat = size * 0.55
                        arrow.move(to: CGPoint(x: tip.x - d.x * size - d.y * half, y: tip.y - d.y * size + d.x * half))
                        arrow.addLine(to: tip)
                        arrow.addLine(to: CGPoint(x: tip.x - d.x * size + d.y * half, y: tip.y - d.y * size - d.x * half))
                    }
                    head(at: b, pointing: u)
                    if loop { head(at: a, pointing: CGPoint(x: -u.x, y: -u.y)) }
                    let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                    ctx.stroke(arrow, with: .color(shadow), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
                    ctx.stroke(arrow, with: .color(.white), style: style)
                }
            }

            // The blue ring: where the drift goes.
            let r = HowlaroundPad.ringRadius
            let ring = Path(ellipseIn: CGRect(x: e.x - r, y: e.y - r, width: 2 * r, height: 2 * r))
            ctx.stroke(ring, with: .color(shadow), lineWidth: 5.5)
            ctx.stroke(ring, with: .color(Self.blue), lineWidth: 3)
            if showSelection && selected != .start {
                let h = r + 4.5
                ctx.stroke(Path(ellipseIn: CGRect(x: e.x - h, y: e.y - h, width: 2 * h, height: 2 * h)),
                           with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }

            // The green dot: the vanishing point.
            let d = HowlaroundPad.dotRadius
            let dot = Path(ellipseIn: CGRect(x: s.x - d, y: s.y - d, width: 2 * d, height: 2 * d))
            ctx.stroke(dot, with: .color(shadow), lineWidth: 3.5)
            ctx.fill(dot, with: .color(Self.green))
            ctx.stroke(dot, with: .color(.white), lineWidth: 1.5)
            if showSelection && selected != .end && !(pad.stacked && selected == .both) {
                let h = pad.stacked ? d + 2 : d + 4
                ctx.stroke(Path(ellipseIn: CGRect(x: s.x - h, y: s.y - h, width: 2 * h, height: 2 * h)),
                           with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            }
        }
    }

    // MARK: interaction

    /// Where clicks are taken: round the dot, round the ring, along the
    /// arrow (HowlaroundPad.handle decides which). Everywhere else they go
    /// through to the player underneath.
    private func grabAreas(_ pad: HowlaroundPad) -> some View {
        let ring = pad.stacked ? HowlaroundPad.grabStackedRing : HowlaroundPad.grabRing
        return ZStack {
            if !pad.stacked {
                Color.clear.contentShape(Segment(from: pad.startPoint, to: pad.endPoint,
                                                 width: 2 * HowlaroundPad.grabArrow))
            }
            Color.clear
                .frame(width: 2 * ring, height: 2 * ring)
                .contentShape(Circle())
                .tooltip(pad.stacked
                      ? "Pull this blue ring out of the green dot to make the vanishing point drift over the render. Drag the green dot itself to move the vanishing point."
                      : "Drift to: where the vanishing point moves over the render. Drag it back onto the green dot, or double-click it, for no drift.")
                .position(pad.endPoint)
            // Sitting inside the ring, the dot needs no area of its own:
            // the ring's covers it, and its tooltip explains both.
            if !pad.stacked {
                Color.clear
                    .frame(width: 2 * HowlaroundPad.grabDot, height: 2 * HowlaroundPad.grabDot)
                    .contentShape(Circle())
                    .tooltip("Vanishing point: where the copies converge at the start. Drag to move it; double-click for the middle. Arrow keys nudge the dot you clicked last.")
                    .position(pad.startPoint)
            }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil || drag?.at != value.startLocation {
                    guard let handle = pad.handle(at: value.startLocation) else { drag = nil; return }
                    drag = (handle, pad, value.startLocation)
                    selected = handle
                    if takesKeys {
                        focused = true
                    } else {
                        takesKeys = true            // focusable from the next update
                        DispatchQueue.main.async { focused = true }
                    }
                }
                guard let drag, value.translation != .zero else { return }
                state.setHowlaroundValues(drag.from.dragged(drag.handle, by: value.translation).values)
            }
            .onEnded { _ in drag = nil })
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
            guard let handle = pad.handle(at: value.location) else { return }
            selected = handle
            state.setHowlaroundValues(pad.doubleClicked(handle).values)
        })
        .focusable(takesKeys, interactions: .edit)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let step = press.modifiers.contains(.shift) ? 0.1 : 0.01
            let (dx, dy): (Int, Int) = switch press.key {
            case .leftArrow: (-1, 0)
            case .rightArrow: (1, 0)
            case .upArrow: (0, -1)
            default: (0, 1)
            }
            state.setHowlaroundValues(pad.nudged(selected, dx: dx, dy: dy, step: step).values)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Vanishing point and drift")
        .accessibilityValue(state.howlaroundReadout)
    }
}

/// A thick line: the arrow's grab area.
private struct Segment: Shape {
    let from: CGPoint
    let to: CGPoint
    let width: CGFloat

    func path(in rect: CGRect) -> Path {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(0.001, hypot(dx, dy))
        let n = CGPoint(x: -dy / length * width / 2, y: dx / length * width / 2)
        var p = Path()
        p.move(to: CGPoint(x: from.x + n.x, y: from.y + n.y))
        p.addLine(to: CGPoint(x: to.x + n.x, y: to.y + n.y))
        p.addLine(to: CGPoint(x: to.x - n.x, y: to.y - n.y))
        p.addLine(to: CGPoint(x: from.x - n.x, y: from.y - n.y))
        p.closeSubpath()
        return p
    }
}
