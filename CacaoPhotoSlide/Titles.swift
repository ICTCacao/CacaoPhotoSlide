import SwiftUI
import AppKit

/// タイトルを置く位置（画面の 3×3）
enum TitleAnchor: String, CaseIterable, Identifiable, Codable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .topLeft: return "左上"
        case .top: return "上"
        case .topRight: return "右上"
        case .left: return "左"
        case .center: return "中央"
        case .right: return "右"
        case .bottomLeft: return "左下"
        case .bottom: return "下"
        case .bottomRight: return "右下"
        }
    }
    /// 横: -1 左 / 0 中央 / 1 右
    var h: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: return -1
        case .top, .center, .bottom: return 0
        default: return 1
        }
    }
    /// 縦: -1 上 / 0 中央 / 1 下
    var v: Int {
        switch self {
        case .topLeft, .top, .topRight: return -1
        case .left, .center, .right: return 0
        default: return 1
        }
    }
    var alignment: Alignment {
        Alignment(horizontal: h < 0 ? .leading : (h > 0 ? .trailing : .center),
                  vertical: v < 0 ? .top : (v > 0 ? .bottom : .center))
    }
    var textAlignment: TextAlignment { h < 0 ? .leading : (h > 0 ? .trailing : .center) }
    var nsAlignment: NSTextAlignment { h < 0 ? .left : (h > 0 ? .right : .center) }
}

/// 画面に重ねる文字 1 つ（タイトル・クレジットなど）
struct TitleItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = "タイトル"
    var anchor = TitleAnchor.bottom
    var size: Double = 0.07          // 文字の大きさ（画面の高さに対する割合）
    var color = "#FFFFFF"            // sRGB の 16 進
    var bold = true
    var shadow = true
    var start: Double = 0            // 出し始める時刻（スライドショーの頭から何秒）
    var duration: Double = 5         // 出している秒数。0 なら最後まで

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        anchor = try c.decodeIfPresent(TitleAnchor.self, forKey: .anchor) ?? .bottom
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.07
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "#FFFFFF"
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? true
        shadow = try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? true
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 5
    }

    var nsColor: NSColor {
        var s = color
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return .white }
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                       blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    var swiftUIColor: Color {
        get { Color(nsColor: nsColor) }
        set {
            let c = NSColor(newValue).usingColorSpace(.sRGB) ?? .white
            color = String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                           Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
    }
}

enum TitleMath {
    static let fade = 0.5

    /// 時刻 t での濃さ。出し始めと消える前に 0.5 秒かけてフェードする
    static func opacity(_ item: TitleItem, at t: Double) -> Double {
        guard t >= item.start else { return 0 }
        let timed = item.duration > 0
        let end = item.start + item.duration
        if timed, t > end { return 0 }
        let f = timed ? min(fade, item.duration / 2) : fade
        let fin = f > 0 ? min(1, (t - item.start) / f) : 1
        let fout = timed && f > 0 ? min(1, (end - t) / f) : 1
        return max(0, min(1, fin * fout))
    }
}

/// 画面用のタイトル。time が nil なら全部を見せる（設定画面のプレビュー）
struct TitleOverlay: View {
    let items: [TitleItem]
    let time: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(items) { item in
                    let op = time.map { TitleMath.opacity(item, at: $0) } ?? 1
                    if op > 0.001, !item.text.isEmpty {
                        label(item, height: geo.size.height, opacity: op)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    private func label(_ item: TitleItem, height: CGFloat, opacity: Double) -> some View {
        let fs = item.size * height
        return Text(item.text)
            .font(.system(size: fs, weight: item.bold ? .bold : .regular))
            .foregroundStyle(Color(nsColor: item.nsColor))
            .multilineTextAlignment(item.anchor.textAlignment)
            .shadow(color: item.shadow ? .black.opacity(0.65) : .clear, radius: fs * 0.06, x: 0, y: fs * 0.03)
            .padding(height * 0.04)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: item.anchor.alignment)
            .opacity(opacity)
    }
}

/// mp4 用のタイトル（Core Graphics の上に AppKit で文字を描く。配置は TitleOverlay と同じ）
enum TitleRenderer {
    static func draw(_ items: [TitleItem], at time: Double, in ctx: CGContext, size: CGSize) {
        for item in items where !item.text.isEmpty {
            let op = TitleMath.opacity(item, at: time)
            guard op > 0.001 else { continue }
            let fs = item.size * size.height
            let m = size.height * 0.04
            let box = CGRect(x: m, y: m, width: size.width - 2 * m, height: size.height - 2 * m)
            let para = NSMutableParagraphStyle()
            para.alignment = item.anchor.nsAlignment
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs, weight: item.bold ? .bold : .regular),
                .foregroundColor: item.nsColor.withAlphaComponent(op),
                .paragraphStyle: para,
            ]
            if item.shadow {
                let sh = NSShadow()
                sh.shadowColor = NSColor.black.withAlphaComponent(0.65 * op)
                sh.shadowBlurRadius = fs * 0.12
                sh.shadowOffset = NSSize(width: 0, height: -fs * 0.03)
                attrs[.shadow] = sh
            }
            let text = NSAttributedString(string: item.text, attributes: attrs)
            let hgt = ceil(text.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin]).height)
            var y = box.minY                                   // CG は y が上向き
            if item.anchor.v < 0 { y = box.maxY - hgt } else if item.anchor.v == 0 { y = box.midY - hgt / 2 }
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(with: CGRect(x: box.minX, y: y, width: box.width, height: hgt), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.current = saved
        }
    }
}
