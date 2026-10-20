// dmg 背景画像を生成する（600x400 ピクセル。Finder は dpi を見ないので等倍で描く）
import Foundation
import AppKit

let scale: CGFloat = 1
let size = NSSize(width: 600, height: 400)
let px = NSSize(width: size.width * scale, height: size.height * scale)
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "background.png"
let appName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "CacaoTrans"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.cgContext.scaleBy(x: scale, y: scale)

// 背景: 淡いグラデーション
let bg = NSGradient(starting: NSColor(calibratedWhite: 0.97, alpha: 1), ending: NSColor(calibratedWhite: 0.90, alpha: 1))!
bg.draw(in: NSRect(origin: .zero, size: size), angle: -90)

// 矢印（左のアプリ → 右の Applications）。アイコンは y=190 付近に置く
let arrowColor = NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.18, alpha: 0.85)
let path = NSBezierPath()
let y: CGFloat = 400 - 190   // Finder 座標は上原点、描画は下原点
let x0: CGFloat = 250, x1: CGFloat = 350
path.move(to: NSPoint(x: x0, y: y))
path.line(to: NSPoint(x: x1 - 22, y: y))
path.lineWidth = 10
path.lineCapStyle = .round
arrowColor.setStroke()
path.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: x1, y: y))
head.line(to: NSPoint(x: x1 - 30, y: y + 18))
head.line(to: NSPoint(x: x1 - 30, y: y - 18))
head.close()
arrowColor.setFill()
head.fill()

// 説明文
let para = NSMutableParagraphStyle(); para.alignment = .center
let title = "\(appName) をインストール"
let body = "左のアプリを右の Applications フォルダへドラッグしてください"
let note = "初回起動時に警告が出たら、Applications 内のアプリを右クリック →「開く」"
(title as NSString).draw(in: NSRect(x: 0, y: 400 - 70, width: 600, height: 40),
    withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor(calibratedWhite: 0.2, alpha: 1), .paragraphStyle: para])
(body as NSString).draw(in: NSRect(x: 0, y: 400 - 100, width: 600, height: 24),
    withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor(calibratedWhite: 0.35, alpha: 1), .paragraphStyle: para])
(note as NSString).draw(in: NSRect(x: 0, y: 26, width: 600, height: 20),
    withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1), .paragraphStyle: para])

NSGraphicsContext.restoreGraphicsState()
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
