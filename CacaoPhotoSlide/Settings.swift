import Foundation

/// 写真の切り替え方
enum Transition: String, CaseIterable, Identifiable, Codable {
    case kenBurns, crossfade, push, zoom, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .kenBurns: return "Ken Burns（ゆっくり寄る・流れる）"
        case .crossfade: return "クロスフェード"
        case .push: return "スライド（横に流す）"
        case .zoom: return "ズーム"
        case .none: return "なし（パッと切り替え）"
        }
    }
}

/// 写真の順番
enum PhotoOrder: String, CaseIterable, Identifiable {
    case name, date, random, manual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "名前順"
        case .date: return "撮影日順"
        case .random: return "ランダム"
        case .manual: return "手動"
        }
    }
}

/// 画面への収め方
enum FitMode: String, CaseIterable, Identifiable, Codable {
    case fit, fill
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "全体を表示"
        case .fill: return "画面いっぱい"
        }
    }
}

/// 段（トラック）ごとの色
enum TrackColors {
    static let names = ["orange", "teal", "purple", "green", "pink", "indigo", "mint", "brown"]
}

/// スライドショーの表示先
enum DisplayMode: String, CaseIterable, Identifiable {
    case fullScreen, window
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fullScreen: return "全画面"
        case .window: return "別ウインドウ"
        }
    }
}

/// スライドショー開始時に固める設定
struct SlideshowSettings {
    var dwell: TimeInterval            // 1 枚を見せる秒数（次の切り替えまで）
    var transition: Transition
    var transitionDuration: TimeInterval
    var loop: Bool
    var fit: FitMode
    var clips: [MusicClip] = []        // 音声のタイムライン
    var document: URL?                 // クリップの相対パスを解決するための書類の場所
    var endFade: TimeInterval = 0      // 最後の写真を、終わるこの秒数前から黒へフェードアウト（0 なら画面ではなし、mp4 は切り替えの長さ）
    var titles: [TitleItem] = []       // 画面に重ねる文字
    var overrides: [String: PhotoOverride] = [:]   // 写真ごとの表示時間・切り替え・収め方（写真のパスがキー）
}

/// 写真 1 枚だけの設定。nil の項目は全体の設定に従う
struct PhotoOverride: Codable, Equatable {
    var dwell: TimeInterval?
    var transition: Transition?
    var fit: FitMode?
    var isEmpty: Bool { dwell == nil && transition == nil && fit == nil }
}

/// 流す写真ごとの表示時間・切り替え・開始時刻（個別設定を反映）。画面・タイムライン・mp4 で同じものを使う
struct SlideTiming {
    let dwells: [TimeInterval]
    let transitions: [Transition]
    let fits: [FitMode]
    let trs: [TimeInterval]        // その写真に入ってくる切り替えの長さ（前の写真・自分の長さを超えない）
    let starts: [TimeInterval]
    let total: TimeInterval        // 最後の黒へのフェードを含む全体の長さ
    var count: Int { dwells.count }

    init(urls: [URL], settings: SlideshowSettings) {
        var dw: [TimeInterval] = [], tx: [Transition] = [], ft: [FitMode] = []
        for u in urls {
            let o = settings.overrides[u.path]
            dw.append(max(0.1, o?.dwell ?? settings.dwell))
            tx.append(o?.transition ?? settings.transition)
            ft.append(o?.fit ?? settings.fit)
        }
        var tr: [TimeInterval] = []
        for i in dw.indices {
            tr.append(tx[i] == .none ? 0 : min(settings.transitionDuration, dw[i], i > 0 ? dw[i - 1] : dw[i]))
        }
        var st: [TimeInterval] = []
        var t: TimeInterval = 0
        for d in dw { st.append(t); t += d }
        dwells = dw; transitions = tx; fits = ft; trs = tr; starts = st
        total = t + (tr.last ?? 0)
    }

    /// その時刻に出ている写真の番号
    func index(at time: TimeInterval) -> Int {
        guard !starts.isEmpty else { return 0 }
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// 写真の区切り（count + 1 個。最後は最後の写真の表示が終わる時刻）
    var bounds: [TimeInterval] { starts + [(starts.last ?? 0) + (dwells.last ?? 0)] }

    /// Ken Burns の動きの長さ。次の写真に切り替わり終わるまで動かす
    func motionLength(_ i: Int) -> TimeInterval {
        dwells[i] + (i + 1 < count ? trs[i + 1] : trs[i])
    }
}

enum Prefs {
    static let dwell = "dwell"
    static let transition = "transition"
    static let transitionDuration = "transitionDuration"
    static let order = "order"
    static let manualOrder = "manualOrder"
    static let endFade = "endFade"
    static let titles = "titles"
    static let overrides = "overrides"
    static let loop = "loop"
    static let recursive = "recursive"
    static let fit = "fit"
    static let lastSources = "lastSources"
    static let exportSize = "exportSize"
    static let exportFps = "exportFps"
    static let lastDocument = "lastDocument"
    static let displayMode = "displayMode"
}
