import SwiftUI
import UIKit

/// Finger navigation only in this preview's bounds. Vertical scrolling and Pencil input
/// stay with their existing owners; a held text-selection drag is not a page swipe.
struct PreviewPageSwipe: UIViewRepresentable {
    var enabled: Bool
    var move: (Int) -> Void
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.enabled = enabled; view.move = move; view.attach() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView, UIGestureRecognizerDelegate {
        var enabled = false { didSet { pan.isEnabled = enabled } }
        var move: ((Int) -> Void)?
        private var beganAt: TimeInterval = 0
        private lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pan.maximumNumberOfTouches = 1; pan.cancelsTouchesInView = true; pan.delegate = self
            return pan
        }()
        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if superview == nil { detach() } else { attach() }
        }
        override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { detach() } else { attach() } }
        func detach() { pan.view?.removeGestureRecognizer(pan) }
        func attach() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    if pan.view !== scroll {
                        detach(); scroll.addGestureRecognizer(pan)
                        scroll.panGestureRecognizer.require(toFail: pan)
                    }
                    return
                }
                ancestor = view.superview
            }
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard enabled, bounds.contains(touch.location(in: self)) else { return false }
            var target = touch.view
            while let view = target, view !== pan.view {
                if view is UIControl { return false }
                if let text = view as? UITextView, text.isEditable || text.selectedRange.length > 0 { return false }
                target = view.superview
            }
            beganAt = touch.timestamp; return true
        }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = pan.velocity(in: self)
            return enabled && ProcessInfo.processInfo.systemUptime - beganAt < 0.45 && abs(velocity.x) > abs(velocity.y) * 1.8
        }
        @objc private func panned() {
            guard pan.state == .ended else { return }
            let travel = pan.translation(in: self)
            if abs(travel.x) >= 60, abs(travel.x) > abs(travel.y) * 1.8 { move?(travel.x < 0 ? 1 : -1) }
        }
    }
}
