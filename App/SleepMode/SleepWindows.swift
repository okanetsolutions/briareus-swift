// Where sleep mode shows on a phone or iPad: a window of its own above each of the app's windows in front, so it
// covers sheets and alerts as well as the tabs, fading in and out. The keyboard is put away first, as nothing is typed
// while asleep.
import SwiftUI
import UIKit

@MainActor
enum SleepWindows {
    private static var windows: [UIWindow] = []

    /// Shows or hides the cover; asking again for what already holds does nothing, as every window's shell asks.
    static func set(shown: Bool) {
        shown ? show() : hide()
    }

    private static func show() {
        guard windows.isEmpty else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: SleepScreen(model: SleepModel.shared))
            host.view.backgroundColor = .clear
            window.rootViewController = host
            // Any touch wakes it, a swipe or a long press as well as a tap.
            window.addGestureRecognizer(TouchWatcher())
            window.alpha = 0
            window.isHidden = false
            UIView.animate(withDuration: 0.6) { window.alpha = 1 }
            windows.append(window)
        }
    }

    private static func hide() {
        let closing = windows
        windows = []
        UIView.animate(withDuration: 0.4, animations: { closing.forEach { $0.alpha = 0 } }) { _ in
            closing.forEach { $0.isHidden = true }
        }
    }
}
