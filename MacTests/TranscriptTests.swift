// Live transcript updates preserve ordering and folded runs without rebuilding completed history.
import XCTest
@testable import BriareusMacCore

final class TranscriptTests: XCTestCase {
    private func line(_ seq: Int, _ kind: String, _ text: String? = nil) -> JSON {
        var value: JSON = ["seq": JSON(seq), "kind": .string(kind)]
        if let text { value["text"] = .string(text) }
        return value
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
            transcript.append(.array(Array(input[..<split])))
            transcript.append(.array(Array(input[split...])))
            XCTAssertEqual(transcript.blocks, expected, "Split at \(split)")
            XCTAssertEqual(transcript.cursor, 20)
        }
        var streamed = Transcript()
        for (i, value) in input.enumerated() {
            streamed.append(.array([value]))
            XCTAssertEqual(streamed.blocks, transcriptBlocks(Array(events[...i])), "Line \(i)")
        }
    }

    func testInvisibleLinesAdvanceTheCursorWithoutChangingRows() {
        var transcript = Transcript()
        XCTAssertTrue(transcript.append(.array([line(1, "tool")])))
        let first = transcript.blocks
        XCTAssertFalse(transcript.append(.array([line(2, "status", "working"), line(3, "future")])))
        XCTAssertEqual(transcript.blocks, first)
        XCTAssertEqual(transcript.cursor, 3)
        XCTAssertEqual(transcript.events.count, 3)
        XCTAssertTrue(transcript.append(.array([line(4, "tool")])))
        XCTAssertEqual(transcript.blocks.map(\.seq), [1, 4], "Hidden events must still separate contiguous tool runs")
    }

    func testReplayAndMalformedEventsAddNoRowsAndKeepTheFirstCopy() {
        var transcript = Transcript()
        let original = line(4, "text", "Original")
        transcript.append(.array([original]))
        let saved = transcript
        XCTAssertFalse(transcript.append(.array([line(4, "text", "Replay"), ["seq": 8], ["kind": "tool"], .null])))
        XCTAssertFalse(transcript.append(["events": [line(9, "tool")]]))
        XCTAssertEqual(transcript, saved)
        XCTAssertEqual(transcript.blocks, [.event(Event(original)!)])
    }

    func testLateInsertionRebuildsRunsAndPreservesSnapshots() {
        var transcript = Transcript()
        transcript.append(.array([line(2, "tool"), line(6, "tool")]))
        let before = transcript
        XCTAssertTrue(transcript.append(.array([line(4, "status")])))
        XCTAssertEqual(transcript.blocks.map(\.seq), [2, 6])
        XCTAssertEqual(before.blocks.count, 1)
        XCTAssertEqual(before.events.map(\.seq), [2, 6])
        XCTAssertEqual(transcript.cursor, 6)
        XCTAssertTrue(transcript.append(.array([line(1, "info", "Cloning"), line(3, "info", "Session started") ])))
        XCTAssertEqual(transcript.events.map(\.seq), [1, 2, 3, 4, 6])
        XCTAssertEqual(transcript.blocks, transcriptBlocks(transcript.events))
    }

    func testUnorderedBatchesAndRestoredTranscriptsHaveTheSameRows() {
        var transcript = Transcript()
        let input = [line(8, "result"), line(2, "tool"), line(6, "text", "Answer"), line(2, "text", "Duplicate")]
        transcript.append(.array(input))
        XCTAssertEqual(transcript.events.map(\.seq), [2, 6, 8])
        XCTAssertEqual(transcript.events[0].kind, "tool")
        var restored = Transcript()
        restored.append(transcript.json)
        XCTAssertEqual(restored, transcript)
        XCTAssertEqual(restored.blocks, transcript.blocks)
        // Resetting after Clear or a full refresh must also reset deduplication and folding state.
        restored = Transcript()
        restored.append(.array([line(2, "info", "New setup")]))
        XCTAssertEqual(restored.blocks, [.preparation([Event(line(2, "info", "New setup"))!])])
    }

    func testLongLiveConversationKeepsHistoryAndGroupsOnlyAdjacentSteps() {
        var transcript = Transcript()
        for seq in 1...4_000 {
            transcript.append(.array([line(seq, seq.isMultiple(of: 3) ? "tool" : "text", "Line \(seq)")]))
        }
        XCTAssertEqual(transcript.cursor, 4_000)
        XCTAssertEqual(transcript.events.count, 4_000)
        XCTAssertEqual(transcript.blocks.count, 4_000)
        XCTAssertEqual(transcript.blocks, transcriptBlocks(transcript.events))
    }
}
