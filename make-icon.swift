#!/usr/bin/env swift
// Generates AppIcon.icns. Drawn in code from the same SF Symbol the menu bar
// uses, so the artwork has one source and stays regenerable — a committed image
// leaves nobody able to change a colour later.
import AppKit

let symbol = "gauge.with.dots.needle.50percent"
// Plain rounded rect, not a squircle: hand-rolled squircles never match the
// real one, and the mismatch is more visible than the missing curve.
let bg1 = NSColor(red: 0.29, green: 0.44, blue: 0.62, alpha: 1)  // #4a70a0
let bg2 = NSColor(red: 0.19, green: 0.30, blue: 0.45, alpha: 1)  // #304d73

func render(_ px: Int) -> NSImage {
    let size = NSSize(width: px, height: px)
    let img = NSImage(size: size)
    img.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    let radius = CGFloat(px) * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    NSGradient(starting: bg1, ending: bg2)?.draw(in: rect, angle: -90)

    let inset = CGFloat(px) * 0.20
    let glyphRect = rect.insetBy(dx: inset, dy: inset)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.56, weight: .semibold)
    if let raw = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
       let glyph = raw.withSymbolConfiguration(cfg) {
        // .sourceAtop over the opaque background fills the destination's whole
        // alpha and the glyph becomes a white rectangle. Tinting on a transparent
        // canvas first makes the destination alpha the glyph shape itself.
        let tinted = NSImage(size: glyph.size)
        tinted.lockFocus()
        glyph.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: glyph.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        let g = NSRect(
            x: glyphRect.midX - glyph.size.width / 2,
            y: glyphRect.midY - glyph.size.height / 2,
            width: glyph.size.width, height: glyph.size.height)
        tinted.draw(in: g)
    }
    img.unlockFocus()
    return img
}

func png(_ img: NSImage, _ px: Int) -> Data? {
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])
}

let fm = FileManager.default
let out = "AppIcon.iconset"
try? fm.removeItem(atPath: out)
try! fm.createDirectory(atPath: out, withIntermediateDirectories: true)

// The fixed names and sizes iconutil expects. Both 1x and 2x are emitted.
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in sizes {
    guard let d = png(render(px), px) else { continue }
    try! d.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
FileHandle.standardError.write("wrote \(out) (\(sizes.count) sizes)\n".data(using: .utf8)!)
