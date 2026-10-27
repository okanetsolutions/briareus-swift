// Live transcript updates preserve ordering and folded runs without rebuilding completed history.
import XCTest
@testable import BriareusMacCore

final class TranscriptTests: XCTestCase {
    private func line(_ seq: Int, _ kind: String, _ text: String? = nil) -> JSON {
        var value: JSON = ["seq": JSON(seq), "kind": .string(kind)]
        if let text { value["text"] = .string(text) }
        return value
    }

    @discardableResult
    private func append(_ value: JSON, to transcript: inout Transcript, using builder: TranscriptBlockBuilder) -> Bool {
        let changed = transcript.append(value)
        return builder.update(transcript.events, changed: changed)
    }

    func testIncrementalFoldingMatchesWholeReadsAtEveryBatchBoundary() {
        let input = [line(1, "user", "Start"), line(2, "info", "Cloning"), line(3, "cmd", "install"),
                     line(4, "status"), line(5, "setup", "Ready"), line(6, "info", "Session started"),
                     line(7, "info", "Notice"), line(8, "tool"), line(9, "tool_error"), line(10, "status"),
                     line(11, "tool"), line(12, "text", "Answer"), line(13, "result"),
                     line(14, "stdout", "Preparing again"), line(15, "git", "checkout"),
                     line(16, "info", "Started worker 2"), line(17, "stdout", "Notice"),
                     line(18, "user", "Next turn"), line(19, "cmd", "setup"), line(20, "tool")]
        let events = input.compactMap(Event.init)
        let expected: [TranscriptBlock] = [.event(events[0]), .preparation(Array(events[1...2])),
            .preparation([events[4]]), .event(events[5]), .event(events[6]), .tools(Array(events[7...8])),
            .tools([events[10]]), .event(events[11]), .event(events[12]), .preparation(Array(events[13...14])),
            .event(events[15]), .event(events[16]), .event(events[17]), .preparation([events[18]]), .tools([events[19]])]
        XCTAssertEqual(transcriptBlocks(events), expected)
        for split in 0...input.count {
            var transcript = Transcript()
            let builder = TranscriptBlockBuilder()
            append(.array(Array(input[..<split])), to: &transcript, using: builder)
            append(.array(Array(input[split...])), to: &transcript, using: builder)
            XCTAssertEqual(Array(builder.blocks), expected, "Split at \(split)")
            XCTAssertEqual(transcript.cursor, 20)
        }
        var streamed = Transcript()
        let builder = TranscriptBlockBuilder()
        for (i, value) in input.enumerated() {
            append(.array([value]), to: &streamed, using: builder)
            XCTAssertEqual(Array(builder.blocks), transcriptBlocks(Array(events[...i])), "Line \(i)")
        }
    }

    func testInvisibleLinesAdvanceTheCursorWithoutChangingRows() {
        var transcript = Transcript()
        let builder = TranscriptBlockBuilder()
        XCTAssertTrue(append(.array([line(1, "tool")]), to: &transcript, using: builder))
        let first = builder.blocks
        XCTAssertFalse(append(.array([line(2, "status", "working"), line(3, "future")]), to: &transcript, using: builder))
        XCTAssertEqual(builder.blocks, first)
        XCTAssertEqual(transcript.cursor, 3)
        XCTAssertEqual(transcript.events.count, 3)
        XCTAssertTrue(append(.array([line(4, "tool")]), to: &transcript, using: builder))
        XCTAssertEqual(builder.blocks.map(\.seq), [1, 4], "Hidden events must still separate contiguous tool runs")
    }

    func testReplayAndMalformedEventsAddNoRowsAndKeepTheFirstCopy() {
        var transcript = Transcript()
        let builder = TranscriptBlockBuilder()
        let original = line(4, "text", "Original")
        append(.array([original]), to: &transcript, using: builder)
        let saved = transcript
        XCTAssertFalse(append(.array([line(4, "text", "Replay"), ["seq": 8], ["kind": "tool"], .null]), to: &transcript, using: builder))
        XCTAssertFalse(append(["events": [line(9, "tool")]], to: &transcript, using: builder))
        XCTAssertEqual(transcript, saved)
        XCTAssertEqual(Array(builder.blocks), [.event(Event(original)!)])
    }

