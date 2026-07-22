import SwiftUI

/// Compact right-aligned numeric entry used as the value readout next to
/// sliders — type an exact value and press return (or click away) to commit.
/// Clamps to `range`.
///
/// String-backed on purpose: TextField(value:format:) re-parses and
/// re-formats on every keystroke and goes stale when the bound value changes
/// externally mid-edit, which mangled typed input (e.g. "120" → "1,620").
/// Here the text is only parsed on commit and only refreshed from the bound
/// value while the field is unfocused.
struct NumericField: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var width: CGFloat = 72

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: value.wrappedValue) { _, v in
                if !focused { text = Self.display(v) }
            }
            .onAppear { text = Self.display(value.wrappedValue) }
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let v = Double(cleaned) {
            value.wrappedValue = min(max(v, range.lowerBound), range.upperBound)
        }
        text = Self.display(value.wrappedValue)
    }

    static func display(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e9 { return String(Int(v)) }
        return String(format: "%.5g", v)
    }
}

/// Integer variant.
struct IntField: View {
    let value: Binding<Int>
    let range: ClosedRange<Int>
    var width: CGFloat = 56

    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.caption, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onChange(of: value.wrappedValue) { _, v in
                if !focused { text = String(v) }
            }
            .onAppear { text = String(value.wrappedValue) }
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let v = Int(cleaned) {
            value.wrappedValue = min(max(v, range.lowerBound), range.upperBound)
        }
        text = String(value.wrappedValue)
    }
}
