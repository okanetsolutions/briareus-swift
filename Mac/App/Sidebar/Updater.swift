// Keeps Briareus up to date from its GitHub releases (updater.c, Core/Update.swift): a check shortly after launch and every
// six hours, and, unless turned off, the new Briareus.app downloaded, unpacked and swapped in to run from the next start.
// The sidebar's version shows when one is waiting and opens the menu to check now, install, restart or turn the automatic
// updates off.
import AppKit
import Foundation

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private static let firstCheck: UInt64 = 15
    private static let checkEvery: UInt64 = 6 * 60 * 60
    private static let autoKey = "autoUpdate"

    /// This build's version, as the bundle says it.
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    /// The bundle as launched, which names the new build once an update moved the running one aside.
    private let app = Bundle.main.bundleURL
    @Published private(set) var busy = false
    private var installing = false
    @Published private(set) var latest: UpdateRelease?
    @Published private(set) var newer = false
    /// The latest release is in place and runs from the next start.
    @Published private(set) var ready = false
    /// What the last check or install ran into.
    @Published private(set) var error: String?
    /// A release that could not be installed is not downloaded again on its own.
    private var failedVersion: String?
    private var checked = false
    private var timer: Task<Void, Never>?
    private var restart = false
    private var started = false

    /// Whether new releases are downloaded and installed on their own: on until turned off, except in a debug build, which
    /// would otherwise be replaced by the published one.
    var automatic: Bool {
        get {
            if let on = UserDefaults.standard.object(forKey: Self.autoKey) as? Bool { return on }
            #if DEBUG
            return false
            #else
            return true
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoKey); objectWillChange.send() }
    }

    /// Called once the app has launched: removes what the last update left behind and schedules the first check.
    func start() {
        guard !started else { return }
        started = true
        let app = app
        // The process that ran from the backup may still be closing, so it is tried for a while.
        Task.detached(priority: .background) {
            for _ in 0..<20 where !updateCleanup(app: app) { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        schedule(Self.firstCheck)
    }

    private func schedule(_ seconds: UInt64) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.startJob(install: false, manual: false)
        }
    }

    // MARK: Restarting

    private func restartNow() {
        restart = true
        NSApp.terminate(nil)
    }
    /// The quit the restart asked for was turned down.
    func restartCancelled() { restart = false }

    /// As the app quits: starts the updated bundle once this process has gone, when a restart was asked for.
    func relaunchIfAsked() {
        guard restart else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$1\"",
                       String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
    }

    // MARK: Checking

    private struct Outcome: Sendable {
        var release: UpdateRelease?
        var newer = false
        var installed = false
        var error: String?
    }

    nonisolated private static func work(install: Bool, app: URL, current: String) async -> Outcome {
        var out = Outcome()
        let updates = Updates()
        switch await updates.check() {
        case .failure(let e): out.error = e.message; return out
        case .success(let r): out.release = r
        }
        guard let release = out.release else { return out }
        out.newer = updateNewer(release.version, current)
        guard out.newer, install else { return out }
        if let refusal = UpdateBundle.refusal(app) { out.error = refusal; return out }
        switch await updates.download(release) {
        case .failure(let e): out.error = e.message
        case .success(let zip):
            switch UpdateBundle.install(zip: zip, release: release, app: app) {
            case .failure(let e): out.error = e.message
            case .success: out.installed = true
            }
        }
        return out
    }

    /// Checks, and installs a newer release when asked to or when automatic updates are on.
    private func startJob(install: Bool, manual: Bool) {
        guard !busy, !ready else { return }
        // An automatic install that failed waits for the next release, or for Install in the menu.
        let auto = automatic && !(failedVersion != nil && failedVersion == latest?.version)
        let wantInstall = install || auto
        busy = true; installing = install
        let app = app, current = Self.current
        Task {
            let out = await Self.work(install: wantInstall, app: app, current: current)
            self.done(out, install: wantInstall, manual: manual)
        }
    }

    private func done(_ out: Outcome, install: Bool, manual: Bool) {
        busy = false; installing = false
        checked = true
        error = out.error
        if let r = out.release { latest = r; newer = out.newer }
        if out.installed { ready = true }
        else if install, out.newer, error != nil { failedVersion = latest?.version }
        // Once an update is in place the running bundle is the backup, which another one could not replace: no more checks.
        if !ready { schedule(Self.checkEvery) }
        if manual { report(out, install: install) }
    }

    /// What a check asked for from the menu ended in, said in a dialog.
    private func report(_ out: Outcome, install: Bool) {
        let version = latest?.version ?? ""
        if out.installed {
            if Dialogs.confirm("Briareus \(version) is installed", "Restart Briareus now to use it? Otherwise it starts the next time you open Briareus.",
                               continueLabel: "Restart now") { restartNow() }
        } else if let error {
            Dialogs.alert(install && out.newer ? "Briareus could not be updated" : "Could not check for updates", error)
        } else if !out.newer {
            Dialogs.alert("Briareus is up to date", "Version \(Self.current) is the latest release.")
        } else if Dialogs.confirm("Briareus \(version) is available", "Download and install it now? It runs once Briareus restarts.",
                                  continueLabel: "Install") {
            startJob(install: true, manual: true)
        }
    }

    // MARK: Sidebar

    /// Whether the sidebar's version shows a waiting release, in the accent.
    var highlight: Bool { latest != nil && (ready || newer) }
    /// The sidebar's version label: this build's, or the waiting release's.
    var label: String { highlight ? "↑ v\(latest?.version ?? "")" : "v\(Self.current)" }

    private var statusLine: String {
        if busy { return installing ? "Updating Briareus…" : "Checking for updates…" }
        if ready { return "Briareus \(latest?.version ?? "") is installed: restart to use it" }
        // A long reason is cut, the menu being one line.
        if let error { return error.count <= 90 ? error : String(error.prefix(87)) + "…" }
        if newer { return "Briareus \(latest?.version ?? "") is available" }
        if checked { return "Briareus \(Self.current) is up to date" }
        return "Briareus \(Self.current)"
    }

    /// The updates menu, under the pointer.
    func showMenu() {
        enum Item { case restart, install, check, auto, notes }
        var items: [PopupMenu.Item] = [PopupMenu.Item(title: statusLine, enabled: false), .separatorItem]
        var ids: [Item?] = [nil, nil]
        func add(_ item: PopupMenu.Item, _ id: Item) { items.append(item); ids.append(id) }
        if ready { add(PopupMenu.Item(title: "Restart to update"), .restart) }
        else if newer, let v = latest?.version { add(PopupMenu.Item(title: "Install \(v)", enabled: !busy), .install) }
        add(PopupMenu.Item(title: "Check for updates now", enabled: !busy && !ready), .check)
        let auto = automatic
        add(PopupMenu.Item(title: "Install updates automatically", checked: auto), .auto)
        if latest?.page != nil { add(PopupMenu.Item(title: "Release notes…"), .notes) }
        guard let i = PopupMenu.choose(items), let chosen = ids[i] else { return }
        switch chosen {
        case .restart: restartNow()
        case .install: startJob(install: true, manual: true)
        case .check: startJob(install: false, manual: true)
        case .auto:
            automatic = !auto
            // Turned on with a release already waiting: it is fetched now rather than at the next check.
            if !auto, newer { startJob(install: true, manual: false) }
        case .notes: openWebURL(latest?.page)
        }
    }
}

