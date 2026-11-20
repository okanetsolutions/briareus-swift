// Waits a returning link cuts short, the notice a link raises, identical reads sharing one request, and a GET tried
// again after a dropped link while a write never is (LinkWatch.swift, SingleFlight.swift, APIClient.call).
import XCTest
@testable import BriareusMacCore

/// Answers each request from a script: a dropped link (`nil`) or a JSON body. It can hold GETs until released.
private final class Scripted: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String?]
    private(set) var methods: [String] = []
    var gate: WakeSignal?
    init(_ script: [String?]) { self.script = script }
    var count: Int { lock.lock(); defer { lock.unlock() }; return methods.count }
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeout: TimeInterval) async throws -> HTTPResponse {
        lock.lock()
        methods.append(method)
        let next = script.isEmpty ? "{}" : script.removeFirst()
        lock.unlock()
        if method == "GET", let gate { await gate.sleep(5) }
        guard let next else { throw URLSessionTransport.failure(URLError(.networkConnectionLost)) }
        return HTTPResponse(status: 200, contentType: "application/json", retryAfter: nil, body: Data(next.utf8))
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [T] = []
    func add(_ v: T) { lock.lock(); value.append(v); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return value }
}

final class LinkWatchTests: XCTestCase {
    private func client(_ transport: HTTPTransport) throws -> APIClient {
        let c = try APIClient(address: ServerAddress("https://example.com")!, token: "brm_" + String(repeating: "a", count: 43), transport: transport)
        c.retryScale = 0
        return c
    }

    // MARK: WakeSignal

    func testASleepEndsWhenTheSignalFires() async {
        let signal = WakeSignal()
        let start = Date()
        let sleeper = Task { await signal.sleep(30) }
        while signal.waiting == 0 { await Task.yield() }
        signal.fire()
        await sleeper.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(signal.waiting, 0)
    }

    func testASleepEndsOnItsOwnAndOnCancellation() async {
        let signal = WakeSignal()
        await signal.sleep(0.01)
        let start = Date()
        let sleeper = Task { await signal.sleep(30) }
        while signal.waiting == 0 { await Task.yield() }
        sleeper.cancel()
        await sleeper.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(signal.waiting, 0)
    }

    // MARK: LinkWatch

    func testTheNoticeIsToldOnlyWhenItChanges() {
        let watch = LinkWatch()
        let told = Box<ConnectivityNotice?>()
        watch.noticeChanged = { told.add($0) }
        var dropped = APIError(.network)
        dropped.networkCode = URLError.Code.timedOut.rawValue
        watch.record(dropped); watch.record(dropped)
        XCTAssertTrue(told.all.isEmpty, "a poor link raises no notice")
        watch.record(dropped)
        XCTAssertEqual(told.all.last??.kind, .unreachable)
        watch.record(dropped)
        XCTAssertEqual(told.all.count, 1)
        watch.record(nil)
        XCTAssertEqual(told.all.count, 2)
        XCTAssertNil(told.all.last!)
        watch.pathChanged(NetworkPath(reachable: false))
        XCTAssertEqual(told.all.last??.kind, .offline)
    }

    func testAWayBackWakesWhoeverWaitsForOne() async {
        let watch = LinkWatch()
        watch.pathChanged(NetworkPath(reachable: false))
        let start = Date()
        let waiter = Task { await watch.untilReachable() }
        while watch.wake.waiting == 0 { await Task.yield() }
        watch.pathChanged(NetworkPath(reachable: true))
        await waiter.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        await watch.untilReachable()   // at once while there is a way out
    }

    // MARK: SingleFlight

    func testIdenticalReadsAtOnceShareOneRequest() async throws {
        let flights = SingleFlight<Int>()
        let calls = Box<Int>()
        let gate = WakeSignal()
        async let a = flights.run("k") { calls.add(1); await gate.sleep(5); return 7 }
        while flights.inFlight == 0 { await Task.yield() }
        async let b = flights.run("k") { calls.add(1); return 8 }
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.fire()
        let (x, y) = try await (a, b)
        XCTAssertEqual(x, 7); XCTAssertEqual(y, 7)
        XCTAssertEqual(calls.all.count, 1)
        XCTAssertEqual(flights.inFlight, 0)
    }

