// Draws the Scorebug app icon (1024×1024 PNG) with CoreGraphics and the bundled
// Barlow Condensed font. Regenerate after changing the design:
//   swift ios/Resources/AppIcon/make-icon.swift
import AppKit
import CoreText
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let font = root.appendingPathComponent("Fonts/BarlowCondensed-Bold.ttf")
CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func draw(size: Int, to url: URL) throws {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Ground: near-black.
    ctx.setFillColor(color(0x0B0D10)); ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

    // The scorebug: two team rows on a dark card.
    let card = CGRect(x: 152, y: 302, width: 720, height: 420)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 64, cornerHeight: 64, transform: nil))
    ctx.setFillColor(color(0x1B1F25)); ctx.fillPath()

    func row(y: CGFloat, team: UInt32, score: String, dim: Bool) {
        let chip = CGRect(x: 208, y: y, width: 40, height: 140)
        ctx.addPath(CGPath(roundedRect: chip, cornerWidth: 20, cornerHeight: 20, transform: nil))
        ctx.setFillColor(color(team)); ctx.fillPath()
        // Name stand-in: a rounded bar, so the icon reads at any size and in any language.
        let bar = CGRect(x: 288, y: y + 46, width: 250, height: 48)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 24, cornerHeight: 24, transform: nil))
        ctx.setFillColor(color(0xF2F4F7, dim ? 0.45 : 0.9)); ctx.fillPath()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "BarlowCondensed-Bold", size: 200)!,
            .foregroundColor: NSColor(cgColor: color(0xF2F4F7, dim ? 0.6 : 1))!,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: score, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: 816 - width, y: y + 4)
        CTLineDraw(line, ctx)
    }
    row(y: 532, team: 0x2563EB, score: "25", dim: false)
    row(y: 350, team: 0xF97316, score: "23", dim: true)

    // Live dot.
    ctx.setFillColor(color(0xE5372C)); ctx.fillEllipse(in: CGRect(x: 790, y: 668, width: 108, height: 108))

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
