// Every key, click, scroll and mouse move the app receives, seen first: what tells sleep mode the app is in use. The
// input that wakes it, and the rest of that gesture for a moment after (a trackpad swipe's scrolls, a click's release,
// a drag), goes no further, so waking the window does not also act on the screen under it.
import AppKit

@MainActor
enum InputMonitor {
    private static var installed = false
    /// When the last input woke the app.
    private static var woke = Date.distantPast

    static func install() {
        guard !installed else { return }
        installed = true
        let watched: NSEvent.EventTypeMask = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                                              .rightMouseUp, .otherMouseDown, .otherMouseUp, .scrollWheel, .mouseMoved]
        NSEvent.addLocalMonitorForEvents(matching: watched) { event in
            MainActor.assumeIsolated {
                let asleep = SleepModel.shared.asleep
                SleepModel.shared.touched()
                if asleep { woke = Date() }
                let wakingGesture = Date().timeIntervalSince(woke) < 0.6
                return wakingGesture && event.type != .mouseMoved ? nil : event
            }
        }
    }
}
