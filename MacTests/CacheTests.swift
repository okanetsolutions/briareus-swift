// The saved-response cache: saves reach the disk off the calling thread, and reads see them at once.
import XCTest
@testable import BriareusMacCore

final class CacheTests: XCTestCase {
    private var directory: URL!
    private var cache: DiskCache!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("briareus-cache-\(UUID().uuidString)")
        cache = DiskCache(directory: directory, protection: [])
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private func onDisk(_ key: String) -> JSON? {
        (try? Data(contentsOf: directory.appendingPathComponent(DiskCache.fileName(key)))).flatMap(JSON.parse)
    }

    func testReadsSeeASaveBeforeItIsWritten() {
        cache.store(["n": 1], "k")
        XCTAssertEqual(cache.value("k"), ["n": 1])
        cache.flush()
        XCTAssertEqual(onDisk("k"), ["n": 1])
        XCTAssertEqual(cache.value("k"), ["n": 1])
    }

    func testTheNewestSaveOfAKeyWins() {
        for n in 1...20 { cache.store(["n": JSON(n)], "k") }
        XCTAssertEqual(cache.value("k"), ["n": 20])
        cache.flush()
        XCTAssertEqual(onDisk("k"), ["n": 20])
    }

    func testRemovingDropsASaveStillWaiting() {
        cache.store(["n": 1], "k")
        cache.remove("k")
        XCTAssertNil(cache.value("k"))
        cache.flush()
        XCTAssertNil(onDisk("k"))

        cache.store(["n": 2], "a")
        cache.removeAll()
        cache.flush()
        XCTAssertNil(cache.value("a"))
        XCTAssertNil(onDisk("a"))
    }

    func testASaveAfterRemovingAllIsKept() {
        cache.store(["n": 1], "k")
        cache.removeAll()
        cache.store(["n": 2], "k")
        cache.flush()
        XCTAssertEqual(onDisk("k"), ["n": 2])
    }
}
