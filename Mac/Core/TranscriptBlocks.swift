// Builds the transcript's folded rows incrementally, keeping completed history unchanged as live lines arrive.
import Foundation

struct TranscriptBlockBuilder: Sendable {
    private(set) var blocks: [TranscriptBlock] = []
    private var prepDone = false
    private enum Run: Equatable, Sendable { case preparation, tools }
    private var run: Run?

    /// Appends an ordered suffix; even an invisible event ends a contiguous preparation or tool run.
    @discardableResult
    mutating func append(_ events: ArraySlice<Event>) -> Bool {
        var changed = false
        var i = events.startIndex
        while i < events.endIndex {
            let e = events[i]
            if e.kind == "user" || e.kind == "result" { prepDone = false }
            if !prepDone && isPrepLine(e) && !prepClosed(e) {
                var j = i + 1
                while j < events.endIndex && isPrepLine(events[j]) && !prepClosed(events[j]) { j += 1 }
                var group = Array(events[i..<j])
                if run == .preparation, case .preparation(let previous)? = blocks.last {
                    group = previous + group
                    blocks.removeLast()
                }
                blocks.append(.preparation(group))
                run = .preparation
                changed = true; i = j
                continue
            }
            if isPrepLine(e) && prepClosed(e) { prepDone = true }
            if isToolEvent(e) {
                var j = i + 1
                while j < events.endIndex && isToolEvent(events[j]) { j += 1 }
                var group = Array(events[i..<j])
                if run == .tools, case .tools(let previous)? = blocks.last {
                    group = previous + group
                    blocks.removeLast()
                }
                blocks.append(.tools(group))
                run = .tools
                changed = true; i = j
                continue
            }
            run = nil
            if e.isVisible { blocks.append(.event(e)); changed = true }
            i += 1
        }
        return changed
    }
}
