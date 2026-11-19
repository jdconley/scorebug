// swift ios/AppStore/frame.swift <raw-dir> <out-dir> <prefix>
// Store screenshots: each raw capture named in captions.json, on the app's dark ground with its
// caption above, in a rounded frame. Output keeps the raw pixel size (portrait or landscape) and is
// a JPEG with no alpha under 1.5 MB, as App Store Connect wants. <prefix> names the files:
// iphone-1.jpg, iphone-2.jpg, …
import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count == 4 else { fatalError("usage: frame.swift <raw-dir> <out-dir> <prefix>") }
let raw = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2]), prefix = args[3]
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
CTFontManagerRegisterFontsForURL(here.appendingPathComponent("../Resources/Fonts/BarlowCondensed-Bold.ttf") as CFURL, .process, nil)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct Caption: Decodable { let shot: String; let title: String; let line: String }
let captions = try JSONDecoder().decode([Caption].self, from: Data(contentsOf: here.appendingPathComponent("captions.json")))

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(_ text: String, font: NSFont, color: CGColor, in rect: CGRect, context: CGContext) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!, .paragraphStyle: style])
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(string), CFRange(), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, context)
}

var index = 0
for caption in captions {
    let url = raw.appendingPathComponent("\(caption.shot).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let shot = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("skip \(caption.shot): no \(url.lastPathComponent)"); continue
    }
    index += 1
    let w = CGFloat(shot.width), h = CGFloat(shot.height), landscape = w > h
    let short = min(w, h)
    let context = CGContext(data: nil, width: shot.width, height: shot.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // Ground: the app's dark gradient with a red glow behind the caption.
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0x1B1F25), color(0x0B0D10)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
    let glow = CGGradient(colorsSpace: nil, colors: [color(0xE5372C, 0.28), color(0xE5372C, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: w / 2, y: h), startRadius: 0,
                               endCenter: CGPoint(x: w / 2, y: h), endRadius: short * 0.9, options: [])

    // Caption: Barlow Condensed headline, system subline.
    let titleSize = short * (landscape ? 0.085 : 0.088), lineSize = short * (landscape ? 0.036 : 0.042)
    let captionHeight = titleSize * 1.15 + lineSize * 1.5 + short * 0.05
    let top = h - short * (landscape ? 0.07 : 0.1)
    draw(caption.title.uppercased(), font: NSFont(name: "BarlowCondensed-Bold", size: titleSize)!, color: color(0xF2F4F7),
         in: CGRect(x: 0, y: top - titleSize * 1.15, width: w, height: titleSize * 1.6), context: context)
    draw(caption.line, font: .systemFont(ofSize: lineSize, weight: .medium), color: color(0xC9CED6),
         in: CGRect(x: w * 0.06, y: top - titleSize * 1.15 - lineSize * 1.8, width: w * 0.88, height: lineSize * 1.8), context: context)

    // The screen, scaled to fit under the caption, in a rounded frame with a shadow.
    let room = CGSize(width: w * (landscape ? 0.86 : 0.84), height: top - captionHeight - short * 0.05)
    let scale = min(room.width / w, room.height / h)
    let size = CGSize(width: w * scale, height: h * scale)
    let rect = CGRect(x: (w - size.width) / 2, y: short * 0.05 + (room.height - size.height) / 2, width: size.width, height: size.height)
    let radius = min(size.width, size.height) * 0.075, border = short * 0.008
    let outer = rect.insetBy(dx: -border, dy: -border)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -short * 0.015), blur: short * 0.06, color: color(0x000000, 0.7))
    context.addPath(CGPath(roundedRect: outer, cornerWidth: radius + border, cornerHeight: radius + border, transform: nil))
    context.setFillColor(color(0x262A30)); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.interpolationQuality = .high
    context.draw(shot, in: rect)
    context.restoreGState()

    // JPEG, stepping quality down until it's under 1.5 MB.
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    var quality = 0.92, data = Data()
    repeat {
        data = rep.representation(using: .jpeg, properties: [.compressionFactor: quality])!
        quality -= 0.05
    } while data.count > 1_450_000 && quality > 0.5
    let file = out.appendingPathComponent("\(prefix)-\(index).jpg")
    try data.write(to: file)
    print("\(file.lastPathComponent) \(shot.width)x\(shot.height) \(data.count / 1024) KB  \(caption.shot)")
}
