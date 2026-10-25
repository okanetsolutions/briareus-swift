// Attachment selection, error grouping and cancellation without a server or a slow file volume.
import XCTest
@testable import BriareusMacCore

final class AttachmentFilesTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testRefusedFilesDoNotReserveSlotsAndMetadataSizesAreReadyBeforeReading() throws {
        let folder = try temporaryDirectory()
        let empty = folder.appendingPathComponent("empty")
        try Data().write(to: empty)
        let large = folder.appendingPathComponent("large")
        XCTAssertTrue(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(APIClient.uploadLimit + 1))
        try handle.close()
        let first = folder.appendingPathComponent("first")
        let second = folder.appendingPathComponent("second")
        try Data([1, 2, 3]).write(to: first)
        try Data([4, 5]).write(to: second)
        let batch = prepareAttachmentFiles([folder, empty, large, folder.appendingPathComponent("missing"), first, second], attached: 8)
        XCTAssertEqual(batch.files.map(\.url), [first, second])
        XCTAssertEqual(batch.files.map(\.size), [3, 2])
        XCTAssertEqual(batch.error?.split(separator: "\n").count, 4)
    }

    func testSelectionOverLimitProducesOneJoinedError() throws {
        let folder = try temporaryDirectory()
        let urls = try (0..<15).map { n in
            let url = folder.appendingPathComponent("file-\(n)")
            try Data([1]).write(to: url)
            return url
        }
        let batch = prepareAttachmentFiles(urls, attached: 0)
        XCTAssertEqual(batch.files.map(\.url), Array(urls.prefix(10)))
        XCTAssertEqual(batch.error?.split(separator: "\n").count, 1)
        XCTAssertEqual(prepareAttachmentFiles(urls, attached: 10).files.count, 0)
    }

    func testErrorsAccumulateWithoutDiscardingEarlierRefusals() {
        let first = joinedAttachmentErrors([nil, "first", "second"])
        XCTAssertEqual(joinedAttachmentErrors([first, nil, "third"]), "first\nsecond\nthird")
        XCTAssertNil(joinedAttachmentErrors([nil, ""]))
    }

    func testUnknownSizeIsOmittedUntilBytesAreLoaded() {
        XCTAssertEqual(attachmentChipLabel(name: "photo", size: nil, uploaded: false), "\u{2026} photo")
        XCTAssertTrue(attachmentChipLabel(name: "file", size: 4096, uploaded: false).contains(formatFileSize(4096)))
    }

    func testReadReturnsTheWholeFileAndReportsFilesThatDisappearWhileQueued() async throws {
        let url = try temporaryDirectory().appendingPathComponent("file")
        let bytes = Data(repeating: 42, count: 1024 * 1024 + 7)
        try bytes.write(to: url)
        let file = AttachmentFile(url: url, size: bytes.count)
        let result = await loadAttachmentFile(file)
        XCTAssertEqual(result.files.first?.1, bytes)
        XCTAssertNil(result.error)
        try FileManager.default.removeItem(at: url)
        let failed = await loadAttachmentFile(file)
        XCTAssertTrue(failed.files.isEmpty)
        XCTAssertNotNil(failed.error)
    }

    @MainActor
    func testRemovingAFileDuringReadStopsTheWorkerAndUnblocksTheNextFile() async {
        let queue = AttachmentUploadQueue()
        let reading = expectation(description: "Worker is reading the first chunk")
        let nextFile = expectation(description: "Next file starts after cancellation")
        let finishChunk = DispatchSemaphore(value: 0)
        let first = queue.enqueue {
            do {
                _ = try await readAttachmentBytes {
                    reading.fulfill()
                    // Bound the simulated blocking read so a regression cannot hang the test suite.
                    guard finishChunk.wait(timeout: .now() + 5) == .success else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    return Data([1])
                }
                XCTFail("The removed file must not finish reading")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        let second = queue.enqueue { nextFile.fulfill() }
        await fulfillment(of: [reading], timeout: 5)
        first.cancel()
        finishChunk.signal()
        await fulfillment(of: [nextFile], timeout: 5)
        await second.value
    }
}