    func testACallerThatLeavesIsCancelledAndTheReadEndsWithTheLastOne() async throws {
        let flights = SingleFlight<Int>()
        let ended = Box<Bool>()
        let first = Task { try await flights.run("k") { await WakeSignal().sleep(30); ended.add(Task.isCancelled); return 1 } }
        while flights.inFlight == 0 { await Task.yield() }
        first.cancel()
        do { _ = try await first.value; XCTFail("a cancelled caller throws") } catch let e as APIError { XCTAssertEqual(e.kind, .cancelled) }
        XCTAssertEqual(flights.inFlight, 0)
        while ended.all.isEmpty { await Task.yield() }
        XCTAssertEqual(ended.all, [true])
    }

    // MARK: APIClient

    func testAGetIsTriedAgainAfterADroppedLink() async throws {
        let transport = Scripted([nil, nil, #"{"pulls":[]}"#])
        let answer = try await client(transport).call("pulls", ["repo": "o/r"])
        XCTAssertTrue(answer["pulls"].isArray)
        XCTAssertEqual(transport.count, 3)
    }

    func testAGetGivesUpAfterItsRetries() async throws {
        let transport = Scripted([nil, nil, nil, "{}"])
        do { _ = try await client(transport).call("pulls", ["repo": "o/r"]); XCTFail("three drops in a row fail the read") }
        catch let e as APIError { XCTAssertEqual(e.kind, .network); XCTAssertEqual(e.networkCode, URLError.Code.networkConnectionLost.rawValue) }
        XCTAssertEqual(transport.count, 3)
    }

    func testAWriteIsNeverTriedAgain() async throws {
        let transport = Scripted([nil, "{}"])
        do { _ = try await client(transport).call("message", ["sessionId": "s1", "text": "hi"]); XCTFail("the drop is reported") }
        catch let e as APIError { XCTAssertEqual(e.kind, .network) }
        XCTAssertEqual(transport.methods, ["POST"])
    }

    func testIdenticalGetsShareARequestButNotAcrossAWrite() async throws {
        let transport = Scripted([#"{"n":1}"#, "{}", #"{"n":2}"#])
        let gate = WakeSignal()
        transport.gate = gate
        let c = try client(transport)
        async let a = c.call("pulls", ["repo": "o/r"])
        while transport.count < 1 { await Task.yield() }
        async let b = c.call("pulls", ["repo": "o/r"])
        while c.reads.waiting < 2 { await Task.yield() }
        XCTAssertEqual(transport.count, 1, "the second read joined the first")
        // A write while the first read is still held: a read asked after it does not join the one from before it.
        _ = try await c.call("message", ["sessionId": "s1", "text": "hi"])
        async let after = c.call("pulls", ["repo": "o/r"])
        let deadline = Date().addingTimeInterval(4)
        while transport.count < 3 && Date() < deadline { await Task.yield() }
        XCTAssertEqual(transport.count, 3, "the read after the write made its own request")
        gate.fire()
        let (x, y, z) = try await (a, b, after)
        XCTAssertEqual(x["n"].truncatedInt, 1); XCTAssertEqual(y["n"].truncatedInt, 1)
        XCTAssertEqual(z["n"].truncatedInt, 2)
        XCTAssertEqual(transport.methods, ["GET", "POST", "GET"])
    }

    // MARK: Pausing

    func testAPauseSaysWhetherTheLinkCameBack() async {
        let watch = LinkWatch()
        let quiet = await watch.pause(0.01)
        XCTAssertFalse(quiet, "a link that was never lost did not come back")
        watch.pathChanged(NetworkPath(reachable: false))
        let start = Date()
        let pausing = Task { await watch.pause(30) }
        while watch.wake.waiting == 0 { await Task.yield() }
        watch.pathChanged(NetworkPath(reachable: true))
        let back = await pausing.value
        XCTAssertTrue(back)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testAReturningLinkDoesNotCutARetryAfterShort() async {
        let watch = LinkWatch()
        watch.pathChanged(NetworkPath(reachable: false))
        let start = Date()
        let pausing = Task { await watch.pause(0.6, atLeast: 0.4) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        watch.pathChanged(NetworkPath(reachable: true))
        _ = await pausing.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.4)
    }
}
