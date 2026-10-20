// アプリアイコンを描く。使い方: swift make-icon.swift <out.png>
// カカオ色の土台に、重なった 2 枚の写真（空・山・太陽）と再生の三角
import Foundation
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let canvas: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r/255, green: g/255, blue: b/255, alpha: a)
}
let cacaoTop = rgb(139, 82, 58)
let cacaoBottom = rgb(92, 50, 34)
let cream = rgb(246, 233, 220)
let accent = rgb(240, 168, 76)

// 1. 角丸の土台
let inset: CGFloat = 100
let base = NSRect(x: inset, y: inset, width: canvas - inset*2, height: canvas - inset*2)
let squircle = NSBezierPath(roundedRect: base, xRadius: base.width * 0.225, yRadius: base.width * 0.225)
ctx.saveGState()
squircle.addClip()
NSGradient(starting: cacaoTop, ending: cacaoBottom)!.draw(in: base, angle: -90)
NSGradient(starting: NSColor(white: 1, alpha: 0.10), ending: NSColor(white: 1, alpha: 0))!
    .draw(in: NSRect(x: base.minX, y: base.midY, width: base.width, height: base.height/2), angle: -90)
ctx.restoreGState()

// 2. 写真（白い縁取りのカード）を描く関数
func drawPhoto(center: NSPoint, size: NSSize, rotation: CGFloat, dim: CGFloat) {
    ctx.saveGState()
    let t = NSAffineTransform()
    t.translateX(by: center.x, yBy: center.y)
    t.rotate(byDegrees: rotation)
    t.concat()
    let frame = NSRect(x: -size.width/2, y: -size.height/2, width: size.width, height: size.height)
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor(white: 0, alpha: 0.35).cgColor)
    cream.setFill()
    NSBezierPath(roundedRect: frame, xRadius: 28, yRadius: 28).fill()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    // 写真の中身: 空のグラデーション、太陽、山
    let inner = frame.insetBy(dx: 26, dy: 26)
    let innerPath = NSBezierPath(roundedRect: inner, xRadius: 14, yRadius: 14)
    innerPath.addClip()
    NSGradient(starting: rgb(118, 190, 232), ending: rgb(206, 232, 246))!.draw(in: inner, angle: -90)
    accent.setFill()
    NSBezierPath(ovalIn: NSRect(x: inner.maxX - 150, y: inner.maxY - 150, width: 92, height: 92)).fill()
    let back = NSBezierPath()
    back.move(to: NSPoint(x: inner.minX, y: inner.minY))
    back.line(to: NSPoint(x: inner.minX + inner.width * 0.30, y: inner.minY + inner.height * 0.62))
    back.line(to: NSPoint(x: inner.minX + inner.width * 0.58, y: inner.minY + inner.height * 0.30))
    back.line(to: NSPoint(x: inner.minX + inner.width * 0.72, y: inner.minY + inner.height * 0.44))
    back.line(to: NSPoint(x: inner.maxX, y: inner.minY))
    back.close()
    rgb(86, 130, 96).setFill(); back.fill()
    let front = NSBezierPath()
    front.move(to: NSPoint(x: inner.minX, y: inner.minY))
    front.line(to: NSPoint(x: inner.minX + inner.width * 0.52, y: inner.minY + inner.height * 0.42))
    front.line(to: NSPoint(x: inner.maxX, y: inner.minY))
    front.close()
    rgb(58, 100, 70).setFill(); front.fill()
    if dim > 0 { NSColor(white: 0, alpha: dim).setFill(); inner.fill() }
    ctx.restoreGState()
}

// 後ろの写真（少し傾けて暗め）と、前の写真
drawPhoto(center: NSPoint(x: 470, y: 560), size: NSSize(width: 520, height: 400), rotation: 8, dim: 0.18)
drawPhoto(center: NSPoint(x: 540, y: 490), size: NSSize(width: 520, height: 400), rotation: -4, dim: 0)

// 3. 再生の三角（右下、オレンジの丸の上）
let btnCenter = NSPoint(x: 760, y: 250)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: NSColor(white: 0, alpha: 0.35).cgColor)
accent.setFill()
NSBezierPath(ovalIn: NSRect(x: btnCenter.x - 105, y: btnCenter.y - 105, width: 210, height: 210)).fill()
ctx.restoreGState()
let tri = NSBezierPath()
tri.move(to: NSPoint(x: btnCenter.x - 38, y: btnCenter.y - 52))
tri.line(to: NSPoint(x: btnCenter.x - 38, y: btnCenter.y + 52))
tri.line(to: NSPoint(x: btnCenter.x + 54, y: btnCenter.y))
tri.close()
cacaoBottom.setFill(); tri.fill()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
