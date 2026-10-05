import SwiftUI

/// Disclosure chevron for collapsible sidebar sections.
///
/// Deliberately NOT animated: animating the expand would relayout the whole
/// (large) sidebar subtree over multiple frames on the main thread, which
/// competes with the 60fps preview and feels laggy. Instant is snappy.
struct Twirl: View {
    @Binding var expanded: Bool

    var body: some View {
        Button {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                // The glyph itself is ~8pt across. Without an explicit hit
                // area a click landing a few points off hits nothing, which
                // reads as "the twirl needs two or three clicks" rather than
                // as a miss. contentShape makes the whole square clickable,
                // not just the drawn chevron.
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Compact right-aligned numeric entry used as the value readout next to
/// sliders — type an exact value and press return (or click away) to commit.
/// Clamps to `range`.
///
/// String-backed on purpose: TextField(value:format:) re-parses and
/// re-formats on every keystroke and goes stale when the bound value changes
/// externally mid-edit, which mangled typed input (e.g. "120" → "1,620").
/// Here the text is only parsed on commit, and only text you've typed is
/// committed: until you type, the field follows the bound value even while
/// it has focus. (It used to commit whatever it showed on losing focus — so
/// a field focused while its slider moved put the old value back. The
/// Screen Loop panel focuses its first field on opening, so opening the
/// export settings reset Zoom.)
struct NumericField: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var width: CGFloat = 72

    @State private var text: String
    /// Typed into since the field last showed the bound value.
    @State private var edited = false
    @FocusState private var focused: Bool

    init(value: Binding<Double>, range: ClosedRange<Double>, width: CGFloat = 72) {
        self.value = value
        self.range = range
        self.width = width
        _text = State(initialValue: Self.display(value.wrappedValue))
    }

    var body: some View {
        // Typing goes through this binding; the field's own refreshes don't.
        // AppKit also writes the unchanged text back when the field gains
        // focus, so only a real change counts as an edit.
        TextField("", text: Binding(get: { text }, set: { if $0 != text { text = $0; edited = true } }))
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
                if !focused || !edited { text = Self.display(v) }
            }
    }

    private func commit() {
        if edited {
            let cleaned = text.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let v = Double(cleaned) {
                value.wrappedValue = min(max(v, range.lowerBound), range.upperBound)
            }
        }
        edited = false
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

    @State private var text: String
    /// Typed into since the field last showed the bound value (see NumericField).
    @State private var edited = false
    @FocusState private var focused: Bool

    init(value: Binding<Int>, range: ClosedRange<Int>, width: CGFloat = 56) {
        self.value = value
        self.range = range
        self.width = width
        _text = State(initialValue: String(value.wrappedValue))
    }

    var body: some View {
        TextField("", text: Binding(get: { text }, set: { if $0 != text { text = $0; edited = true } }))
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
                if !focused || !edited { text = String(v) }
            }
    }

    private func commit() {
        if edited {
            let cleaned = text.replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let v = Int(cleaned) {
                value.wrappedValue = min(max(v, range.lowerBound), range.upperBound)
            }
        }
        edited = false
        text = String(value.wrappedValue)
    }
}
