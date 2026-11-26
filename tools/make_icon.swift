// Renders the Ad Nope app icon (1024×1024, opaque) with the system font.
//
//   swift tools/make_icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// Layout is in a 100×100 design grid (the same one the mock-ups used), scaled up.
// iOS applies the rounded-corner mask itself, so the image is a full square.

import AppKit

let size = 1024
let s = CGFloat(size) / 100

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downward, like the SVG mock-ups.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// Background
ctx.setFillColor(color(0x534AB7))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

/// Draws text with its baseline at (x, y) in the 100-unit grid.
func draw(_ text: String, size pt: CGFloat, color hex: UInt32, x: CGFloat, y: CGFloat,
          centered: Bool = false, tracking: CGFloat = 0) {
    let font = NSFont.systemFont(ofSize: pt * s, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(cgColor: color(hex))!,
        .kern: tracking * s,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    ctx.saveGState()
    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)  // undo the flip for glyphs
    ctx.textPosition = CGPoint(x: x * s - (centered ? CGFloat(width) / 2 : 0), y: y * s)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

draw("ad", size: 14, color: 0xCECBF6, x: 17, y: 31)
draw("nope", size: 30, color: 0xFFFFFF, x: 50, y: 62, centered: true, tracking: -1)

// Coral dot
ctx.setFillColor(color(0xF0997B))
ctx.fillEllipse(in: CGRect(x: (78 - 6) * s, y: (30 - 6) * s, width: 12 * s, height: 12 * s))

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
