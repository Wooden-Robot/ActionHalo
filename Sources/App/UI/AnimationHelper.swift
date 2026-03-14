import Cocoa
import QuartzCore

/// Animation helpers for the radial menu
struct AnimationHelper {
    
    /// Spring animation for menu appearing with a sci-fi spin
    static func showAnimation(for view: NSView, completion: (() -> Void)? = nil) {
        view.alphaValue = 0
        
        // Ensure layer is ready
        view.wantsLayer = true
        
        let startScale: CGFloat = 0.05
        let startAngle: CGFloat = -.pi / 1.5 // Start rotated back 120 degrees
        
        var transform = CATransform3DIdentity
        transform = CATransform3DScale(transform, startScale, startScale, 1)
        transform = CATransform3DRotate(transform, startAngle, 0, 0, 1)
        view.layer?.transform = transform
        
        // Scale Spring
        let scaleAnim = CASpringAnimation(keyPath: "transform.scale")
        scaleAnim.damping = 16
        scaleAnim.stiffness = 250
        scaleAnim.mass = 0.5
        scaleAnim.initialVelocity = 0.0
        scaleAnim.fromValue = startScale
        scaleAnim.toValue = 1.0
        
        // Rotation Spring (ease-out type spin to snap into place)
        let rotAnim = CASpringAnimation(keyPath: "transform.rotation.z")
        rotAnim.damping = 20
        rotAnim.stiffness = 200
        rotAnim.mass = 0.6
        rotAnim.fromValue = startAngle
        rotAnim.toValue = 0.0
        
        let group = CAAnimationGroup()
        group.animations = [scaleAnim, rotAnim]
        group.duration = scaleAnim.settlingDuration
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
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1.0
        }, completionHandler: nil)
        
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
