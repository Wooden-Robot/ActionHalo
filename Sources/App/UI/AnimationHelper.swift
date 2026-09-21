import Cocoa
import QuartzCore

/// Animation helpers for the radial menu
@MainActor
struct AnimationHelper {
    
    /// Ease-out animation for menu disappearing with rotation
    static func hideAnimation(
        for view: NSView,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
            
            var transform = CATransform3DIdentity
            transform = CATransform3DScale(transform, 0.4, 0.4, 1)
            transform = CATransform3DRotate(transform, .pi / 4, 0, 0, 1) // spin away
            view.layer?.transform = transform
        }, completionHandler: {
            Task { @MainActor in
                completion?()
            }
        })
    }
    
    /// Hover scale animation for menu sectors
    static func hoverAnimation(for layer: CALayer, highlighted: Bool) {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.toValue = highlighted ? 1.12 : 1.0
        animation.duration = 0.15
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "hoverScale")
    }
}