    func testLateInsertionRebuildsRunsAndPreservesSnapshots() {
        var transcript = Transcript()
        let builder = TranscriptBlockBuilder()
        append(.array([line(2, "tool"), line(6, "tool")]), to: &transcript, using: builder)
        let before = transcript
        let beforeRows = builder.blocks
        XCTAssertTrue(append(.array([line(4, "status")]), to: &transcript, using: builder))
        XCTAssertEqual(builder.blocks.map(\.seq), [2, 6])
        XCTAssertEqual(beforeRows.count, 1)
        XCTAssertEqual(Array(beforeRows), transcriptBlocks(before.events))
        XCTAssertEqual(before.events.map(\.seq), [2, 6])
        XCTAssertEqual(transcript.cursor, 6)
        XCTAssertTrue(append(.array([line(1, "info", "Cloning"), line(3, "info", "Session started")]), to: &transcript, using: builder))
        XCTAssertEqual(transcript.events.map(\.seq), [1, 2, 3, 4, 6])
        XCTAssertEqual(Array(builder.blocks), transcriptBlocks(transcript.events))
    }

    func testUnorderedBatchesAndRestoredTranscriptsHaveTheSameRows() {
        var transcript = Transcript()
        let builder = TranscriptBlockBuilder()
        let input = [line(8, "result"), line(2, "tool"), line(6, "text", "Answer"), line(2, "text", "Duplicate")]
        append(.array(input), to: &transcript, using: builder)
        XCTAssertEqual(transcript.events.map(\.seq), [2, 6, 8])
        XCTAssertEqual(transcript.events[0].kind, "tool")
        var restored = Transcript()
        var restoredBuilder = TranscriptBlockBuilder()
        append(transcript.json, to: &restored, using: restoredBuilder)
        XCTAssertEqual(restored, transcript)
        XCTAssertEqual(restoredBuilder.blocks, builder.blocks)
        // Resetting after Clear or a full refresh must also reset deduplication and folding state.
        restored = Transcript()
        restoredBuilder = TranscriptBlockBuilder()
        append(.array([line(2, "info", "New setup")]), to: &restored, using: restoredBuilder)
        XCTAssertEqual(Array(restoredBuilder.blocks), [.preparation([Event(line(2, "info", "New setup"))!])])
    }

    func testLongLiveConversationKeepsHistoryAndGroupsOnlyAdjacentSteps() {
        var transcript = Transcript()
        let builder = TranscriptBlockBuilder()
        for seq in 1...4_000 {
            append(.array([line(seq, seq.isMultiple(of: 3) ? "tool" : "text", "Line \(seq)")]), to: &transcript, using: builder)
        }
        XCTAssertEqual(transcript.cursor, 4_000)
        XCTAssertEqual(transcript.events.count, 4_000)
        XCTAssertEqual(builder.blocks.count, 4_000)
        XCTAssertEqual(Array(builder.blocks), transcriptBlocks(transcript.events))
    }

    func testSnapshotsKeepTheirTailWhileRunsGrowAndHistoryExpands() {
        var transcript = Transcript()
        let builder = TranscriptBlockBuilder()
        let input = [line(1, "user", "Start"), line(2, "cmd", "setup"), line(3, "stdout", "Ready"),
                     line(4, "info", "Session started"), line(5, "tool"), line(6, "tool_error"), line(7, "result")]
        var snapshots: [TranscriptRows] = [builder.blocks]
        for value in input {
            append(.array([value]), to: &transcript, using: builder)
            snapshots.append(builder.blocks)
        }
        for (count, snapshot) in snapshots.enumerated() {
            let expected = transcriptBlocks(input.prefix(count).compactMap(Event.init))
            XCTAssertEqual(Array(snapshot), expected, "Snapshot before line \(count + 1)")
            XCTAssertEqual(Array(snapshot.reversed()), Array(expected.reversed()))
        }
        XCTAssertNotEqual(snapshots[2], snapshots[3], "Growing a folded run must invalidate the equatable column")
        XCTAssertNotEqual(snapshots[5], snapshots[6])
        XCTAssertTrue(transcriptAnswered(builder.blocks))
        XCTAssertFalse(transcriptAnswered(snapshots[6]))
    }
}
