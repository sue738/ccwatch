#!/usr/bin/env swift
// make-icon.swift — dist/ccwatch.app に入れる AppIcon.icns を生成する。
//
// アイコンを手描きの画像ファイルとしてリポジトリに置くと、色を変えたい時に
// 誰も再生成できない(元データがどこにあるか分からなくなる)。ここでは
// メニューバー・パネル見出しと同じ SF Symbol をコードから描くので、
// 見た目の出どころが1つに保たれる。`swift make-icon.swift` で作り直せる。
import AppKit

let symbol = "gauge.with.dots.needle.50percent"
// パネルのアクセント(Nord blue)と同系。macOS のアイコンは角丸矩形が標準だが、
// squircle を自前で描くと本物とずれるので、システムに任せず単純な角丸にする。
let bg1 = NSColor(red: 0.29, green: 0.44, blue: 0.62, alpha: 1)  // #4a70a0
let bg2 = NSColor(red: 0.19, green: 0.30, blue: 0.45, alpha: 1)  // #304d73

func render(_ px: Int) -> NSImage {
    let size = NSSize(width: px, height: px)
    let img = NSImage(size: size)
    img.lockFocus()
    let rect = NSRect(origin: .zero, size: size)
    // 角丸は macOS 標準のアイコン比率(約22.37%)に合わせる
    let radius = CGFloat(px) * 0.2237
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.addClip()
    NSGradient(starting: bg1, ending: bg2)?.draw(in: rect, angle: -90)

    let inset = CGFloat(px) * 0.20
    let glyphRect = rect.insetBy(dx: inset, dy: inset)
    let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.56, weight: .semibold)
    if let raw = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
       let glyph = raw.withSymbolConfiguration(cfg) {
        // 背景の上で直接 .sourceAtop を使うと、合成先(不透明な背景)の
        // アルファ全域が塗られてグリフが白い矩形になる。透明なキャンバスに
        // 一度描いてそこで色を乗せる — こうすると合成先のアルファが
        // グリフ形状そのものなので、狙い通り字型だけが白くなる。
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

// iconutil が要求する固定の名前と大きさ。1x/2x の両方を出す。
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
