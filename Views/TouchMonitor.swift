import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// [TRILLING 1] Vangt ELKE aanraking van het scherm op (knoppen, lijsten, sheets…) zonder ze te
/// blokkeren, en meldt begin/einde. Zo weet de camera-pipeline dat het statief kan trillen.
final class TouchObserverRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var onBegan: (() -> Void)?
    var onEnded: (() -> Void)?
    private var activeTouches = 0

    /// Geen eigen init (dat vraagt bij sommige SDK's een `init(coder:)`): instellen na het aanmaken.
    static func make() -> TouchObserverRecognizer {
        let r = TouchObserverRecognizer(target: nil, action: nil)
        r.cancelsTouchesInView = false   // knoppen blijven gewoon werken
        r.delaysTouchesBegan = false
        r.delaysTouchesEnded = false
        r.delegate = r
        return r
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if activeTouches == 0 { onBegan?() }
        activeTouches += touches.count
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { release(touches.count) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { release(touches.count) }

    private func release(_ n: Int) {
        activeTouches = max(0, activeTouches - n)
        if activeTouches == 0 {
            onEnded?()
            state = .failed              // nooit "herkend": stoort geen andere gebaren
        }
    }

    override func reset() {
        forceEnd()
    }

    /// Meld "losgelaten" als er nog een aanraking openstond (signaal onderweg verloren).
    func forceEnd() {
        if activeTouches > 0 { onEnded?() }
        activeTouches = 0
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Hangt de recognizer aan het venster (dus ook boven sheets en menu's in hetzelfde venster).
struct TouchMonitor: UIViewRepresentable {
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeUIView(context: Context) -> HostView {
        let v = HostView()
        v.isUserInteractionEnabled = false
        v.recognizer.onBegan = onBegan
        v.recognizer.onEnded = onEnded
        return v
    }

    func updateUIView(_ uiView: HostView, context: Context) {
        uiView.recognizer.onBegan = onBegan
        uiView.recognizer.onEnded = onEnded
    }

    static func dismantleUIView(_ uiView: HostView, coordinator: ()) {
        uiView.recognizer.view?.removeGestureRecognizer(uiView.recognizer)
    }

    final class HostView: UIView {
        let recognizer = TouchObserverRecognizer.make()
        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.forceEnd()                    // venster wisselt midden in een aanraking → afsluiten
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }
}

extension View {
    /// Meldt elke aanraking van het scherm aan de camera (trillings-lockout).
    func reportsTouches(to camera: CameraSystem) -> some View {
        background(
            TouchMonitor(onBegan: { camera.pipeline.touchBegan() },
                         onEnded: { camera.pipeline.touchEnded() })
                .frame(width: 0, height: 0)
        )
    }
}
