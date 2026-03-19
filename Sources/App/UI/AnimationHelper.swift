import Cocoa
import QuartzCore

/// Animation helpers for the radial menu
struct AnimationHelper {
    
    /// Spring animation for menu appearing with a sci-fi spin
    static func showAnimation(for view: NSView, completion: (() -> Void)? = nil) {
        view.alphaValue = 0
        
        // Ensure layer is ready
        view.wantsLayer = true
        
        let startScale: CGFloat = 0.03
        let startAngle: CGFloat = -.pi * 0.92
        
        var transform = CATransform3DIdentity
        transform = CATransform3DScale(transform, startScale, startScale, 1)
        transform = CATransform3DRotate(transform, startAngle, 0, 0, 1)
        view.layer?.transform = transform
        
        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.values = [startScale, 1.08, 0.985, 1.0]
        scaleAnim.keyTimes = [0.0, 0.58, 0.82, 1.0]
        scaleAnim.duration = 0.26
        scaleAnim.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut)
        ]

        let rotAnim = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotAnim.values = [startAngle, 0.12, -0.035, 0.0]
        rotAnim.keyTimes = [0.0, 0.64, 0.84, 1.0]
        rotAnim.duration = 0.26
        rotAnim.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.2, 0.95, 0.28, 1.0),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut)
        ]

        let opacityAnim = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnim.values = [0.0, 0.72, 1.0]
        opacityAnim.keyTimes = [0.0, 0.55, 1.0]
        opacityAnim.duration = 0.16
        opacityAnim.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut)
        ]

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, rotAnim, opacityAnim]
        group.duration = 0.26
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        
        view.layer?.add(group, forKey: "sciFiReveal")
        
        // Ensure the final transform snaps to identity when animation completes
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            view.layer?.transform = CATransform3DIdentity
            view.layer?.removeAnimation(forKey: "sciFiReveal")
            completion?()
        }
        
        view.alphaValue = 1.0
        
        CATransaction.commit()
    }
    
    /// Ease-out animation for menu disappearing with rotation
    static func hideAnimation(for view: NSView, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
            
            var transform = CATransform3DIdentity
            transform = CATransform3DScale(transform, 0.4, 0.4, 1)
            transform = CATransform3DRotate(transform, .pi / 4, 0, 0, 1) // spin away
            view.layer?.transform = transform
        }, completionHandler: completion)
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
