//! The vanishing-point control over the Screen Loop preview (the Mac's
//! `HowlaroundPad`): a green dot where the tunnel converges at the start, a
//! blue ring where the drift takes it by the end, an arrow between them.
//! Geometry and editing rules only; the window draws it.
//!
//! Points are in the settings' units: from the middle of the frame, in
//! fractions of its width and height, y down. Screen positions are in points.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Handle {
    /// The green dot: the vanishing point.
    Start,
    /// The blue ring: where it drifts to.
    End,
    /// The arrow: both together.
    Both,
}

pub type P = (f64, f64);

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pad {
    /// Where the picture is drawn: (left, top, width, height).
    pub frame: (f64, f64, f64, f64),
    pub start: P,
    pub end: P,
}

pub const DOT_RADIUS: f64 = 6.0;
pub const RING_RADIUS: f64 = 10.0;
pub const GRAB_DOT: f64 = 12.0;
pub const GRAB_RING: f64 = 14.0;
pub const GRAB_STACKED_RING: f64 = 16.0;
pub const GRAB_ARROW: f64 = 5.0;
const GRAB_DOT_CORE: f64 = 7.0;
const SNAP_TO_OTHER: f64 = 10.0;
const SNAP_TO_MIDDLE: f64 = 6.0;

fn clamped(p: P) -> P {
    (p.0.clamp(-0.5, 0.5), p.1.clamp(-0.5, 0.5))
}

fn distance(a: P, b: P) -> f64 {
    (a.0 - b.0).hypot(a.1 - b.1)
}

impl Pad {
    pub fn new(frame: (f64, f64, f64, f64), settings: &super::HowlSettings) -> Self {
        Self { frame, start: settings.vanishing_point(), end: settings.drift_target() }
    }

