// A session's terminal in SwiftUI (TerminalHost): the session's own TerminalCanvas, moved into whichever screen shows it,
// the project's SSH sessions tab or the SSH servers page.
import AppKit
import SwiftUI

/// The terminal of a session, in SwiftUI: the session's own view, moved into whichever screen shows it.
struct TerminalHost: NSViewRepresentable {
    var session: TerminalSession
    /// The tabs over it hold every project's sessions (SSHSessionsPane.everyProject).
    var everyProject = false

    final class Container: NSView {
        weak var attached: TerminalCanvas?
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> Container {
        let c = Container()
        attach(session, to: c)
        return c
    }
    func updateNSView(_ c: Container, context: Context) {
        if c.attached !== session.canvas { attach(session, to: c) }
        session.canvas.stepsEveryProject = everyProject
    }
    static func dismantleNSView(_ c: Container, coordinator: ()) {
        if let canvas = c.attached, canvas.superview === c { canvas.removeFromSuperview() }
    }

    private func attach(_ s: TerminalSession, to c: Container) {
        if let old = c.attached, old.superview === c { old.removeFromSuperview() }
        let canvas = s.canvas
        canvas.stepsEveryProject = everyProject
        canvas.removeFromSuperview()
        canvas.frame = c.bounds
        canvas.autoresizingMask = [.width, .height]
        c.addSubview(canvas)
        c.attached = canvas
        // A session just opened or switched to takes the keyboard.
        DispatchQueue.main.async { [weak canvas] in
            guard let canvas, let window = canvas.window else { return }
            window.makeFirstResponder(canvas)
        }
    }
}
