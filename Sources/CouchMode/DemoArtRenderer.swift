// Owns: drawing demo artwork with CoreGraphics from a DemoArtSpec: a diagonal
// gradient, one motif of soft original shapes (sunrise, waves, hills, rings,
// lattice, beams, orbit, crescent), a vignette and, for tiles, the invented
// title. Everything is computed from the title; there are no image files, no
// photos and nothing that depicts a character or a real work.

import AppKit
import CoreGraphics
import CouchModeCore

@MainActor
enum DemoArtRenderer {
    private static var cache: [DemoArtSpec: NSImage] = [:]
    private static let maxCached = 160

    /// The picture for a demo address; nil for any other address.
    static func image(for url: URL) -> NSImage? {
        DemoArtSpec(url: url).flatMap(image)
    }

    static func image(_ spec: DemoArtSpec) -> NSImage? {
        if let hit = cache[spec] { return hit }
        guard let made = render(spec) else { return nil }
        if cache.count >= maxCached { cache.removeAll() }
        cache[spec] = made
        return made
    }

    private static func color(_ c: DemoColor, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: c.red, green: c.green, blue: c.blue, alpha: alpha)
    }

    private static func render(_ spec: DemoArtSpec) -> NSImage? {
        let (w, h) = spec.pixelSize
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: w, height: h)
        let p = spec.palette
        // Background.
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space, colors: [color(p.dark), color(p.mid), color(p.dark)] as CFArray, locations: [0, 0.55, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        draw(spec.motif, spec, p, in: ctx, size: size)
        // Vignette: darker toward the corners and the bottom, where text sits.
        if let fade = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0.55), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(fade, start: .zero, end: CGPoint(x: 0, y: size.height * 0.55), options: [])
        }
        switch spec.kind {
        case .tile: drawText(spec.title, in: ctx, size: size, fontSize: size.height * 0.105, inset: size.width * 0.06, bottom: true)
        case .square: drawText(String(spec.title.prefix(1)).uppercased(), in: ctx, size: size, fontSize: size.height * 0.5, inset: 0, bottom: false)
        case .hero: break
        }
        guard let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    // MARK: Motifs (spec.unit(i) places things; coordinates are 0...1 of the picture)

    private static func draw(_ motif: DemoMotif, _ spec: DemoArtSpec, _ p: DemoPalette, in ctx: CGContext, size: CGSize) {
        let w = size.width, h = size.height
        func x(_ f: Double) -> CGFloat { w * CGFloat(f) }
        func y(_ f: Double) -> CGFloat { h * CGFloat(f) }
        let u = spec.unit
        switch motif {
        case .sunrise:
            let cx = x(0.3 + 0.4 * u(1)), cy = y(0.28 + 0.1 * u(2)), r = h * (0.22 + 0.08 * u(3))
            for i in (1...4).reversed() {
                ctx.setFillColor(color(p.accent, 0.08 * CGFloat(5 - i)))
                ctx.fillEllipse(in: CGRect(x: cx - r * CGFloat(i) * 0.7, y: cy - r * CGFloat(i) * 0.7, width: r * CGFloat(i) * 1.4, height: r * CGFloat(i) * 1.4))
            }
            ctx.setFillColor(color(p.accent, 0.95))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            hills(ctx, spec, p, size: size, layers: 3, base: 0.0, alpha: 0.9)
        case .hills:
            ctx.setFillColor(color(p.accent, 0.85))
            let r = h * 0.09
            ctx.fillEllipse(in: CGRect(x: x(0.15 + 0.7 * u(1)) - r, y: y(0.62 + 0.15 * u(2)) - r, width: r * 2, height: r * 2))
            hills(ctx, spec, p, size: size, layers: 4, base: 0.05, alpha: 0.85)
        case .waves:
            for i in 0..<5 {
                let level = 0.18 + 0.15 * Double(i)
                let amp = 0.03 + 0.03 * u(10 + i)
                let phase = u(20 + i) * .pi * 2
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: 0))
                var step: CGFloat = 0
                while step <= w {
                    let f = Double(step / w)
                    path.addLine(to: CGPoint(x: step, y: y(level + amp * sin(f * (4 + 2 * u(30 + i)) * .pi + phase))))
                    step += max(2, w / 160)
                }
                path.addLine(to: CGPoint(x: w, y: 0))
                path.closeSubpath()
                ctx.setFillColor(color(i % 2 == 0 ? p.light : p.mid, 0.16 + 0.07 * CGFloat(i)))
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.setFillColor(color(p.accent, 0.9))
            let r = h * 0.1
            ctx.fillEllipse(in: CGRect(x: x(0.65 + 0.2 * u(2)) - r, y: y(0.7) - r, width: r * 2, height: r * 2))
        case .rings:
            let cx = x(0.55 + 0.3 * u(1)), cy = y(0.5 + 0.2 * u(2))
            for i in 1...7 {
                let r = h * 0.1 * CGFloat(i)
                ctx.setStrokeColor(color(i % 3 == 0 ? p.accent : p.light, i % 3 == 0 ? 0.8 : 0.25))
                ctx.setLineWidth(max(2, h * 0.006 * CGFloat(8 - i) / 3))
                ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            }
        case .lattice:
            ctx.setStrokeColor(color(p.light, 0.16))
            ctx.setLineWidth(max(1.5, h * 0.004))
            let gap = h * (0.09 + 0.04 * u(1))
            var k: CGFloat = -h
            while k < w + h {
                ctx.move(to: CGPoint(x: k, y: 0)); ctx.addLine(to: CGPoint(x: k + h, y: h))
                ctx.move(to: CGPoint(x: k + h, y: 0)); ctx.addLine(to: CGPoint(x: k, y: h))
                k += gap
            }
            ctx.strokePath()
            let r = h * 0.11
            ctx.setFillColor(color(p.accent, 0.85))
            ctx.fillEllipse(in: CGRect(x: x(0.6 + 0.25 * u(2)) - r, y: y(0.55 + 0.15 * u(3)) - r, width: r * 2, height: r * 2))
        case .beams:
            let origin = CGPoint(x: x(0.2 + 0.6 * u(1)), y: y(0.9))
            for i in 0..<9 {
                let angle = CGFloat(.pi * (1.15 + 0.7 * Double(i) / 8 + 0.05 * u(10 + i)))
                let spread: CGFloat = 0.05 + CGFloat(u(20 + i)) * 0.05
                let path = CGMutablePath()
                path.move(to: origin)
                path.addLine(to: CGPoint(x: origin.x + cos(angle - spread) * w * 1.5, y: origin.y + sin(angle - spread) * w * 1.5))
                path.addLine(to: CGPoint(x: origin.x + cos(angle + spread) * w * 1.5, y: origin.y + sin(angle + spread) * w * 1.5))
                path.closeSubpath()
                ctx.setFillColor(color(i % 2 == 0 ? p.accent : p.light, 0.14))
                ctx.addPath(path)
                ctx.fillPath()
            }
        case .orbit:
            let center = CGPoint(x: x(0.6 + 0.2 * u(1)), y: y(0.5))
            for i in 1...4 {
                let rx = h * 0.22 * CGFloat(i), ry = rx * CGFloat(0.35 + 0.2 * u(10 + i))
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: CGFloat(u(20) * 0.8 - 0.4))
                ctx.setStrokeColor(color(p.light, 0.3))
                ctx.setLineWidth(max(1.5, h * 0.005))
                ctx.strokeEllipse(in: CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                let t = u(30 + i) * .pi * 2
                let dot = h * 0.025
                ctx.setFillColor(color(p.accent, 0.95))
                ctx.fillEllipse(in: CGRect(x: rx * CGFloat(cos(t)) - dot, y: ry * CGFloat(sin(t)) - dot, width: dot * 2, height: dot * 2))
                ctx.restoreGState()
            }
            let r = h * 0.07
            ctx.setFillColor(color(p.accent, 0.95))
            ctx.fillEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        case .crescent:
            let cx = x(0.5 + 0.3 * u(1)), cy = y(0.6 + 0.12 * u(2)), r = h * 0.26
            // The moon minus a second disc: clip to everything outside the bite, then fill the moon.
            ctx.saveGState()
            ctx.addRect(CGRect(origin: .zero, size: size))
            ctx.addEllipse(in: CGRect(x: cx - r * 0.55, y: cy - r * 0.8, width: r * 2, height: r * 2))
            ctx.clip(using: .evenOdd)
            ctx.setFillColor(color(p.accent, 0.95))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.restoreGState()
            for i in 0..<14 {
                let sr = h * (0.004 + 0.006 * u(40 + i))
                ctx.setFillColor(color(p.light, 0.7))
                ctx.fillEllipse(in: CGRect(x: x(u(50 + i)) - sr, y: y(0.3 + 0.7 * u(60 + i)) - sr, width: sr * 2, height: sr * 2))
            }
        }
    }

    /// Layered ridgelines, far to near, darker toward the front.
    private static func hills(_ ctx: CGContext, _ spec: DemoArtSpec, _ p: DemoPalette, size: CGSize, layers: Int, base: Double, alpha: CGFloat) {
        for layer in 0..<layers {
            let top = base + 0.18 + 0.12 * Double(layers - layer)
            let path = CGMutablePath()
            path.move(to: .zero)
            var step: CGFloat = 0
            while step <= size.width {
                let f = Double(step / size.width)
                let bump = 0.5 * sin(f * (3 + Double(layer)) * .pi + spec.unit(70 + layer) * 6) + 0.5 * sin(f * 7 * .pi + spec.unit(80 + layer) * 6)
                path.addLine(to: CGPoint(x: step, y: size.height * CGFloat(top * 0.6 + 0.04 * bump)))
                step += max(2, size.width / 200)
            }
            path.addLine(to: CGPoint(x: size.width, y: 0))
            path.closeSubpath()
            let shade = 1 - CGFloat(layer) / CGFloat(layers)
            ctx.setFillColor(CGColor(red: p.dark.red * (0.6 + 0.5 * (1 - shade)), green: p.dark.green * (0.6 + 0.5 * (1 - shade)),
                                     blue: p.dark.blue * (0.6 + 0.5 * (1 - shade)), alpha: alpha))
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    private static func drawText(_ text: String, in ctx: CGContext, size: CGSize, fontSize: CGFloat, inset: CGFloat, bottom: Bool) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = bottom ? .left : .center
        paragraph.lineBreakMode = .byWordWrapping
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = fontSize * 0.25
        shadow.shadowOffset = NSSize(width: 0, height: -fontSize * 0.06)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.96),
                                                    .paragraphStyle: paragraph, .shadow: shadow]
        let string = NSAttributedString(string: text, attributes: attrs)
        let width = size.width - inset * 2
        let bounds = string.boundingRect(with: NSSize(width: width, height: size.height), options: [.usesLineFragmentOrigin])
        let rect = bottom ? CGRect(x: inset, y: size.height * 0.5 - ceil(bounds.height) / 2, width: width, height: ceil(bounds.height))
                          : CGRect(x: 0, y: (size.height - bounds.height) / 2, width: size.width, height: ceil(bounds.height))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        string.draw(with: rect, options: [.usesLineFragmentOrigin])
        NSGraphicsContext.current = previous
    }
}
