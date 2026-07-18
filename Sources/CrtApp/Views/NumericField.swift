import SwiftUI

/// Compact right-aligned numeric entry used as the value readout next to
/// sliders — type an exact value and press return. Clamps to `range`.
struct NumericField: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var width: CGFloat = 64

    var body: some View {
        TextField(
            "",
            value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
            ),
            format: .number.precision(.significantDigits(1...5))
        )
        .textFieldStyle(.plain)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .frame(width: width)
    }
}

/// Integer variant.
struct IntField: View {
    let value: Binding<Int>
    let range: ClosedRange<Int>
    var width: CGFloat = 56

    var body: some View {
        TextField(
            "",
            value: Binding(
                get: { value.wrappedValue },
                set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
            ),
            format: .number
        )
        .textFieldStyle(.plain)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .frame(width: width)
    }
}
