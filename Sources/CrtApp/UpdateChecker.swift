import AppKit
import CrtCore

/// Checking GitHub for a newer release: at most once a day at launch
/// (unless turned off in the NTSCRT menu) and from "Check for Updates…".
/// A newer release is offered with its notes and a link to its page;
/// nothing is downloaded or installed here. The rules live in CrtCore's
/// UpdateCheck; the Windows version is port/app/src/update.rs.
///
/// Test hooks: `CRT_UPDATE_URL` (another feed: a URL or a JSON file in
/// GitHub's release format), `CRT_UPDATE_VERSION` (pretend to be this
/// version), `CRT_UPDATE_CHECK=0` (never check at launch). Other `CRT_*`
/// hooks (scripted runs) skip the launch check unless `CRT_UPDATE_URL` is set.
@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    /// UserDefaults keys (the menu's toggle binds to `automaticKey`).
    static let automaticKey = "UpdateCheckAutomatic"
    private static let lastCheckKey = "UpdateLastCheck"
    private static let skippedKey = "UpdateSkippedVersion"
    private static let checkEvery: TimeInterval = 24 * 60 * 60

    /// This build's version: the release's ("0.23.0"), a git describe string
    /// for dev bundles, or "dev" for the bare executable.
    let current: String
    private var checking = false
    private let env = ProcessInfo.processInfo.environment

    private init() {
        current = env["CRT_UPDATE_VERSION"]
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
        UserDefaults.standard.register(defaults: [Self.automaticKey: true])
    }

    private var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: Self.automaticKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.automaticKey) }
    }

    func checkAtLaunch() {
        let testing = env["CRT_UPDATE_URL"] != nil
        guard env["CRT_UPDATE_CHECK"] != "0" else { return }
        // Runs driven by test hooks mustn't reach out or put up an alert on
        // their own. (CRT_PRESETS comes from the dev bundle's Info.plist.)
        let scripted = env.keys.contains { $0.hasPrefix("CRT_") && !$0.hasPrefix("CRT_UPDATE_") && $0 != "CRT_PRESETS" }
        if testing {
            Task { await check(manual: false) }
            return
        }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard !scripted, automatic, UpdateCheck.parseVersion(current) != nil,
              Date().timeIntervalSince1970 - last >= Self.checkEvery else { return }
        Task { await check(manual: false) }
    }

    func checkNow() {
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        let outcome: UpdateCheck.Outcome
        do {
            outcome = UpdateCheck.compare(current: current, latest: try await fetch())
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        if case .failed = outcome {} else {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        }
        switch outcome {
        case .newer(let release):
            // At launch, a version the user skipped isn't offered again.
            if !manual && UserDefaults.standard.string(forKey: Self.skippedKey) == release.version { return }
            offer(release)
        case .upToDate(let latest):
            guard manual else { return }
            let exact = UpdateCheck.parseVersion(current) == UpdateCheck.parseVersion(latest) && !current.contains("-")
            tell("You're up to date",
                 exact ? "NTSCRT \(current) is the latest version."
                       : "This build is \(current); the latest release is \(latest).")
        case .failed(let message):
            guard manual else { return }
            tell("Couldn't check for updates",
                 "\(message). Check your internet connection, or see the releases on GitHub.",
                 extra: ("Open GitHub", UpdateCheck.releasesPage))
        }
    }

    private func fetch() async throws -> UpdateCheck.Release {
        let override = env["CRT_UPDATE_URL"]
        if let override, !override.hasPrefix("http") {
            return try UpdateCheck.release(from: Data(contentsOf: URL(fileURLWithPath: override)))
        }
        var request = URLRequest(url: override.flatMap(URL.init(string:)) ?? UpdateCheck.feed, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NTSCRT/\(current) (Mac)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateCheckError("GitHub answered \(http.statusCode)")
        }
        return try UpdateCheck.release(from: data)
    }

    // MARK: - alerts

    private func offer(_ release: UpdateCheck.Release) {
        let alert = NSAlert()
        alert.messageText = "NTSCRT \(release.version) is available"
        alert.informativeText = "You have \(current). Download it from the release page, then replace NTSCRT in Applications."
        if !release.notes.isEmpty { alert.accessoryView = notesView(release.notes) }
        alert.addButton(withTitle: "Download…")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Check for updates automatically"
        alert.suppressionButton?.state = automatic ? .on : .off
        present(alert) { [weak self] response in
            guard let self else { return }
            self.automatic = alert.suppressionButton?.state == .on
            switch response {
            case .alertFirstButtonReturn: NSWorkspace.shared.open(release.page)
            case .alertSecondButtonReturn: UserDefaults.standard.set(release.version, forKey: Self.skippedKey)
            default: break
            }
        }
    }

    private func tell(_ title: String, _ text: String, extra: (String, URL)? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        if let extra { alert.addButton(withTitle: extra.0) }
        present(alert) { response in
            if let extra, response == .alertSecondButtonReturn { NSWorkspace.shared.open(extra.1) }
        }
    }

    /// As a sheet on the window when there is one (the app keeps running
    /// behind it), else on its own.
    private func present(_ alert: NSAlert, then: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { then(response) }
            }
        } else {
            then(alert.runModal())
        }
    }

    /// The release notes, scrollable.
    private func notesView(_ notes: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.string = notes
        scroll.documentView = text
        return scroll
    }
}
