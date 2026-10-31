import Foundation
import CoreGraphics

nonisolated enum ReplyBubblePlacement {
    static func origin(anchor: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        var x = anchor.x + 22
        var y = anchor.y - 6 - size.height
        if x + size.width > visibleFrame.maxX { x = anchor.x - 22 - size.width }
        if y < visibleFrame.minY { y = anchor.y + 6 }
        x = max(visibleFrame.minX, min(x, visibleFrame.maxX - size.width))
        y = max(visibleFrame.minY, min(y, visibleFrame.maxY - size.height))
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// The × button's clickable area in screen coordinates (top-right corner, with some slack).
    /// Everywhere else the bubble lets clicks through to the app underneath.
    static func closeButtonRect(panelFrame: CGRect) -> CGRect {
        CGRect(x: panelFrame.maxX - 34, y: panelFrame.maxY - 32, width: 34, height: 32)
    }
}
