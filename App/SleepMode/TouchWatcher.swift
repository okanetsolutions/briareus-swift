// Every touch on the app's windows, seen without being taken: what tells sleep mode the app is in use.
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

    /// Watches every window of the app's scenes not watched yet; an iPad's new window is caught the next time this runs.
    static func install() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where !(window.gestureRecognizers ?? []).contains(where: { $0 is TouchWatcher }) {
                window.addGestureRecognizer(TouchWatcher())
            }
        }
    }
}
