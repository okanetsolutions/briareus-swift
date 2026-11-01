// What the conversation screen, its panel and the composers word and fold, as screen_conversation.c, screen_panel.c and
// attach_list.c do.
import XCTest
@testable import BriareusMacCore

final class ConversationLogicTests: XCTestCase {
    private func session(_ j: JSON) -> Session { Session(j)! }
    private func event(_ j: JSON) -> Event { Event(j)! }

    @MainActor
    func testAttachmentQueueWaitsForUploadBeforeReadingTheNextFile() async {
        let queue = AttachmentUploadQueue()
        let uploading = expectation(description: "First file is uploading")
        var finishUpload: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let first = queue.enqueue {
            events.append("read first")
            await withCheckedContinuation { finishUpload = $0; uploading.fulfill() }
            events.append("uploaded first")
        }
        let second = queue.enqueue {
            events.append("read second")
            events.append("uploaded second")
        }
        await fulfillment(of: [uploading], timeout: 5)
        XCTAssertEqual(events, ["read first"])
        finishUpload?.resume()
        await first.value
        await second.value
        XCTAssertEqual(events, ["read first", "uploaded first", "read second", "uploaded second"])
    }

    @MainActor
    func testAttachmentQueueSkipsCancelledFilesWithoutOvertakingAnActiveRead() async {
        let queue = AttachmentUploadQueue()
        let reading = expectation(description: "First file is being read")
        var finishRead: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let first = queue.enqueue {
            events.append("read first")
            await withCheckedContinuation { finishRead = $0; reading.fulfill() }
            events.append("finished first")
        }
        let removed = queue.enqueue { XCTFail("A removed file must never be read") }
        let last = queue.enqueue {
            XCTAssertFalse(Task.isCancelled)
            events.append("read last")
        }
        await fulfillment(of: [reading], timeout: 5)
        removed.cancel()
        XCTAssertEqual(events, ["read first"])
        finishRead?.resume()
        await last.value
        XCTAssertEqual(events, ["read first", "finished first", "read last"])
    }

    @MainActor
    func testCancellingASuspendedReadLetsTheNextFileStartBeforeItReturns() async {
        let queue = AttachmentUploadQueue()
        let reading = expectation(description: "Read is suspended in an API that ignores cancellation")
        let nextFile = expectation(description: "Next file starts without waiting for the removed read")
        var finishRead: CheckedContinuation<Void, Never>?
        var events: [String] = []
        let first = queue.enqueue {
            await withCheckedContinuation { finishRead = $0; reading.fulfill() }
            XCTAssertTrue(Task.isCancelled)
            events.append("removed read returned")
        }
        let second = queue.enqueue {
            events.append("read next")
            nextFile.fulfill()
        }
        await fulfillment(of: [reading], timeout: 5)
        first.cancel()
        await fulfillment(of: [nextFile], timeout: 5)
        XCTAssertEqual(events, ["read next"])
        finishRead?.resume()
        await first.value
        await second.value
        XCTAssertEqual(events, ["read next", "removed read returned"])
    }

    // MARK: Header

