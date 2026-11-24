import AppKit
import CrtCore

/// Who made NTSCRT, with the site and X profile as links: under the name
/// and version in NTSCRT › About NTSCRT (the standard panel), and as one
/// line at the bottom of the update prompt (UpdateChecker).
enum AboutPanel {

    static let author = "Finn Mckenty"
    static let site = (label: "finnmckenty.com", url: URL(string: "https://finnmckenty.com")!)
    static let x = (label: "Finn Mckenty on X", url: URL(string: "https://x.com/thefinnmckenty")!)

    /// Three centered lines: "by Finn Mckenty", the site, the X profile.
    static var credits: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 3
        let name: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        func link(_ item: (label: String, url: URL)) -> NSAttributedString {
            NSAttributedString(string: item.label, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .link: item.url,
                .paragraphStyle: centered,
            ])
        }
        let text = NSMutableAttributedString(string: "by \(author)\n", attributes: name)
        text.append(link(site))
        text.append(NSAttributedString(string: "\n", attributes: name))
        text.append(link(x))
        return text
    }

    /// The same on one line, for the update prompt: "NTSCRT by Finn Mckenty
    /// · finnmckenty.com · Finn Mckenty on X".
    static var creditLine: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered,
        ]
        let text = NSMutableAttributedString(string: "NTSCRT by \(author)", attributes: plain)
        for item in [site, x] {
            text.append(NSAttributedString(string: "  ·  ", attributes: plain))
            text.append(NSAttributedString(string: item.label, attributes: [
                .font: font, .link: item.url, .paragraphStyle: centered,
            ]))
        }
        return text
    }

    /// `creditLine` as a view `width` wide, its links clickable.
    @MainActor
    static func creditLineView(width: CGFloat) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 16))
        view.isEditable = false
        view.isSelectable = true        // links only open in selectable text
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textStorage?.setAttributedString(creditLine)
        return view
    }

    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// CRT_ABOUT_SNAPSHOT=<out.png>: open the panel, capture its window to
    /// a PNG (needs Screen Recording permission), print its text and where
    /// each link goes, exit.
    @MainActor
    static func snapshotAndExit(to path: String) async {
        show()
        await snapshotCreditAndExit("ABOUT", to: path)
    }

    /// Capture the window that shows the credit (the About panel, or the
    /// update prompt's sheet: CRT_UPDATE_SNAPSHOT) to a PNG, print the
    /// credit's text and where each link goes, exit.
    @MainActor
    static func snapshotCreditAndExit(_ label: String, to path: String) async {
        try? await Task.sleep(for: .milliseconds(900))
        func textView(in view: NSView) -> NSTextView? {
            if let t = view as? NSTextView, t.string.contains(author) { return t }
            for sub in view.subviews { if let t = textView(in: sub) { return t } }
            return nil
        }
        guard let (window, text) = NSApp.windows.lazy.compactMap({ w in
            w.contentView.flatMap(textView(in:)).map { (w, $0) }
        }).first else {
            print("\(label) FAIL: no window showing the credit"); exit(1)
        }
        // The window as the window server shows it: drawn off screen, the
        // panel's material is missing and its label-colored text with it.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? capture.run()
        capture.waitUntilExit()
        print("\(label) text: \(text.string.replacingOccurrences(of: "\n", with: " | "))")
        let storage = text.textStorage ?? NSTextStorage()
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let value else { return }
            print("\(label) link: \"\(storage.attributedSubstring(from: range).string)\" -> \(value)")
        }
        exit(0)
    }
}
