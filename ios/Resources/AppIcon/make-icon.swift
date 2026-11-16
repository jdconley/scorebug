// Draws the Scorebug app icon (1024×1024 PNG) with CoreGraphics and the bundled
// Barlow Condensed font: a scorebug card over a hardwood volleyball court.
// Regenerate after changing the design:
//   swift ios/Resources/AppIcon/make-icon.swift
import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let font = root.appendingPathComponent("Fonts/BarlowCondensed-Bold.ttf")
CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32, top y0: CGFloat, bottom y1: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func roundedRect(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat, fill: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(fill); ctx.fillPath()
}

func draw(size: Int, to url: URL) throws {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Hardwood court, lit from above, with sidelines in perspective, the attack line and the net.
    gradient(ctx, 0xD9944F, 0x8E5226, top: 1024, bottom: 0)
    ctx.setStrokeColor(color(0xFFF6EA, 0.9)); ctx.setLineWidth(14)
    ctx.move(to: CGPoint(x: 210, y: 1024)); ctx.addLine(to: CGPoint(x: -80, y: 380)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 814, y: 1024)); ctx.addLine(to: CGPoint(x: 1104, y: 380)); ctx.strokePath()
    ctx.move(to: CGPoint(x: 0, y: 760)); ctx.addLine(to: CGPoint(x: 1024, y: 760)); ctx.strokePath()
    ctx.setFillColor(color(0x0B0D10, 0.85)); ctx.fill(CGRect(x: 0, y: 860, width: 1024, height: 22))
    ctx.setFillColor(color(0xF2F4F7)); ctx.fill(CGRect(x: 0, y: 882, width: 1024, height: 10))

    // The scorebug: two team rows on a dark card with a soft drop shadow.
    let card = CGRect(x: 120, y: 150, width: 784, height: 457)
    let k = card.height / 420
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18 * k), blur: 48 * k, color: color(0x000000, 0.55))
    roundedRect(ctx, card, radius: 64 * k, fill: color(0x1B1F25))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 64 * k, cornerHeight: 64 * k, transform: nil)); ctx.clip()
    gradient(ctx, 0x262B33, 0x1B1F25, top: card.maxY, bottom: card.midY)
    ctx.restoreGState()

    func row(y: CGFloat, team: UInt32, score: String, dim: Bool) {
        roundedRect(ctx, CGRect(x: card.minX + 56 * k, y: y, width: 40 * k, height: 140 * k), radius: 20 * k,
                    fill: color(team))
        // Name stand-in: a rounded bar, so the icon reads at any size and in any language.
        roundedRect(ctx, CGRect(x: card.minX + 136 * k, y: y + 46 * k, width: 250 * k, height: 48 * k),
                    radius: 24 * k, fill: color(0xF2F4F7, dim ? 0.42 : 0.92))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "BarlowCondensed-Bold", size: 200 * k)!,
            .foregroundColor: NSColor(cgColor: color(0xF2F4F7, dim ? 0.55 : 1))!,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: score, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: card.maxX - 56 * k - width, y: y + 4 * k)
        CTLineDraw(line, ctx)
    }
    row(y: card.minY + 230 * k, team: 0x2563EB, score: "25", dim: false)
    row(y: card.minY + 48 * k, team: 0xF97316, score: "23", dim: true)

    // Live dot with a glow.
    let d = 108 * k
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40 * k, color: color(0xFF3B30, 0.7))
    ctx.setFillColor(color(0xFF3B30))
    ctx.fillEllipse(in: CGRect(x: card.maxX - d / 2 - 10 * k, y: card.maxY - d / 2 + 10 * k, width: d, height: d))
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let outputs = [
    root.appendingPathComponent("Assets.xcassets/AppIcon.appiconset/AppIcon.png"),
    root.appendingPathComponent("WatchAssets.xcassets/AppIcon.appiconset/AppIcon.png"),
]
for output in outputs {
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try draw(size: 1024, to: output)
    print("wrote \(output.path)")
}