    func testStatusLineListsRuntimeStateAndSession() {
        let s = session(["id": "abc", "status": "running", "provider": "Claude", "model": "opus", "effort": "high"])
        XCTAssertEqual(conversationStatusLine(s), "Claude \u{00B7} opus \u{00B7} high \u{00B7} running \u{00B7} session abc")
    }
    func testIdleSessionAwaitingAnAnswerReadsWaiting() {
        let s = session(["id": "a", "status": "idle", "awaitingAnswer": true])
        XCTAssertEqual(conversationStatusLine(s), "waiting \u{00B7} session a")
    }
    func testStatusLineCarriesBranchTokensCostAndPull() {
        let s = session(["id": "a", "status": "idle", "reviewLoop": ["rounds": 2], "branch": "feat/x", "inputTokens": 1500, "outputTokens": 500,
                         "costUsd": 1.5, "prStatus": ["number": 70, "state": "open", "draft": true, "checks": ["failed": 0, "pending": 3, "passed": 2]]])
        XCTAssertEqual(conversationStatusLine(s),
                       "idle \u{00B7} feat/x \u{00B7} 2.0k tok \u{00B7} $1.50 \u{00B7} session a \u{00B7} \u{26AA} PR #70 draft \u{00B7} \u{2026}3")
    }
    func testStatusLineSaysWhetherTheSharedBrowserIsUp() {
        XCTAssertEqual(conversationStatusLine(session(["id": "a", "status": "idle", "branch": "b", "browser": ["running": true]])),
                       "idle \u{00B7} b \u{00B7} \u{1F310} browser \u{00B7} session a")
        XCTAssertEqual(conversationStatusLine(session(["id": "a", "status": "idle", "browser": ["running": false]])),
                       "idle \u{00B7} \u{1F310} browser starts next turn \u{00B7} session a")
        XCTAssertEqual(conversationStatusLine(session(["id": "a", "status": "idle", "browser": nil])), "idle \u{00B7} session a")
    }
    func testAReviewLoopRecordIsNoLongerShownAndMergedPull() {
        let s = session(["id": "a", "status": "idle", "reviewLoop": [:], "prStatus": ["number": 3, "state": "merged", "checks": ["passed": 4]]])
        XCTAssertEqual(conversationStatusLine(s), "idle \u{00B7} session a \u{00B7} \u{1F7E3} PR #3 merged \u{00B7} \u{2713}4")
    }

    // MARK: Transcript

