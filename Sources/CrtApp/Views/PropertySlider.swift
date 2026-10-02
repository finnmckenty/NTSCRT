import SwiftUI
import AppKit

/// The sliders in the sidebar: AppKit's own NSSlider — so it looks and
/// drags exactly as SwiftUI's Slider does on macOS — plus double-click on
/// the knob to send the property to `neutral`, where its effect is weakest.
///
/// SwiftUI's Slider can't do the double-click reliably: NSSlider runs its own
/// tracking loop on mouse-down, so a SwiftUI tap gesture can't tell a
/// double-click on the knob from clicks on the track.
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
        slider.onKnobDoubleClick = { [weak coordinator] in coordinator?.resetToNeutral() }
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

        func resetToNeutral() {
            parent.value = min(parent.range.upperBound, max(parent.range.lowerBound, parent.neutral))
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
