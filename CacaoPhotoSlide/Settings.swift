import Foundation

/// 写真の切り替え方
enum Transition: String, CaseIterable, Identifiable {
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
    case name, date, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "名前順"
        case .date: return "撮影日順"
        case .random: return "ランダム"
        }
    }
}

/// 画面への収め方
enum FitMode: String, CaseIterable, Identifiable {
    case fit, fill
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fit: return "全体を表示"
        case .fill: return "画面いっぱい"
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
}

enum Prefs {
    static let dwell = "dwell"
    static let transition = "transition"
    static let transitionDuration = "transitionDuration"
    static let order = "order"
    static let loop = "loop"
    static let recursive = "recursive"
    static let fit = "fit"
    static let lastSources = "lastSources"
}
