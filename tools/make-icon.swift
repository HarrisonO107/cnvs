// Renders the CNVS wallpaper art into a macOS-shaped app icon (1024 PNG).
// Usage: swift tools/make-icon.swift <source-image> <out.png>
// run.sh feeds the PNG to sips/iconutil to build AppIcon.icns.

import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <src> <out.png>\n".utf8))
    exit(2)
}
guard let source = NSImage(contentsOfFile: args[1]),
      let art = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

let canvas: CGFloat = 1024
let inset: CGFloat = 100          // macOS icons float inside the 1024 grid
let side = canvas - inset * 2
let radius = side * 0.2237        // Big Sur squircle ratio

guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let ctx = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ) else { exit(1) }

let rect = CGRect(x: inset, y: inset, width: side, height: side)
let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow, cast by filling the shape before the art goes down.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40,
              color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Aspect-fill the painting inside the squircle.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let imgW = CGFloat(art.width), imgH = CGFloat(art.height)
let scale = max(rect.width / imgW, rect.height / imgH)
let drawW = imgW * scale, drawH = imgH * scale
ctx.draw(art, in: CGRect(
    x: rect.midX - drawW / 2, y: rect.midY - drawH / 2, width: drawW, height: drawH
))

// Glass rim so the art doesn't butt straight into the Dock background.
ctx.addPath(CGPath(
    roundedRect: rect.insetBy(dx: 1.5, dy: 1.5),
    cornerWidth: radius - 1.5, cornerHeight: radius - 1.5, transform: nil
))
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

guard let cg = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: cg)
rep.size = NSSize(width: canvas, height: canvas)
guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: args[2]))
