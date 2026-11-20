// The link's state as requests end and the path changes, the poll intervals it stretches, the notice it raises, and
// which failed reads are tried again (ConnectivityLogic.swift).
import XCTest
@testable import BriareusMacCore

final class ConnectivityLogicTests: XCTestCase {
    private func dropped(_ code: URLError.Code = .networkConnectionLost) -> APIError {
        var e = APIError(.network, message: "lost")
        e.networkCode = code.rawValue
        return e
    }

    func testFailuresInARowMakeTheServerUnreachableAndAnAnswerClearsThem() {
        var link = Connectivity()
        XCTAssertEqual(link.state, .online)
        XCTAssertFalse(link.record(dropped()))
        XCTAssertEqual(link.state, .poor)
        _ = link.record(dropped()); _ = link.record(dropped())
        XCTAssertEqual(link.state, .unreachable)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(link.record(nil, at: at), "the server answering again wakes the waiting screens")
        XCTAssertEqual(link.state, .online)
        XCTAssertEqual(link.lastAnswer, at)
        XCTAssertFalse(link.record(nil), "an answer on a working link wakes nobody")
    }

    func testARefusalIsAnAnswerAndACancellationSaysNothing() {
        var link = Connectivity()
        _ = link.record(dropped()); _ = link.record(dropped())
        _ = link.record(APIError(.cancelled))
        XCTAssertEqual(link.failures, 2)
        _ = link.record(APIError(.http, status: 503))
        XCTAssertEqual(link.failures, 0)
        XCTAssertNotNil(link.lastAnswer)
    }

    func testNoWayOutIsOfflineAndAWayBackWakesTheScreens() {
        var link = Connectivity()
        XCTAssertFalse(link.pathChanged(NetworkPath(reachable: false)))
        XCTAssertEqual(link.state, .offline)
        XCTAssertTrue(link.pausesReads)
        XCTAssertTrue(link.pathChanged(NetworkPath(reachable: true, expensive: true)))
        XCTAssertEqual(link.state, .online)
        XCTAssertFalse(link.pausesReads)
        XCTAssertFalse(link.pathChanged(NetworkPath(reachable: true, expensive: true)), "the same path again changes nothing")
    }

    func testANewPathAfterFailuresStartsAfreshButOneOnAWorkingLinkWakesNobody() {
        var link = Connectivity()
        XCTAssertFalse(link.pathChanged(NetworkPath(reachable: true, expensive: true)))
        _ = link.record(dropped()); _ = link.record(dropped()); _ = link.record(dropped())
        XCTAssertTrue(link.pathChanged(NetworkPath(reachable: true)), "Wi-Fi after the cellular link stalled")
        XCTAssertEqual(link.failures, 0)
    }

    func testOnlyOfflineAndUnreachableAreLost() {
        XCTAssertEqual([LinkState.online, .poor, .unreachable, .offline].map(\.isLost), [false, false, true, true])
        XCTAssertEqual([LinkState.online, .poor, .unreachable, .offline].map(\.canWriteNow), [true, true, false, false])
    }

    func testLowDataModeIsAPoorLinkWithNoNotice() {
        var link = Connectivity()
        _ = link.pathChanged(NetworkPath(reachable: true, constrained: true))
        XCTAssertEqual(link.state, .poor)
        XCTAssertNil(link.notice)
    }

    func testPollsSlowDownOnAPoorLinkOnly() {
        var link = Connectivity()
        XCTAssertEqual(link.pollInterval(2), 2)
        XCTAssertEqual(link.pollInterval(7), 7)
        _ = link.record(dropped())
        XCTAssertEqual(link.pollInterval(2), 10)
        XCTAssertEqual(link.pollInterval(7), 30)
        XCTAssertEqual(link.pollInterval(120), 300)
        XCTAssertEqual(link.pollInterval(600), 600, "a long interval is never shortened")
    }

    func testPollsStaySlowUntilTwoAnswersOrANewPath() {
        var link = Connectivity()
        for _ in 0..<3 { _ = link.record(dropped()) }
        XCTAssertEqual(link.state, .unreachable)
        XCTAssertEqual(pollDelay(base: link.pollInterval(7), failures: 3, retryAfter: nil), 30)

        XCTAssertTrue(link.record(nil), "the first answer still wakes waiting screens")
        XCTAssertNil(link.notice)
        XCTAssertEqual(pollDelay(base: link.pollInterval(2), failures: 0, retryAfter: nil), 10)
        XCTAssertEqual(pollDelay(base: link.pollInterval(7), failures: 0, retryAfter: nil), 30)
        _ = link.record(APIError(.cancelled))
        XCTAssertEqual(link.pollInterval(7), 30)
        _ = link.record(nil)
        XCTAssertEqual(link.pollInterval(7), 7)

        _ = link.record(dropped())
        _ = link.record(nil)
        _ = link.record(dropped())
        _ = link.record(nil)
        XCTAssertEqual(link.pollInterval(7), 30, "an intervening failure restarts recovery")
        _ = link.pathChanged(NetworkPath(reachable: false))
        XCTAssertTrue(link.pathChanged(NetworkPath(reachable: true)))
        XCTAssertEqual(link.pollInterval(2), 2)
        _ = link.pathChanged(NetworkPath(reachable: true, constrained: true))
        _ = link.record(nil)
        _ = link.record(nil)
        XCTAssertEqual(link.pollInterval(7), 30, "Low Data Mode still slows polling")
    }

