// Every touch on the app's windows, seen without being taken, and every change typed into a field (the keyboard is a
// window of the system's, and a hardware keyboard never touches the screen): what tells sleep mode the app is in use.
import UIKit
import UIKit.UIGestureRecognizerSubclass

final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        SleepModel.shared.touched()
        state = .failed
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private static var typing: [NSObjectProtocol] = []

    /// Watches every window of the app's scenes not watched yet; an iPad's new window is caught the next time this runs.
    static func install() {
        if typing.isEmpty {
            let center = NotificationCenter.default
            typing = [UITextField.textDidChangeNotification, UITextView.textDidChangeNotification].map {
                center.addObserver(forName: $0, object: nil, queue: .main) { _ in MainActor.assumeIsolated { SleepModel.shared.touched() } }
            }
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchWatcher }) {
                window.addGestureRecognizer(TouchWatcher())
            }
        }
    }
}
