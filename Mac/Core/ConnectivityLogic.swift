// How good the link to the server is, judged from the device's network path and how recent requests ended, and what
// that changes on a train or anywhere the signal comes and goes: how often screens ask again, whether they ask at all,
// which failed reads are worth asking again at once, and the one notice both apps show for a lost connection.
// No UI here.
import Foundation

/// The device's network path as the system reports it.
struct NetworkPath: Equatable, Sendable {
    /// There is a way out (Wi-Fi, cellular or wired).
    var reachable: Bool
    /// Low Data Mode is on for it.
    var constrained = false
    /// It is metered (cellular, or a phone's hotspot). A move between Wi-Fi and cellular changes it.
    var expensive = false

    /// Until the system first answers, the path is taken to work.
    static let unknown = NetworkPath(reachable: true)
}

/// The link as the apps act on it.
enum LinkState: Equatable, Sendable {
    case online
    /// Low Data Mode, or a request failed lately: screens ask less often.
    case poor
    /// There is a way out but the server has not answered several requests in a row.
    case unreachable
    /// No way out at all: nothing is asked until there is one.
    case offline

    /// The link is lost (offline, or the server out of reach), as against working, however poorly.
    var isLost: Bool { self == .offline || self == .unreachable }

    /// Whether the link can attempt an immediate write. The caller still checks permissions and server support.
    var canWriteNow: Bool { !isLost }
}

/// The link's state, kept as requests end and the path changes.
struct Connectivity: Equatable, Sendable {
    /// Network failures in a row after which the server counts as out of reach.
    static let unreachableAfter = 3

    private(set) var path = NetworkPath.unknown
    /// Requests in a row that got no answer at all.
    private(set) var failures = 0
    /// Two answers in a row restore fast polling after a failure, even though the first clears the notice.
    private var answersToRestorePolling = 0
    /// When the server last answered anything, a refusal included.
    private(set) var lastAnswer: Date?

    var state: LinkState {
        if !path.reachable { return .offline }
        if failures >= Connectivity.unreachableAfter { return .unreachable }
        if path.constrained || failures > 0 { return .poor }
        return .online
    }

    /// Reads wait while there is no way out: each would fail at once and wake the radio for nothing.
    var pausesReads: Bool { state == .offline }

    /// The system reported a path. True when waiting screens should ask now: a way out appeared, or a new one (Wi-Fi to
    /// cellular, another network) after requests had been failing.
    mutating func pathChanged(_ next: NetworkPath) -> Bool {
        guard next != path else { return false }
        let wasFailing = !path.reachable || answersToRestorePolling > 0
        path = next
        guard next.reachable else { return false }
        failures = 0
        answersToRestorePolling = 0
        return wasFailing
    }

    /// A request ended. An answer from the server (nil, or any error but a network one) clears the failures; a request
    /// that got no answer adds one; a cancelled one says nothing. True when the server answers again after being out of
    /// reach, so screens waiting out a long backoff can ask now.
    mutating func record(_ error: APIError?, at now: Date = Date()) -> Bool {
        if let error, error.kind == .cancelled { return false }
        if let error, error.kind == .network {
            failures += 1
            answersToRestorePolling = 2
            return false
        }
        let wasUnreachable = state == .unreachable
        failures = 0
        answersToRestorePolling = max(0, answersToRestorePolling - 1)
        lastAnswer = now
        return wasUnreachable
    }

    /// The interval a screen polls at: an active conversation's 2 s becomes 10 s on a poor link and a list's 7 s
    /// becomes 30 s. Other intervals stretch up to 5 minutes, preserving any longer base.
    func pollInterval(_ base: TimeInterval) -> TimeInterval {
        guard state != .online || answersToRestorePolling > 0 else { return base }
        if base == 7 { return 30 }
        return max(base, min(max(base * 4, 10), 300))
    }

    /// What the apps show while the link is lost, or nil while it works (a poor link says nothing: screens only slow down).
    var notice: ConnectivityNotice? {
        switch state {
        case .online, .poor: return nil
        case .offline: return ConnectivityNotice(kind: .offline, savedAt: lastAnswer)
        case .unreachable: return ConnectivityNotice(kind: .unreachable, savedAt: lastAnswer)
        }
    }
}

/// The one notice both apps show at the top while the link is lost, instead of each screen reporting it.
struct ConnectivityNotice: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case offline, unreachable }
    var kind: Kind
    /// When the server last answered: what is on screen is from then or before. Nil when it has not answered since launch.
    var savedAt: Date?

    var title: String {
        switch kind {
        case .offline: return "Offline"
        case .unreachable: return "Can’t reach the server"
        }
    }

    /// What is on screen and what happens next.
    func detail(now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let saved = savedAt.map { "Showing what was saved at \(formatEventTime($0, now: now, locale: locale, timeZone: timeZone))." }
            ?? "Showing what was saved."
        switch kind {
        case .offline: return "\(saved) Updates resume when the connection is back."
        case .unreachable: return "\(saved) The connection is weak or the server is down; trying again."
        }
    }

    /// The SF Symbol both apps draw it with.
    var symbol: String {
        switch kind {
        case .offline: return "wifi.slash"
        case .unreachable: return "wifi.exclamationmark"
        }
    }
    var tone: RowTone { kind == .offline ? .muted : .warn }
}

// MARK: - Waiting

/// The delay before the next poll, at least `base` (already stretched for the link when applicable). Failures back off
/// exponentially up to a minute, and Retry-After can extend the wait further.
func pollDelay(base: TimeInterval, failures: Int, retryAfter: Double?) -> TimeInterval {
    let backoff = failures > 0 ? min(pow(2, Double(min(failures, 6))), 60) : 0
    return max(base, backoff, retryAfter ?? 0)
}

/// Whether a request that got no answer for this reason is worth trying again at once: the link dropped or stalled, as
/// it does going through a tunnel or between cells, which on a phone often shows as a name lookup that failed. A
/// certificate, a malformed address or a refused login is not.
func transientNetworkFailure(_ code: URLError.Code) -> Bool {
    switch code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed,
         .cannotFindHost, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
        return true
    default:
        return false
    }
}

/// The seconds to wait before reading again after a read that got no answer, `attempt` retries in, or nil to give up
/// and let the screen's own polling carry on. A dropped link is tried twice more (about 1 s, then 3 s, give or take
/// `jitter`); a timed-out read only once, since each try may take the whole timeout. Writes are never retried here: one
/// that got no answer may have gone through.
func readRetryDelay(after error: APIError, attempt: Int, jitter: Double = Double.random(in: 0.8...1.2)) -> TimeInterval? {
    guard error.kind == .network, let raw = error.networkCode, transientNetworkFailure(URLError.Code(rawValue: raw)) else { return nil }
    let limit = raw == URLError.Code.timedOut.rawValue ? 1 : 2
    guard attempt >= 0, attempt < limit else { return nil }
    return (attempt == 0 ? 1 : 3) * jitter
}