    func testTurnFooter() {
        let e = event(["seq": 1, "kind": "result", "costUsd": 2.95651, "durationMs": 455_900, "numTurns": 57, "inputTokens": 5_600_000,
                       "outputTokens": 36_400, "tokens": 151_600])
        XCTAssertEqual(turnFooterText(e), "\u{2014} $2.9565 \u{00B7} 455s \u{00B7} 57 turns \u{00B7} 5.6M in / 36.4k out \u{00B7} 151.6k context")
        XCTAssertEqual(turnFooterText(event(["seq": 2, "kind": "result"])), "\u{2014} turn done")
    }
    func testToolTitlesAndFirstLine() {
        XCTAssertEqual(toolTitle(event(["seq": 1, "kind": "tool", "name": "Bash"])), "Bash")
        XCTAssertEqual(toolTitle(event(["seq": 1, "kind": "cmd"])), "Command")
        XCTAssertEqual(toolTitle(event(["seq": 1, "kind": "tool_error"])), "Tool error")
        XCTAssertEqual(toolTitle(event(["seq": 1, "kind": "tool", "name": ""])), "Tool")
        XCTAssertEqual(firstLine("  ls -la \n second"), "ls -la")
        XCTAssertEqual(firstLine(nil), "")
    }
    func testBlocksFoldPreparationAndToolRuns() {
        let events = [
            event(["seq": 1, "kind": "user", "text": "hi"]),
            event(["seq": 2, "kind": "info", "text": "Cloning"]),
            event(["seq": 3, "kind": "cmd", "text": "npm ci"]),
            event(["seq": 4, "kind": "info", "text": "Session started"]),
            event(["seq": 5, "kind": "info", "text": "later info"]),
            event(["seq": 6, "kind": "tool", "name": "Read", "summary": "a.ts"]),
            event(["seq": 7, "kind": "tool", "name": "Bash", "summary": "ls"]),
            event(["seq": 8, "kind": "status", "text": "running"]),
            event(["seq": 9, "kind": "text", "text": "done"]),
        ]
        let blocks = transcriptBlocks(events)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks[0], .event(events[0]))
        XCTAssertEqual(blocks[1].summary, "Preparing workspace\u{2026} (2 steps)")
        XCTAssertEqual(blocks[1].seq, 2)
        XCTAssertEqual(blocks[2], .event(events[3]))
        // Once the session started, info lines belong to the conversation.
        XCTAssertEqual(blocks[3], .event(events[4]))
        XCTAssertEqual(blocks[4].summary, "2 steps \u{00B7} Bash")
        XCTAssertEqual(blocks[5], .event(events[8]))
    }
    func testRetimeOnlyWhenEveryEventLacksATime() {
        XCTAssertFalse(transcriptNeedsRetime([]))
        XCTAssertTrue(transcriptNeedsRetime([event(["seq": 1, "kind": "text", "text": "a"])]))
        XCTAssertFalse(transcriptNeedsRetime([event(["seq": 1, "kind": "text", "text": "a", "t": "2026-01-01T00:00:00Z"])]))
    }
    func testDictationAppendsWithAGap() {
        XCTAssertEqual(appendDictation("", "hello"), "hello")
        XCTAssertEqual(appendDictation("fix", "it"), "fix it")
        XCTAssertEqual(appendDictation("fix ", "it"), "fix it")
        XCTAssertEqual(appendDictation("fix\n", "it"), "fix\nit")
        XCTAssertEqual(appendDictation("fix", ""), "fix")
    }

    // MARK: Composer

    func testConversationChips() {
        let s = session(["id": "a", "status": "idle", "repo": "okanet/briareus", "local": true, "branch": "main", "model": "opus"])
        XCTAssertEqual(conversationChipText(s, .workspace), "\u{2302} Local")
        XCTAssertEqual(conversationChipText(s, .project), "briareus")
        XCTAssertEqual(conversationChipText(s, .branch), "main")
        XCTAssertEqual(conversationChipText(s, .provider), "")
        XCTAssertEqual(conversationChipText(s, .model), "opus")
        let o = session(["id": "a", "status": "idle", "orchestrator": true])
        XCTAssertEqual(conversationChipText(o, .workspace), "\u{1F9ED} Orchestrator")
    }
    func testComposerNote() {
        XCTAssertEqual(conversationComposerNote(active: true, liveInput: true, uploading: false, files: 0, empty: true), "Sent into the running turn")
        XCTAssertEqual(conversationComposerNote(active: true, liveInput: false, uploading: true, files: 0, empty: true), "Queued for the next turn")
        XCTAssertEqual(conversationComposerNote(active: false, liveInput: false, uploading: true, files: 1, empty: true), "Uploading\u{2026}")
        XCTAssertEqual(conversationComposerNote(active: false, liveInput: false, uploading: false, files: 1, empty: true), "Add a few words to send the files")
        XCTAssertEqual(conversationComposerNote(active: false, liveInput: false, uploading: false, files: 1, empty: false), "")
    }
    func testAttachmentChip() {
        XCTAssertEqual(attachmentChipLabel(name: "a.png", size: 1500, uploaded: true), "\u{1F4CE} a.png \u{00B7} 2 KB")
        XCTAssertEqual(attachmentChipLabel(name: "b.zip", size: 3 * 1024 * 1024, uploaded: false), "\u{2026} b.zip \u{00B7} 3.0 MB")
        XCTAssertEqual(attachmentRefusal("notes", "is empty"), "notes is empty.")
    }

    // MARK: Panel

    func testPanelLabels() {
        XCTAssertEqual(panelStateText(["state": "open", "draft": true]), "draft")
        XCTAssertEqual(panelStateText(["state": "merged", "draft": true]), "merged")
        XCTAssertEqual(panelStateText([:]), "open")
    }
    func testContextFigures() {
        XCTAssertEqual(contextHeadline(used: 12_000, window: 200_000), "12.0k / 200.0k (6%)")
        XCTAssertEqual(contextHeadline(used: 12_000, window: 0), "12.0k tokens")
        XCTAssertNil(sessionContextSize(["contextWindow": 10]))
        let size = sessionContextSize(["contextUsage": ["tokens": 5, "window": 10]])
        XCTAssertEqual(size?.used, 5); XCTAssertEqual(size?.window, 10)
        XCTAssertEqual(sessionContextSize(["contextTokens": 7])?.window, 0)
        XCTAssertTrue(sessionUsageRowsPresent(["usage": ["costUsd": 1]]))
        XCTAssertFalse(sessionUsageRowsPresent(["usage": ["sessions": 1], "costUsd": 1]))
        XCTAssertTrue(sessionUsageRowsPresent(["costUsd": 1]))
    }

    // MARK: Working line

    func testSessionReadsItsBackgroundTasks() {
        let s = session(["id": "a", "status": "running", "backgroundTasks": [["name": "Bash", "summary": "sleep 120"], ["name": "Monitor"], ["summary": "no name"]]])
        XCTAssertEqual(s.backgroundTasks, [BackgroundTask(name: "Bash", summary: "sleep 120"), BackgroundTask(name: "Monitor")])
        XCTAssertEqual(session(["id": "a", "status": "running"]).backgroundTasks, [])
    }
    func testTranscriptIsAnsweredWhenItEndsOnTheTurnsResult() {
        let said = event(["seq": 1, "kind": "text", "text": "Started the watcher."])
        let result = event(["seq": 2, "kind": "result", "text": "done"])
        let tool = event(["seq": 3, "kind": "tool", "name": "Bash", "summary": "ls"])
        XCTAssertTrue(transcriptAnswered(transcriptBlocks([said, result])))
        XCTAssertFalse(transcriptAnswered(transcriptBlocks([said])))
        XCTAssertFalse(transcriptAnswered(transcriptBlocks([said, result, tool])))
        XCTAssertFalse(transcriptAnswered([]))
        // The server's own lines after the answer leave it answered; a message handed into the turn does not.
        let info = event(["seq": 4, "kind": "info", "text": "PR #7 is open"])
        let stderr = event(["seq": 5, "kind": "stderr", "text": "warning"])
        let user = event(["seq": 6, "kind": "user", "text": "and then?"])
        XCTAssertTrue(transcriptAnswered(transcriptBlocks([said, result, info, stderr])))
        XCTAssertFalse(transcriptAnswered(transcriptBlocks([said, result, info, user])))
    }
    func testWorkingLineWaitsOnBackgroundWorkOnlyWhileRunning() {
        let bash = BackgroundTask(name: "Bash", summary: "sleep 120")
        let thinking = workingLineText(status: "running", background: [], answered: true, tick: 0)
        let waiting = workingLineText(status: "running", background: [bash], answered: true, tick: 0)
        XCTAssertNotEqual(waiting, thinking)
        XCTAssertTrue(waiting.contains("Bash") && waiting.contains("sleep 120"))
        // Several tasks are counted rather than listed.
        let several = workingLineText(status: "running", background: [bash, BackgroundTask(name: "general-purpose")], answered: true, tick: 0)
        XCTAssertTrue(several.contains("2") && !several.contains("sleep 120"))
        // Queued and starting sessions say so whatever the record carries.
        for status in ["queued", "preparing", "starting"] {
            XCTAssertEqual(workingLineText(status: status, background: [bash], answered: true, tick: 0), workingLineText(status: status, background: [], answered: true, tick: 0))
            XCTAssertNotEqual(workingLineText(status: status, background: [], answered: true, tick: 0), thinking)
        }
        // An agent still speaking after it backgrounded work is thinking, not waiting.
        XCTAssertEqual(workingLineText(status: "running", background: [bash], answered: false, tick: 0), thinking)
        // With nothing to wait on, the verb spins with the tick.
        XCTAssertNotEqual(workingLineText(status: "running", background: [], answered: true, tick: 25), thinking)
        XCTAssertEqual(workingLineText(status: "running", background: [bash], answered: true, tick: 25), waiting)
    }
}
