import Foundation
import CoreGraphics

/// V2（重ねる写真）のクリップ 1 つ。V1 の写真の上に、好きな時刻から、透明度を付けて重ねる
struct OverlayClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String                  // 写真（V2 ライブラリの中のもの）。書類の中なら "overlays/xxx" の相対、それ以外は絶対
    var start: TimeInterval = 0       // タイムライン上の開始秒
    var duration: TimeInterval = 5
    var opacity: Double = 1           // 透明度（1 で不透明）
    var scale: Double = 1             // 大きさ（1 で画面に収まる大きさ）
    var offsetX: Double = 0           // 位置の微調整（画面の幅に対する割合。右が +）
    var offsetY: Double = 0           // （画面の高さに対する割合。下が +）
    var fadeIn: TimeInterval = 0.5
    var fadeOut: TimeInterval = 0.5
    var track = 0                     // V のトラック（0 が V2、1 が V3…。大きいほど上＝手前）
    var transition: Transition?       // 出るときのエフェクト（nil なら設定のタブの値＝V1 と同じ）
    var fit: FitMode?                 // 表示の仕方（nil なら設定のタブの値＝V1 と同じ）

    init(path: String, start: TimeInterval, duration: TimeInterval) {
        self.path = path; self.start = start; self.duration = duration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 5
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        offsetX = try c.decodeIfPresent(Double.self, forKey: .offsetX) ?? 0
        offsetY = try c.decodeIfPresent(Double.self, forKey: .offsetY) ?? 0
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0.5
        fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0.5
        track = try c.decodeIfPresent(Int.self, forKey: .track) ?? 0
        transition = try c.decodeIfPresent(Transition.self, forKey: .transition)
        fit = try c.decodeIfPresent(FitMode.self, forKey: .fit)
    }

    var end: TimeInterval { start + duration }

    /// 実際のファイルの場所（書類の場所を渡すと相対パスを解決する）
    func url(in document: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let document { return document.appendingPathComponent(path) }
        return URL(fileURLWithPath: path)
    }
}

enum OverlayMath {
    /// クリップを、手前に重ねる順（下のトラックから順に）に並べる。段はクリップの track
    static func layout(_ clips: [OverlayClip]) -> (order: [OverlayClip], lanes: [UUID: Int]) {
        var lanes: [UUID: Int] = [:]
        for c in clips { lanes[c.id] = max(0, c.track) }
        let order = clips.sorted {
            let a = lanes[$0.id] ?? 0, b = lanes[$1.id] ?? 0
            return a == b ? $0.start < $1.start : a < b
        }
        return (order, lanes)
    }

    /// 時刻 t での見え方。出ていない時刻は nil。V1 の写真と同じエフェクト（Ken Burns・クロスフェード・スライド・ズーム・なし）と表示の仕方を使う。
    /// 入るときはイン、出るときはアウトの秒数をかけて動く。settled なら、出ている時間かどうかだけ見て、動きは付けない
    static func state(_ clip: OverlayClip, at t: TimeInterval, transition: Transition, fit: FitMode,
                      motion: KenBurnsMotion?, settled: Bool = false) -> OverlayState? {
        guard t >= clip.start, t <= clip.end else { return nil }
        let tr = clip.transition ?? transition
        var s = OverlayState(opacity: clip.opacity, scale: clip.scale, dx: clip.offsetX, dy: clip.offsetY,
                             fill: (clip.fit ?? fit) == .fill)
        if settled { return s }
        let fi = tr == .none ? 0 : min(clip.fadeIn, clip.duration / 2)
        let fo = tr == .none ? 0 : min(clip.fadeOut, clip.duration / 2)
        let pin = fi > 0 ? min(1, max(0, (t - clip.start) / fi)) : 1
        let pout = fo > 0 ? min(1, max(0, (clip.end - t) / fo)) : 1
        let ei = TransitionMath.easeInOut(pin), eo = TransitionMath.easeInOut(pout)
        let inFX = TransitionMath.incoming(tr, t: ei, width: 1)
        let outFX = TransitionMath.outgoing(tr, t: 1 - eo, width: 1)
        s.opacity *= inFX.opacity * outFX.opacity
        if tr == .kenBurns || tr == .crossfade { s.opacity *= eo }       // 出るときのフェード
        s.scale *= Double(inFX.scale * outFX.scale)
        s.dx += Double(inFX.dx + outFX.dx)
        if tr == .kenBurns, let m = motion {
            let p = clip.duration > 0 ? min(1, max(0, (t - clip.start) / clip.duration)) : 0
            s.scale *= Double(m.scale(p))
            s.dx += Double(m.offset(p).x)
            s.dy += Double(m.offset(p).y)
        }
        return s
    }
}

/// V2 のクリップ 1 つの、ある時刻の見え方（位置は画面の幅・高さに対する割合）
struct OverlayState {
    var opacity: Double
    var scale: Double
    var dx: Double
    var dy: Double
    var fill: Bool            // 画面いっぱい（はみ出す）か、全体を表示か
}

/// mp4 用に、重ねる写真 1 枚ぶんを描くもの
struct OverlayLayer {
    let image: CGImage
    let state: OverlayState
}
