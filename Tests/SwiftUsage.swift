import UIKit
import SCGLayer

// Compile against the package's public module to check the Swift-facing API.
@MainActor
func attachDrawingLayer(to view: UIView) throws -> SCGLayer {
    let layer = SCGLayer()
    layer.frame = view.bounds
    layer.contentsScale = view.contentScaleFactor
    layer.drawingBlock = { context, bounds in
        context.setFillColor(UIColor.systemCyan.cgColor)
        context.fillEllipse(in: bounds.insetBy(dx: 24, dy: 24))
    }
    view.layer.addSublayer(layer)
    try layer.render()
    return layer
}
