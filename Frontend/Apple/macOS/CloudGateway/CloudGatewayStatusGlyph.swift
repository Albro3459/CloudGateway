import AppKit

enum CloudGatewayStatusGlyph {
    static func image(isActive: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.scaleBy(x: 18 / 56, y: 18 / 56)
            context.translateBy(x: -3, y: -3)
            NSColor.black.set()

            // Cloud and gateway paths follow the repository's cloudgateway.svg
            let cloud = NSBezierPath()
            cloud.move(to: NSPoint(x: 17.5, y: 47))
            cloud.line(to: NSPoint(x: 46.5, y: 47))
            cloud.curve(to: NSPoint(x: 57.8, y: 37.1), controlPoint1: NSPoint(x: 53, y: 47), controlPoint2: NSPoint(x: 57.8, y: 42.7))
            cloud.curve(to: NSPoint(x: 47.9, y: 27.1), controlPoint1: NSPoint(x: 57.8, y: 31.8), controlPoint2: NSPoint(x: 53.4, y: 27.5))
            cloud.curve(to: NSPoint(x: 31.5, y: 15.7), controlPoint1: NSPoint(x: 45.4, y: 20.1), controlPoint2: NSPoint(x: 39, y: 15.7))
            cloud.curve(to: NSPoint(x: 14.8, y: 27.5), controlPoint1: NSPoint(x: 23.8, y: 15.7), controlPoint2: NSPoint(x: 17.3, y: 20.4))
            cloud.curve(to: NSPoint(x: 5, y: 37.9), controlPoint1: NSPoint(x: 9, y: 28.2), controlPoint2: NSPoint(x: 5, y: 32.6))
            cloud.curve(to: NSPoint(x: 17.5, y: 47), controlPoint1: NSPoint(x: 5, y: 43.4), controlPoint2: NSPoint(x: 9.7, y: 47))
            cloud.close()
            if isActive { cloud.fill() }
            else {
                cloud.lineWidth = 3.2
                cloud.stroke()
            }

            if isActive { context.setBlendMode(.destinationOut) }
            let gateway = NSBezierPath()
            gateway.move(to: NSPoint(x: 25.2, y: 47))
            gateway.line(to: NSPoint(x: 25.2, y: 36.3))
            gateway.curve(to: NSPoint(x: 32, y: 28.5), controlPoint1: NSPoint(x: 25.2, y: 31.7), controlPoint2: NSPoint(x: 28, y: 28.5))
            gateway.curve(to: NSPoint(x: 38.8, y: 36.3), controlPoint1: NSPoint(x: 36, y: 28.5), controlPoint2: NSPoint(x: 38.8, y: 31.7))
            gateway.line(to: NSPoint(x: 38.8, y: 47))
            gateway.line(to: NSPoint(x: 34.2, y: 47))
            gateway.line(to: NSPoint(x: 34.2, y: 36.5))
            gateway.curve(to: NSPoint(x: 32, y: 33), controlPoint1: NSPoint(x: 34.2, y: 34.3), controlPoint2: NSPoint(x: 33.4, y: 33))
            gateway.curve(to: NSPoint(x: 29.8, y: 36.5), controlPoint1: NSPoint(x: 30.6, y: 33), controlPoint2: NSPoint(x: 29.8, y: 34.3))
            gateway.line(to: NSPoint(x: 29.8, y: 47))
            gateway.close()
            gateway.fill()
            let links = NSBezierPath()
            links.move(to: NSPoint(x: 17.5, y: 37.3))
            links.line(to: NSPoint(x: 25.2, y: 37.3))
            links.move(to: NSPoint(x: 38.8, y: 37.3))
            links.line(to: NSPoint(x: 46.5, y: 37.3))
            links.lineWidth = 2.4
            links.lineCapStyle = .round
            links.stroke()
            for x in [17.5, 46.5] {
                NSBezierPath(ovalIn: NSRect(x: x - 2.7, y: 34.6, width: 5.4, height: 5.4)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = isActive ? "CloudGateway, VPN active" : "CloudGateway, VPN off"
        return image
    }
}
