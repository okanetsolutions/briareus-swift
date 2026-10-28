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

    func testDecodedDocumentCostAllowsForAllocationOverheadWithoutOverflow() {
        XCTAssertEqual(DiskCache.documentCost(1024 * 1024), 8 * 1024 * 1024)
        XCTAssertEqual(DiskCache.documentCost(0), 0)
        XCTAssertEqual(DiskCache.documentCost(Int.max), Int.max)
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

    func testRecentDocumentsAreReadFromMemoryAfterTheWriterFinishes() throws {
        cache.store(["n": 1], "k")
        cache.flush()
        // Make a disk read fail: the already-decoded document should still serve repeated overview refreshes.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(DiskCache.fileName("k")))
        XCTAssertEqual(cache.value("k"), ["n": 1])
        XCTAssertNil(DiskCache(directory: directory, protection: []).value("k"))
        cache.remove("k")
        XCTAssertNil(cache.value("k"))
    }

    func testDocumentsReadFromDiskAreAlsoReusedAndCleared() throws {
        cache.store(["n": 1], "k")
        cache.flush()
        let restored = DiskCache(directory: directory, protection: [])
        XCTAssertEqual(restored.value("k"), ["n": 1])
        try FileManager.default.removeItem(at: directory.appendingPathComponent(DiskCache.fileName("k")))
        XCTAssertEqual(restored.value("k"), ["n": 1])
        restored.removeAll()
        XCTAssertNil(restored.value("k"))
    }

    func testNewestSaveReplacesAWarmDocument() {
        cache.store(["n": 1], "k")
        cache.flush()
        cache.store(["n": 2], "k")
        XCTAssertEqual(cache.value("k"), ["n": 2])
        cache.flush()
        XCTAssertEqual(cache.value("k"), ["n": 2])
    }

    func testLogWritesInvalidateDocumentsForTheSameKey() {
        cache.store(["n": 1], "replace")
        cache.flush()
        XCTAssertTrue(cache.replace([["n": 2]], "replace"))
        XCTAssertEqual(cache.value("replace"), ["n": 2])
        XCTAssertTrue(cache.append([["n": 3]], "replace"))
        XCTAssertNil(cache.value("replace"), "A multi-line log is no longer a single JSON document")
        XCTAssertEqual(cache.lines("replace"), [["n": 2], ["n": 3]])
    }

    func testPruningDropsDecodedCopiesOfExpiredDocuments() {
        cache.store(["n": 1], "k")
        cache.flush()
        cache.prune(olderThan: 1, now: Date().addingTimeInterval(60))
        XCTAssertNil(cache.value("k"))
        XCTAssertNil(onDisk("k"))
    }

    func testFailedSaveDoesNotLeaveADecodedDocument() throws {
        try Data().write(to: directory)
        cache.store(["n": 1], "k")
        cache.flush()
        XCTAssertNil(cache.value("k"))
    }
}
