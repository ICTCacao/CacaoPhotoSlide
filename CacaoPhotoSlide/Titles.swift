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

/// タイトルの出方・消え方
enum TitleEffect: String, CaseIterable, Identifiable, Codable {
    case none, fade, slideUp, slideDown, slideLeft, slideRight, zoom, typewriter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "なし（パッと出る）"
        case .fade: return "フェード"
        case .slideUp: return "下からスライド"
        case .slideDown: return "上からスライド"
        case .slideLeft: return "左からスライド"
        case .slideRight: return "右からスライド"
        case .zoom: return "ズームイン"
        case .typewriter: return "タイプライター（1 文字ずつ）"
        }
    }
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
    var offsetX: Double = 0          // 位置の微調整（画面の幅に対する割合。右が +）
    var offsetY: Double = 0          // 位置の微調整（画面の高さに対する割合。下が +）
    var effect = TitleEffect.fade    // 出るとき・消えるときの動き
    var effectDuration: Double = 0.5 // その動きにかける秒数

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
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        effect = try c.decodeIfPresent(TitleEffect.self, forKey: .effect) ?? .fade
        effectDuration = try c.decodeIfPresent(Double.self, forKey: .effectDuration) ?? 0.5
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

/// ある時刻のタイトルの見え方
struct TitleState {
    var opacity: Double = 1
    var dx: CGFloat = 0          // 動き（画面の高さに対する割合）
    var dy: CGFloat = 0
    var scale: CGFloat = 1
    var reveal: Double = 1       // タイプライターで、何割の文字を見せるか
}

enum TitleMath {
    /// 時刻 t での見え方。出ていない時刻は nil。t が nil なら、動きのない完成形。settled なら出ている時間かどうかだけ見る
    static func state(_ item: TitleItem, at t: Double?, settled: Bool = false) -> TitleState? {
        guard let t else { return TitleState() }
        guard t >= item.start else { return nil }
        let timed = item.duration > 0
        let end = item.start + item.duration
        if timed, t > end { return nil }
        if settled { return TitleState() }
        let f = max(0.05, timed ? min(item.effectDuration, item.duration / 2) : item.effectDuration)
        let pin = min(1, max(0, (t - item.start) / f))
        let pout = timed ? min(1, max(0, (end - t) / f)) : 1
        let p = min(TransitionMath.easeInOut(pin), TransitionMath.easeInOut(pout))
        let d: CGFloat = 0.15
        var s = TitleState()
        switch item.effect {
        case .none: break
        case .fade: s.opacity = p
        case .slideUp: s.opacity = p; s.dy = CGFloat(1 - p) * d
        case .slideDown: s.opacity = p; s.dy = -CGFloat(1 - p) * d
        case .slideLeft: s.opacity = p; s.dx = -CGFloat(1 - p) * d
        case .slideRight: s.opacity = p; s.dx = CGFloat(1 - p) * d
        case .zoom: s.opacity = p; s.scale = 0.6 + 0.4 * CGFloat(p)
        case .typewriter: s.reveal = pin; s.opacity = TransitionMath.easeInOut(pout)
        }
        return s
    }
}

/// 画面用のタイトル。time が nil なら全部を完成形で見せる（設定画面のプレビュー）。settled なら動きなしで、出ている時間のものだけ
struct TitleOverlay: View {
    let items: [TitleItem]
    let time: Double?
    var settled = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(items) { item in
                    if let st = TitleMath.state(item, at: time, settled: settled), st.opacity > 0.001, !item.text.isEmpty {
                        label(item, size: geo.size, state: st)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
    }

    /// タイプライターのときは、まだ出ない文字を透明にする（行の折り返しが変わらないように、文字は全部置いておく）
    private func text(_ item: TitleItem, reveal: Double) -> Text {
        guard reveal < 1 else { return Text(item.text) }
        var a = AttributedString(item.text)
        let n = Int(Double(item.text.count) * reveal)
        let idx = a.index(a.startIndex, offsetByCharacters: n)
        a[idx...].foregroundColor = .clear
        return Text(a)
    }

    private func label(_ item: TitleItem, size: CGSize, state s: TitleState) -> some View {
        let height = size.height
        let fs = item.size * height
        return text(item, reveal: s.reveal)
            .font(.system(size: fs, weight: item.bold ? .bold : .regular))
            .foregroundStyle(Color(nsColor: item.nsColor))
            .multilineTextAlignment(item.anchor.textAlignment)
            .shadow(color: item.shadow ? .black.opacity(0.65) : .clear, radius: fs * 0.06, x: 0, y: fs * 0.03)
            .scaleEffect(s.scale)
            .offset(x: s.dx * height, y: s.dy * height)
            .padding(height * 0.04)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: item.anchor.alignment)
            .offset(x: item.offsetX * size.width, y: item.offsetY * size.height)
            .opacity(s.opacity)
    }
}

/// mp4 用のタイトル（Core Graphics の上に AppKit で文字を描く。配置と動きは TitleOverlay と同じ）
enum TitleRenderer {
    static func draw(_ items: [TitleItem], at time: Double, in ctx: CGContext, size: CGSize) {
        for item in items where !item.text.isEmpty {
            guard let st = TitleMath.state(item, at: time), st.opacity > 0.001 else { continue }
            let fs = item.size * size.height
            let m = size.height * 0.04
            let box = CGRect(x: m, y: m, width: size.width - 2 * m, height: size.height - 2 * m)
            let para = NSMutableParagraphStyle()
            para.alignment = item.anchor.nsAlignment
            var attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fs, weight: item.bold ? .bold : .regular),
                .foregroundColor: item.nsColor.withAlphaComponent(st.opacity),
                .paragraphStyle: para,
            ]
            if item.shadow {
                let sh = NSShadow()
                sh.shadowColor = NSColor.black.withAlphaComponent(0.65 * st.opacity)
                sh.shadowBlurRadius = fs * 0.12
                sh.shadowOffset = NSSize(width: 0, height: -fs * 0.03)
                attrs[.shadow] = sh
            }
            let text = NSMutableAttributedString(string: item.text, attributes: attrs)
            if st.reveal < 1 {
                let n = Int(Double(item.text.count) * st.reveal)
                let from = item.text.index(item.text.startIndex, offsetBy: n)
                let range = NSRange(from..<item.text.endIndex, in: item.text)
                text.addAttribute(.foregroundColor, value: NSColor.clear, range: range)
                text.removeAttribute(.shadow, range: range)
            }
            // 文字の塊（いちばん長い行の幅 × 行数ぶんの高さ）を置く場所。拡大・移動はこの塊の中心を基準にする
            let bound = text.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin])
            let tw = min(box.width, ceil(bound.width) + 2), hgt = ceil(bound.height)
            var x = box.minX                                   // CG は y が上向き
            if item.anchor.h == 0 { x = box.midX - tw / 2 } else if item.anchor.h > 0 { x = box.maxX - tw }
            var y = box.minY
            if item.anchor.v < 0 { y = box.maxY - hgt } else if item.anchor.v == 0 { y = box.midY - hgt / 2 }
            let rect = CGRect(x: x, y: y, width: tw, height: hgt)
            ctx.saveGState()
            ctx.translateBy(x: rect.midX + st.dx * size.height + item.offsetX * size.width,
                            y: rect.midY - st.dy * size.height - item.offsetY * size.height)
            ctx.scaleBy(x: st.scale, y: st.scale)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
            let saved = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            text.draw(with: rect, options: [.usesLineFragmentOrigin])
            NSGraphicsContext.current = saved
            ctx.restoreGState()
        }
    }
}