/// Unpacking a downloaded release and swapping its Briareus.app in for the running one.
enum UpdateBundle {
    /// Why the bundle at `app` cannot be replaced, or nil when it can.
    static func refusal(_ app: URL) -> String? {
        let name = app.lastPathComponent
        guard app.pathExtension == "app" else { return "Briareus is not running from an app bundle, so it was not replaced." }
        // Opened straight from the download, macOS runs a read-only copy of it.
        if app.path.contains("/AppTranslocation/") {
            return "Briareus is running from a temporary copy macOS made. Move \(name) to Applications and open it from there."
        }
        let folder = app.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: folder) || !FileManager.default.isWritableFile(atPath: app.path) {
            return "\(name) is in a folder this user may not write to, so it was not replaced. Download it from the release page instead."
        }
        return nil
    }

    /// Unpacks `zip` beside `app` (on its volume, so the swap is a rename), checks it is this app at the release's version
    /// with its signature intact, takes away any quarantine, and moves it in place of `app`.
    static func install(zip: Data, release: UpdateRelease, app: URL) -> Result<Void, UpdateError> {
        let fm = FileManager.default
        let work: URL
        do { work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true) } catch {
            return .failure(UpdateError("The update could not be saved beside \(app.lastPathComponent). (\(error.localizedDescription))"))
        }
        defer { try? fm.removeItem(at: work) }
        let archive = work.appendingPathComponent(Update.asset), unpacked = work.appendingPathComponent("unpacked")
        do { try zip.write(to: archive) } catch {
            return .failure(UpdateError("The update could not be saved. (\(error.localizedDescription))"))
        }
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) else {
            return .failure(UpdateError("The update could not be unpacked. Download it from the release page instead."))
        }
        let fresh = unpacked.appendingPathComponent("Briareus.app")
        let info = NSDictionary(contentsOf: fresh.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            return .failure(UpdateError("The downloaded update is not Briareus \(release.version), so it was not installed."))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", fresh.path]) else {
            return .failure(UpdateError("The downloaded update's signature does not hold, so it was not installed."))
        }
        // URLSession's download carries none, but a copy unpacked from a quarantined archive would.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", fresh.path])
        return updateInstall(app: app, fresh: fresh)
    }

    /// Runs a tool to its end; true when it succeeded.
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