    /// The settings that put the vanishing point and drift where the pad has them.
    pub fn values(&self) -> [(&'static str, f64); 4] {
        super::HowlSettings::point_values(self.start, self.end)
    }

    /// No drift: the ring sits on the dot.
    pub fn stacked(&self) -> bool {
        self.start == self.end
    }

    /// Where a point is drawn.
    pub fn point(&self, p: P) -> P {
        (self.frame.0 + (p.0 + 0.5) * self.frame.2, self.frame.1 + (p.1 + 0.5) * self.frame.3)
    }
    pub fn start_point(&self) -> P {
        self.point(self.start)
    }
    pub fn end_point(&self) -> P {
        self.point(self.end)
    }

    fn distance_to_arrow(&self, p: P) -> f64 {
        let (a, b) = (self.start_point(), self.end_point());
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        let l2 = dx * dx + dy * dy;
        if l2 <= 0.0 {
            return distance(p, a);
        }
        let t = (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / l2).clamp(0.0, 1.0);
        distance(p, (a.0 + t * dx, a.1 + t * dy))
    }

    /// What a click at `p` takes hold of, if anything.
    pub fn handle(&self, p: P) -> Option<Handle> {
        let to_dot = distance(p, self.start_point());
        let to_ring = distance(p, self.end_point());
        if to_dot <= GRAB_DOT_CORE {
            return Some(Handle::Start);
        }
        if self.stacked() {
            return (to_ring <= GRAB_STACKED_RING).then_some(Handle::End);
        }
        if to_ring <= GRAB_RING {
            return Some(Handle::End);
        }
        if to_dot <= GRAB_DOT {
            return Some(Handle::Start);
        }
        (self.distance_to_arrow(p) <= GRAB_ARROW).then_some(Handle::Both)
    }

    /// The pad after dragging `handle` by `translation` points from where it
    /// was when the drag began (`self`). A dragged point lands on the other
    /// when it comes close (no drift), and on the middle of the frame.
    pub fn dragged(&self, handle: Handle, translation: P) -> Pad {
        if translation == (0.0, 0.0) {
            return *self;
        }
        let d = (translation.0 / self.frame.2.max(1.0), translation.1 / self.frame.3.max(1.0));
        let mut p = *self;
        match handle {
            Handle::Start => {
                let other = (!self.stacked()).then_some(self.end);
                p.start = self.snapped(clamped((self.start.0 + d.0, self.start.1 + d.1)), other);
                if self.stacked() {
                    p.end = p.start;
                }
            }
            Handle::End => p.end = self.snapped(clamped((self.end.0 + d.0, self.end.1 + d.1)), Some(self.start)),
            Handle::Both => p.move_both(d),
        }
        p
    }

    fn snapped(&self, q: P, other: Option<P>) -> P {
        if let Some(o) = other {
            if distance(self.point(q), self.point(o)) <= SNAP_TO_OTHER {
                return o;
            }
        }
        if distance(self.point(q), self.point((0.0, 0.0))) <= SNAP_TO_MIDDLE {
            return (0.0, 0.0);
        }
        q
    }

    fn move_both(&mut self, d: P) {
        let lo = (-0.5 - self.start.0.min(self.end.0), -0.5 - self.start.1.min(self.end.1));
        let hi = (0.5 - self.start.0.max(self.end.0), 0.5 - self.start.1.max(self.end.1));
        let step = (d.0.max(lo.0).min(hi.0), d.1.max(lo.1).min(hi.1));
        self.start = (self.start.0 + step.0, self.start.1 + step.1);
        self.end = (self.end.0 + step.0, self.end.1 + step.1);
    }

    /// A double-click: on the dot, the vanishing point goes to the middle
    /// (with the ring, if it sits on it); on the ring, the drift goes.
    pub fn double_clicked(&self, handle: Handle) -> Pad {
        let mut p = *self;
        match handle {
            Handle::Start => {
                p.start = (0.0, 0.0);
                if self.stacked() {
                    p.end = (0.0, 0.0);
                }
            }
            Handle::End => p.end = self.start,
            Handle::Both => {}
        }
        p
    }

    /// The arrow keys: `dx` steps right and `dy` down, each `step` of the
    /// width or height; a point nudged within half a step of the other lands
    /// on it.
    pub fn nudged(&self, handle: Handle, dx: i32, dy: i32, step: f64) -> Pad {
        let d = (dx as f64 * step, dy as f64 * step);
        let close = |a: P, b: P| (a.0 - b.0).abs() < step / 2.0 && (a.1 - b.1).abs() < step / 2.0;
        let mut p = *self;
        match handle {
            Handle::Start => {
                p.start = clamped((self.start.0 + d.0, self.start.1 + d.1));
                if self.stacked() {
                    p.end = p.start;
                } else if close(p.start, self.end) {
                    p.start = self.end;
                }
            }
            Handle::End => {
                p.end = clamped((self.end.0 + d.0, self.end.1 + d.1));
                if close(p.end, self.start) {
                    p.end = self.start;
                }
            }
            Handle::Both => p.move_both(d),
        }
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pad(start: P, end: P) -> Pad {
        Pad { frame: (10.0, 10.0, 400.0, 300.0), start, end }
    }

    #[test]
    fn grabbing_follows_the_macs_rules() {
        let stacked = pad((0.1, 0.1), (0.1, 0.1));
        let s = stacked.start_point();
        assert_eq!(stacked.handle(s), Some(Handle::Start), "the dot's middle is the dot");
        assert_eq!(stacked.handle((s.0 + 12.0, s.1)), Some(Handle::End), "the ring round it pulls a drift");
        assert_eq!(stacked.handle((s.0 + 30.0, s.1)), None);
        let apart = pad((-0.2, 0.0), (0.2, 0.0));
        let mid = apart.point((0.0, 0.0));
        assert_eq!(apart.handle((mid.0, mid.1 + 3.0)), Some(Handle::Both), "the arrow moves both");
    }

    #[test]
    fn dragging_snaps_and_stays_in_the_frame() {
        let stacked = pad((0.1, 0.1), (0.1, 0.1));
        // Pulling the ring out makes a drift; the dot stays.
        let p = stacked.dragged(Handle::End, (100.0, 0.0));
        assert_eq!(p.start, (0.1, 0.1));
        assert!((p.end.0 - 0.35).abs() < 1e-9);
        // Back within 10 points of the dot: no drift again.
        let back = p.dragged(Handle::End, (-95.0, 0.0));
        assert!(back.stacked());
        // The dot near the middle lands on it; with the ring on it, both go.
        let mid = stacked.dragged(Handle::Start, (-40.0 + 2.0, -30.0 + 1.0));
        assert_eq!((mid.start, mid.end), ((0.0, 0.0), (0.0, 0.0)));
        // The arrow stops at the frame's edge.
        let both = pad((-0.2, 0.0), (0.3, 0.0)).dragged(Handle::Both, (400.0, 0.0));
        assert!((both.end.0 - 0.5).abs() < 1e-9 && (both.start.0 - 0.0).abs() < 1e-9);
        assert_eq!(pad((0.2, 0.2), (0.4, 0.2)).double_clicked(Handle::End).end, (0.2, 0.2));
        assert_eq!(pad((0.2, 0.2), (0.2, 0.2)).double_clicked(Handle::Start).end, (0.0, 0.0));
        let n = pad((0.0, 0.0), (0.015, 0.0)).nudged(Handle::Start, 1, 0, 0.01);
        assert_eq!(n.start, (0.015, 0.0), "nudged within half a step: onto the ring");
    }
}
