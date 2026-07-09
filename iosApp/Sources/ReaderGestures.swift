import SwiftUI
import UIKit

/// A transparent UIKit gesture layer for the reader. SwiftUI can't reliably run a
/// `DragGesture(minimumDistance: 0)` (needed to catch taps) alongside a `MagnificationGesture` —
/// the drag wins arbitration and the pinch never fires, so you can't zoom while reading. UIKit
/// recognizers, told to recognize simultaneously, give pinch + pan + tap + double-tap all at once,
/// mirroring Android's single unified pointer handler.
struct ReaderGestures: UIViewRepresentable {
    /// Tap location (in the view) + the view's size, so the caller can map to left/right/middle zones.
    var onTap: (CGPoint, CGSize) -> Void
    var onDoubleTap: () -> Void
    /// Cumulative pinch scale since the gesture began (1.0 at start), and the end signal to commit.
    var onPinchChanged: (CGFloat) -> Void
    var onPinchEnded: () -> Void
    /// Cumulative pan translation since the gesture began; end reports final translation, px/s
    /// velocity, and the max simultaneous touch count (so a 1-finger flick can be told from a pinch).
    var onPanChanged: (CGSize) -> Void
    var onPanEnded: (_ translation: CGSize, _ velocity: CGSize, _ maxTouches: Int) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.handlePinch(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 2
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleTap(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleDouble(_:)))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double) // single tap fires only once a double-tap is ruled out

        pinch.delegate = c
        pan.delegate = c
        for g in [pinch, pan, tap, double] as [UIGestureRecognizer] { view.addGestureRecognizer(g) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ReaderGestures
        private var maxTouches = 1
        init(_ parent: ReaderGestures) { self.parent = parent }

        // Let pinch and pan run together (zoom while repositioning), like Android.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .changed: parent.onPinchChanged(g.scale)
            case .ended, .cancelled: parent.onPinchEnded()
            default: break
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view else { return }
            let t = g.translation(in: view)
            switch g.state {
            case .began:
                maxTouches = g.numberOfTouches
            case .changed:
                maxTouches = max(maxTouches, g.numberOfTouches)
                parent.onPanChanged(CGSize(width: t.x, height: t.y))
            case .ended, .cancelled:
                let v = g.velocity(in: view)
                parent.onPanEnded(CGSize(width: t.x, height: t.y), CGSize(width: v.x, height: v.y), maxTouches)
                maxTouches = 1
            default: break
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view else { return }
            parent.onTap(g.location(in: view), view.bounds.size)
        }

        @objc func handleDouble(_ g: UITapGestureRecognizer) { parent.onDoubleTap() }
    }
}
