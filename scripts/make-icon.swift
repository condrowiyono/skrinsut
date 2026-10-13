// Generates the Skrinsut app icon: Resources/AppIcon.icns (+ Resources/AppIcon.png preview).
// Usage: swift scripts/make-icon.swift
//
// Design: a viewfinder (four corner brackets) framing a warm dot: the "." in skrin.sut,
// which also reads as a shutter / record button. Teal → blue squircle background.
import AppKit

let master: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// macOS-style continuous-corner squircle (superellipse) inside `rect`.
func squircle(_ rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = c.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = c.y + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

func drawIcon(in ctx: CGContext, size: CGFloat) {
    let s = size / master
    ctx.scaleBy(x: s, y: s)

    // Icon body on Apple's grid: 824×824 centered in 1024, with a soft drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x1652E0))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: diagonal teal → blue gradient, plus a soft light from the top.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bg = CGGradient(colorsSpace: space, colors: [color(0x19D3B0), color(0x1597D8), color(0x1B4FD6)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 160, y: 900), end: CGPoint(x: 880, y: 120), options: [])
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    // Viewfinder corners.
    let frame = CGRect(x: 512 - 248, y: 512 - 248, width: 496, height: 496)
    let arm: CGFloat = 150, width: CGFloat = 62, r: CGFloat = 70
    let corners = CGMutablePath()
    // Each corner: arm → rounded corner → arm.
    func corner(_ p: CGPoint, _ dx: CGFloat, _ dy: CGFloat) {
        corners.move(to: CGPoint(x: p.x, y: p.y + dy * arm))
        corners.addLine(to: CGPoint(x: p.x, y: p.y + dy * r))
        corners.addQuadCurve(to: CGPoint(x: p.x + dx * r, y: p.y), control: p)
        corners.addLine(to: CGPoint(x: p.x + dx * arm, y: p.y))
    }
    corner(CGPoint(x: frame.minX, y: frame.maxY), 1, -1)
    corner(CGPoint(x: frame.maxX, y: frame.maxY), -1, -1)
    corner(CGPoint(x: frame.minX, y: frame.minY), 1, 1)
    corner(CGPoint(x: frame.maxX, y: frame.minY), -1, 1)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x0A2A6B, 0.35))
    ctx.addPath(corners)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // The dot: warm yellow with a subtle glow and highlight.
    let dot = CGRect(x: 512 - 84, y: 512 - 84, width: 168, height: 168)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 30, color: color(0xFFB000, 0.55))
    ctx.setFillColor(color(0xFFC93C))
    ctx.fillEllipse(in: dot)
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addEllipse(in: dot)
    ctx.clip()
    let shine = CGGradient(colorsSpace: space, colors: [color(0xFFE48A), color(0xFFB21E)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: dot.midX, y: dot.maxY), end: CGPoint(x: dot.midX, y: dot.minY), options: [])
    ctx.restoreGState()
}

func png(size: Int) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(size))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try png(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns and Resources/AppIcon.png" : "iconutil failed")
