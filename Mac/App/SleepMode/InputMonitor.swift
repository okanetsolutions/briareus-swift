// Every key, click and scroll the app receives, seen first: what tells sleep mode the app is in use. While it sleeps,
// the input that wakes it goes no further, so the key or click that wakes the window does not also act on the screen
// under it.
import AppKit

@MainActor
enum InputMonitor {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let woken: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        NSEvent.addLocalMonitorForEvents(matching: woken.union(.mouseMoved)) { event in
            MainActor.assumeIsolated {
                let asleep = SleepModel.shared.asleep
                SleepModel.shared.touched()
                return asleep && event.type != .mouseMoved ? nil : event
            }
        }
    }
}
