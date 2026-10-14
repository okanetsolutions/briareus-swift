// A pull request's ▶ Run tab, the same on the iPhone and the Mac: which session serves it at what address and with which
// run profile, the profile picked in the tab and the one the request in flight asked for, and what each answer of
// `serve_pull` or `serve` changes. The models make the calls and run the embedded browser; this decides.
import Foundation

/// The request the Run tab sends: `serve_pull` prepares a new session (served with the project's default profile), `serve`
/// serves the tab's session again with the picked profile.
struct RunRequest: Equatable {
    let operation: String
    let arguments: JSON
    /// It serves the tab's session again rather than preparing a new one.
    let switched: Bool
    /// The profile it switches to, for the log's "▶ Switching to profile" line.
    let switchingTo: String?
    /// Serving waits on a workspace that may have to start, so it is given longer than a read.
    static let timeout: TimeInterval = 170
}

/// What a `serve_pull` or `serve` answer asks of the model.
struct RunServed: Equatable {
    /// The address to show, when it is one the browser may open.
    var show: String?
    /// The same address after a restart: a new app is behind it, so the page is loaded again.
    var reload = false
    /// A profile was picked while the request was out (or a new session was served with the default): serve again.
    var startAgain = false
}

struct RunServe: Equatable {
    var url: String?
    /// The session serving the pull request.
    var session: String?
    /// The profile it serves.
    var profile: String?
    /// The profile picked in the tab.
    var want: String?
    /// The profile the request in flight asked for.
    var asked: String?
    var error: String?
    var busy = false

    /// The profile the tab shows as chosen: the one picked, else the one served, else the project's default (`profiles`
    /// lists it first).
    func shownProfile(_ profiles: [String]) -> String? { want ?? profile ?? profiles.first }
    /// Opening the tab serves the pull request unless something already serves it, is being served or failed to.
    var needsServing: Bool { url == nil && !busy && error == nil }

    /// A Run already serving the pull request (one of its sessions with serve links) is adopted as it is.
    mutating func adopt(session: String, url: String) { self.session = session; self.url = url }

    /// Starts serving: the tab's session again with the picked profile when there is one and the server takes `serve`;
    /// else a new session. Nil while a request is out.
    mutating func start(repo: String, number: Int, canSwitch: Bool) -> RunRequest? {
        guard !busy else { return nil }
        busy = true; error = nil
        if let session, canSwitch {
            var arguments: JSON = ["sessionId": .string(session)]
            if let want { arguments["profile"] = .string(want) }
            asked = want
            return RunRequest(operation: "serve", arguments: arguments, switched: true, switchingTo: want)
        }
        return RunRequest(operation: "serve_pull", arguments: ["repo": .string(repo), "prNumber": JSON(number)], switched: false,
                          switchingTo: asked)
    }

    /// The request failed with `said`. A switch to a session that has gone (404, or no live workspace) forgets it and its
    /// page, so the next try prepares a new one; any other refused switch goes back to the profile served. True when the
    /// page was dropped.
    @discardableResult
    mutating func failed(_ said: String, status: Int?, message: String?, switched: Bool) -> Bool {
        busy = false; asked = nil
        error = said
        guard switched else { return false }
        if status == 404 || (message ?? "").contains("no live workspace") {
            session = nil; url = nil
            return true
        }
        want = profile
        return false
    }

    /// The request was cancelled: nothing is said, and the tab may serve again.
    mutating func cancelled() { busy = false; asked = nil }

    /// The request answered `answer`: the session and profile it serves, and the address, which must be one the browser may
    /// open.
    mutating func served(_ answer: JSON) -> RunServed {
        busy = false
        let askedFor = asked
        asked = nil
        if let id = answer["session"]["id"].string { session = id }
        profile = answer["profile"].string
        var out = RunServed()
        if let address = answer["url"].string, safeWebURL(address) {
            out.reload = address == url
            out.show = address
            url = address
        } else {
            error = "The server did not say where it serves the pull request."
        }
        if let want, session != nil, want != askedFor, want != profile { out.startAgain = true }
        return out
    }

    /// Picks a profile in the tab; true when it should be served now (with a request out, its answer switches instead).
    mutating func pick(_ chosen: String, profiles: [String]) -> Bool {
        guard chosen != shownProfile(profiles) else { return false }
        want = chosen
        return !busy
    }

    /// The tab's session was deleted, and the workspace serving it with it. The picked profile is kept.
    mutating func forget() {
        busy = false
        session = nil; url = nil; profile = nil; asked = nil; error = nil
    }
}
