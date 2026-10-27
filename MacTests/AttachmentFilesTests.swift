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
        let batch = limitAttachmentFiles(checkAttachmentFiles([folder, empty, large, folder.appendingPathComponent("missing"), first, second]), attached: 8)
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
        let batch = limitAttachmentFiles(checkAttachmentFiles(urls), attached: 0)
        XCTAssertEqual(batch.files.map(\.url), Array(urls.prefix(10)))
        XCTAssertEqual(batch.error?.split(separator: "\n").count, 1)
        XCTAssertEqual(limitAttachmentFiles(checkAttachmentFiles(urls), attached: 10).files.count, 0)
    }

    func testErrorsAccumulateWithoutDiscardingEarlierRefusals() {
        let first = joinedAttachmentErrors([nil, "first", "second"])
        XCTAssertEqual(joinedAttachmentErrors([first, nil, "third"]), "first\nsecond\nthird")
        XCTAssertNil(joinedAttachmentErrors([nil, ""]))
    }

    func testUnknownSizeIsOmittedUntilBytesAreLoaded() {
        let label = attachmentChipLabel(name: "photo", size: nil, uploaded: false)
        XCTAssertTrue(label.contains("photo"))
        XCTAssertFalse(label.contains(formatFileSize(0)))
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

    func testAFileChangedWhileQueuedUploadsItsCurrentBytes() async throws {
        let url = try temporaryDirectory().appendingPathComponent("file")
        try Data([1, 2]).write(to: url)
        let file = try XCTUnwrap(checkAttachmentFiles([url]).files.first)
        for bytes in [Data([2, 3, 4]), Data([5])] {
            try bytes.write(to: url)
            let result = await loadAttachmentFile(file)
            XCTAssertEqual(result.files.first?.1, bytes)
            XCTAssertNil(result.error)
        }
    }

    func testSlotsAreRecheckedAfterMetadataWasLoaded() throws {
        let folder = try temporaryDirectory()
        let urls = try (0..<3).map { n in
            let url = folder.appendingPathComponent("file-\(n)")
            try Data([1]).write(to: url)
            return url
        }
        let checked = checkAttachmentFiles([folder] + urls)
        let batch = limitAttachmentFiles(checked, attached: 9)
        XCTAssertEqual(batch.files.map(\.url), [urls[0]])
        XCTAssertEqual(batch.error?.split(separator: "\n").count, 2)
    }

    @MainActor
    func testProviderLoadReturnsBytesAndForwardsFailures() async throws {
        let bytes = Data([1, 2, 3])
        let data = try await loadAttachmentData { completion in
            completion(.success(bytes))
            return Progress(totalUnitCount: 1)
        }
        XCTAssertEqual(data, bytes)
        do {
            _ = try await loadAttachmentData { completion in
                completion(.failure(CocoaError(.fileReadUnknown)))
                return Progress(totalUnitCount: 1)
            }
            XCTFail("The provider failure must reach the caller")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadUnknown) }
    }

    @MainActor
    func testRemovingAPhotoCancelsItsProviderAndNeverEncodesLateBytes() async {
        let queue = AttachmentUploadQueue()
        let loading = expectation(description: "Provider is loading")
        let cancelled = expectation(description: "Provider receives cancellation")
        let provider = Progress(totalUnitCount: 1)
        provider.cancellationHandler = { cancelled.fulfill() }
        var finishLoad: (@Sendable (Result<Data?, Error>) -> Void)?
        let first = queue.enqueue(releaseOnCancel: false) {
            do {
                _ = try await loadAttachmentData { completion in
                    finishLoad = completion
                    loading.fulfill()
                    return provider
                }
                XCTFail("A removed photo must not proceed to encoding")
            } catch { XCTAssertTrue(error is CancellationError) }
        }
        await fulfillment(of: [loading], timeout: 5)
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 5)
        finishLoad?(.success(Data([1])))
        await first.value
    }

    @MainActor
    func testCancellationBeforeProviderRegistrationStillCancelsTheLoad() async {
        let provider = Progress(totalUnitCount: 1)
        let task = Task {
            try await loadAttachmentData { completion in
                provider.cancellationHandler = { completion(.success(Data([1]))) }
                withUnsafeCurrentTask { $0?.cancel() }
                return provider
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled loads must discard their bytes")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(provider.isCancelled)
    }

    @MainActor
    func testRemovedPhotoFinishesItsCurrentConversionBeforeTheNextFileLoads() async {
        let queue = AttachmentUploadQueue()
        let encoding = expectation(description: "Photo is inside a synchronous conversion")
        let overlap = expectation(description: "Next file must not start during conversion")
        overlap.isInverted = true
        let finishConversion = DispatchSemaphore(value: 0)
        var events: [String] = []
        let first = queue.enqueue(releaseOnCancel: false) {
            let worker = Task.detached { () -> Void in
                encoding.fulfill()
                XCTAssertEqual(finishConversion.wait(timeout: .now() + 5), .success)
            }
            await worker.value
            events.append("conversion stopped")
        }
        let second = queue.enqueue {
            if events.isEmpty { overlap.fulfill() }
            events.append("next file loads")
        }
        await fulfillment(of: [encoding], timeout: 5)
        first.cancel()
        await fulfillment(of: [overlap], timeout: 0.1)
        finishConversion.signal()
        await first.value
        await second.value
        XCTAssertEqual(events, ["conversion stopped", "next file loads"])
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
        await fulfillment(of: [nextFile], timeout: 2)
        finishChunk.signal()
        await first.value
        await second.value
    }
}
