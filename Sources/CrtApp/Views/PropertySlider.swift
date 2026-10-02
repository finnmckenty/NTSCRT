import SwiftUI
import AppKit

/// The sliders in the sidebar: AppKit's own NSSlider — so it looks and
/// drags exactly as SwiftUI's Slider does on macOS — plus double-click on
/// the knob to send the property to `neutral`, where its effect is weakest.
///
/// SwiftUI's Slider can't do the double-click reliably: NSSlider runs its own
/// tracking loop on mouse-down, so a SwiftUI tap gesture can't tell a
/// double-click on the knob from clicks on the track.
///
/// After a double-click the knob is held on the reset value for a moment: on
/// macOS 26 NSSlider is drawn by an internal SwiftUI view that keeps its own
/// copy of the knob position, and when the first click's press ends (~0.3 s
/// later) it silently writes that copy back if the click moved the value at
/// all — the value stays reset but the knob jumps back to where it was.
/// Measured with `CRT_SLIDER_E2E`.
struct PropertySlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Snap to this grid when dragging (nil = continuous).
    var step: Double? = nil
    let neutral: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NeutralSlider {
        let slider = NeutralSlider()
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        let coordinator = context.coordinator
        slider.onKnobDoubleClick = { [weak coordinator, weak slider] in
            if let slider { coordinator?.resetToNeutral(holding: slider) }
        }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return slider
    }

    func updateNSView(_ slider: NeutralSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = context.environment.isEnabled
        if slider.minValue != range.lowerBound { slider.minValue = range.lowerBound }
        if slider.maxValue != range.upperBound { slider.maxValue = range.upperBound }
        if abs(slider.doubleValue - value) > 1e-12 { slider.doubleValue = value }
    }

    final class Coordinator: NSObject {
        var parent: PropertySlider
        init(_ parent: PropertySlider) { self.parent = parent }

        @objc func changed(_ sender: NSSlider) {
            var v = sender.doubleValue
            if let step = parent.step, step > 0 {
                let lo = parent.range.lowerBound
                v = lo + ((v - lo) / step).rounded() * step
                v = min(parent.range.upperBound, max(lo, v))
            }
            if v != parent.value { parent.value = v }
        }

        func resetToNeutral(holding slider: NSSlider) {
            parent.value = min(parent.range.upperBound, max(parent.range.lowerBound, parent.neutral))
            heldSlider = slider
            holdUntil = ProcessInfo.processInfo.systemUptime + 1
            if holdTimer == nil {
                let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(holdKnob(_:)),
                                  userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .common)
                holdTimer = timer
            }
        }

        private var holdTimer: Timer?
        private weak var heldSlider: NSSlider?
        private var holdUntil: TimeInterval = 0

        /// Keep the knob on the bound value until NSSlider's press has ended.
        @objc private func holdKnob(_ timer: Timer) {
            guard let slider = heldSlider, ProcessInfo.processInfo.systemUptime < holdUntil else {
                timer.invalidate()
                holdTimer = nil
                return
            }
            if abs(slider.doubleValue - parent.value) > 1e-12 { slider.doubleValue = parent.value }
        }
    }
}

/// NSSlider that reports a double-click on its knob instead of tracking it.
final class NeutralSlider: NSSlider {
    var onKnobDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, knobContains(event.locationInWindow) {
            onKnobDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    /// The knob's rect, with a few points of slack — it's a small target.
    func knobContains(_ windowPoint: NSPoint) -> Bool {
        guard let cell = cell as? NSSliderCell else { return false }
        let p = convert(windowPoint, from: nil)
        return cell.knobRect(flipped: isFlipped).insetBy(dx: -3, dy: -3).contains(p)
    }
}