    func testTheNoticeFollowsTheStateAndCarriesWhenTheServerLastAnswered() {
        var link = Connectivity()
        XCTAssertNil(link.notice)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        _ = link.record(nil, at: at)
        _ = link.record(dropped()); _ = link.record(dropped()); _ = link.record(dropped())
        XCTAssertEqual(link.notice, ConnectivityNotice(kind: .unreachable, savedAt: at))
        _ = link.pathChanged(NetworkPath(reachable: false))
        XCTAssertEqual(link.notice?.kind, .offline)
        XCTAssertEqual(link.notice?.savedAt, at)
        XCTAssertNotEqual(ConnectivityNotice(kind: .offline).symbol, ConnectivityNotice(kind: .unreachable).symbol)
        XCTAssertEqual(ConnectivityNotice(kind: .unreachable).tone, .warn)
    }

    func testTheNoticeNamesTheSavedTimeOnlyWhenThereIsOne() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let utc = TimeZone(identifier: "UTC")!, locale = Locale(identifier: "en_US_POSIX")
        let clock = formatEventTime(at, now: at, locale: locale, timeZone: utc)
        XCTAssertTrue(ConnectivityNotice(kind: .offline, savedAt: at).detail(now: at, locale: locale, timeZone: utc).contains(clock))
        XCTAssertFalse(ConnectivityNotice(kind: .offline).detail(now: at, locale: locale, timeZone: utc).contains(clock))
    }

    func testPollDelayBacksOffAndHonoursRetryAfter() {
        XCTAssertEqual(pollDelay(base: 7, failures: 0, retryAfter: nil), 7)
        XCTAssertEqual(pollDelay(base: 7, failures: 1, retryAfter: nil), 7)
        XCTAssertEqual(pollDelay(base: 7, failures: 3, retryAfter: nil), 8)
        XCTAssertEqual(pollDelay(base: 10, failures: 1, retryAfter: nil), 10)
        XCTAssertEqual(pollDelay(base: 30, failures: 1, retryAfter: 20), 30)
        XCTAssertEqual(pollDelay(base: 7, failures: 20, retryAfter: nil), 60)
        XCTAssertEqual(pollDelay(base: 120, failures: 20, retryAfter: nil), 120)
        XCTAssertEqual(pollDelay(base: 7, failures: 1, retryAfter: 90), 90)
    }

    func testOnlyADroppedOrStalledLinkIsTransient() {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed] {
            XCTAssertTrue(transientNetworkFailure(code), "\(code)")
        }
        for code in [URLError.Code.serverCertificateUntrusted, .badURL, .cancelled, .userAuthenticationRequired] {
            XCTAssertFalse(transientNetworkFailure(code), "\(code)")
        }
    }

    func testADroppedReadIsTriedTwiceAndATimedOutOneOnce() {
        XCTAssertEqual(readRetryDelay(after: dropped(), attempt: 0, jitter: 1), 1)
        XCTAssertEqual(readRetryDelay(after: dropped(), attempt: 1, jitter: 1), 3)
        XCTAssertNil(readRetryDelay(after: dropped(), attempt: 2, jitter: 1))
        XCTAssertEqual(readRetryDelay(after: dropped(.timedOut), attempt: 0, jitter: 1), 1)
        XCTAssertNil(readRetryDelay(after: dropped(.timedOut), attempt: 1, jitter: 1))
        XCTAssertEqual(readRetryDelay(after: dropped(), attempt: 0, jitter: 1.2), 1.2)
    }

    func testRefusalsAndUnknownFailuresAreNotRetried() {
        XCTAssertNil(readRetryDelay(after: APIError(.http, status: 503), attempt: 0, jitter: 1))
        XCTAssertNil(readRetryDelay(after: APIError(.network), attempt: 0, jitter: 1), "no reason, no retry")
        XCTAssertNil(readRetryDelay(after: dropped(.serverCertificateUntrusted), attempt: 0, jitter: 1))
        XCTAssertNil(readRetryDelay(after: APIError(.cancelled), attempt: 0, jitter: 1))
    }
}
