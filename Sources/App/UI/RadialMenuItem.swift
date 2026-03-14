import Cocoa

/// Represents a single item in the radial menu
struct RadialMenuItem {
    let title: String
    let iconName: String  // SF Symbol name
    let action: RadialMenuAction
    
    /// Custom icon image (for plugins with custom icon.png)
    var customIcon: NSImage?
    
    /// Indicates whether the item matches the current text/app context.
    /// If false, it remains geometrically placed but becomes grayed-out and unclickable.
    var isExecutable: Bool = true
}

/// What happens when a radial menu item is tapped
enum RadialMenuAction {
    case builtIn(BuiltInAction)
    case plugin(Plugin)
    case pageNext
    case pagePrev
}
