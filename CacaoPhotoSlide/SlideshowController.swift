import Foundation
import CoreGraphics
import Observation

/// Ken Burns の動き（拡大率と、画面の幅・高さに対する割合のずらし）
struct KenBurnsMotion {
    var startScale: CGFloat
    var endScale: CGFloat
    var startOffset: CGPoint
    var endOffset: CGPoint

    static func random() -> KenBurnsMotion {
        let zoomIn = Bool.random()
        let near = CGFloat.random(in: 1.0...1.06)
        let far = CGFloat.random(in: 1.14...1.26)
        let (s0, s1) = zoomIn ? (near, far) : (far, near)
        // 流す向きをひとつ決め、その方向に始点→終点。拡大率ではみ出す範囲の中に収める
        let angle = Double.random(in: 0..<(2 * .pi))
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        func pt(_ scale: CGFloat, _ sign: CGFloat) -> CGPoint {
            let m = (scale - 1) / 2 * 0.9
            return CGPoint(x: dir.x * m * sign, y: dir.y * m * sign)
        }
        return KenBurnsMotion(startScale: s0, endScale: s1, startOffset: pt(s0, -1), endOffset: pt(s1, 1))
    }

    func scale(_ p: Double) -> CGFloat { startScale + (endScale - startScale) * CGFloat(p) }
    func offset(_ p: Double) -> CGPoint {
        CGPoint(x: startOffset.x + (endOffset.x - startOffset.x) * CGFloat(p),
                y: startOffset.y + (endOffset.y - startOffset.y) * CGFloat(p))
    }
}

struct Slide {
    let index: Int
    let url: URL
    let image: CGImage
    var start: Date          // この写真を出し始めた時刻（一時停止した分はあとでずらす）
    let motion: KenBurnsMotion
}

/// 再生の状態。画面は「今の時刻」とこの状態から描く
@Observable @MainActor
final class SlideshowController {
    let urls: [URL]
    let settings: SlideshowSettings
    private let loader: ImageLoader

    private(set) var current: Slide?
    private(set) var previous: Slide?      // 切り替え中だけ残す
    private(set) var pausedAt: Date?       // 一時停止した時刻（nil なら再生中）
    private(set) var hold = false          // 一時停止中でも切り替えや表示のために描画を続ける間
    private(set) var showsHud = false      // 枚数表示を出す（一時停止中と手で送った直後だけ）
    var onFinish: (() -> Void)?

    private var advanceTask: Task<Void, Never>?
    private var showTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var failures = 0
    private var music: MusicTimeline?

    var count: Int { urls.count }
    var isPaused: Bool { pausedAt != nil }
    var timelinePaused: Bool { isPaused && !hold }
    var hudVisible: Bool { isPaused || (hold && showsHud) }

    init(urls: [URL], settings: SlideshowSettings, maxPixel: Int) {
        self.urls = urls
        self.settings = settings
        self.loader = ImageLoader(urls: urls, maxPixel: maxPixel)
        music = MusicTimeline(clips: settings.clips, document: settings.document)
    }

    func start(at index: Int = 0) {
        show(min(max(0, index), max(0, count - 1)), direction: 1, manual: false, resync: true)
    }

    func stop() {
        music?.stop()
        music = nil
        advanceTask?.cancel(); showTask?.cancel(); holdTask?.cancel(); clearTask?.cancel()
        advanceTask = nil; showTask = nil; holdTask = nil; clearTask = nil
    }

    func togglePause() {
        if let p = pausedAt {
            let shift = Date().timeIntervalSince(p)
            current?.start += shift
            previous?.start += shift
            pausedAt = nil
            scheduleAdvance()
            music?.resume()
        } else {
            pausedAt = Date()
            advanceTask?.cancel(); advanceTask = nil
            music?.pause()
        }
        flashHold(hud: true)
    }

    func next(manual: Bool = true) {
        guard let cur = current else { return }
        var i = cur.index + 1
        var wrapped = false
        if i >= count {
            guard settings.loop else { if !manual { finish() }; return }
            i = 0
            wrapped = true
        }
        show(i, direction: 1, manual: manual, resync: manual || wrapped)
    }

    func previousSlide() {
        guard let cur = current else { return }
        var i = cur.index - 1
        if i < 0 {
            guard settings.loop else { return }
            i = count - 1
        }
        show(i, direction: -1, manual: true, resync: true)
    }

    /// 流している途中でクリップが変わった
    func updateClips(_ clips: [MusicClip], document: URL?) {
        if let m = music {
            m.update(clips: clips, document: document)
        } else if !clips.isEmpty, let m = MusicTimeline(clips: clips, document: document) {
            music = m
            m.set(time: timelineTime(at: Date()), playing: pausedAt == nil)
        }
    }

    /// タイムライン上の今の時刻（写真の位置 × 表示時間 + その写真での経過）
    func timelineTime(at date: Date) -> TimeInterval {
        guard let cur = current else { return 0 }
        let clock = pausedAt ?? date
        return Double(cur.index) * settings.dwell + min(settings.dwell, max(0, clock.timeIntervalSince(cur.start)))
    }

    /// タイムラインの時刻へ飛ぶ（その時刻の写真を出す）
    func jump(to time: TimeInterval) {
        guard count > 0, settings.dwell > 0 else { return }
        let i = min(count - 1, max(0, Int(time / settings.dwell)))
        show(i, direction: 1, manual: true, resync: true)
    }

    // MARK: 描画用

    /// 切り替えの進み具合 0→1（実時間。停止中でも切り替え自体は最後まで動く）
    func transitionProgress(at date: Date) -> Double {
        guard let cur = current else { return 1 }
        let d = settings.transitionDuration
        guard d > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(cur.start) / d))
    }

    /// Ken Burns の進み具合 0→1（停止中は止まる）
    func motionProgress(_ slide: Slide, at date: Date) -> Double {
        let clock = pausedAt ?? date
        let total = settings.dwell + settings.transitionDuration
        return min(1, max(0, clock.timeIntervalSince(slide.start) / total))
    }

    // MARK: 内部

    private func show(_ index: Int, direction: Int, manual: Bool, resync: Bool) {
        advanceTask?.cancel()
        showTask?.cancel()
        showTask = Task { [weak self] in
            guard let self else { return }
            let image = await loader.image(at: index)
            guard !Task.isCancelled else { return }
            guard let image else {
                // 読めない写真は飛ばす。全部だめなら終わる
                failures += 1
                if failures >= count { finish(); return }
                let n = count
                show(((index + direction) % n + n) % n, direction: direction, manual: manual, resync: resync)
                return
            }
            failures = 0
            let now = Date()
            if pausedAt != nil { pausedAt = now }   // 停止中に送ったら、新しい写真は出だしで止めておく
            previous = current
            current = Slide(index: index, url: urls[index], image: image, start: now, motion: .random())
            // 音楽は、最初・矢印で飛んだとき・最初に戻ったときだけ写真の位置に合わせ直す。自動送りでは触らない（毎回合わせると音が飛ぶ）
            if resync { music?.set(time: Double(index) * settings.dwell, playing: pausedAt == nil) }
            let loop = settings.loop
            Task { await self.loader.preload(around: index, loop: loop) }
            scheduleAdvance()
            flashHold(hud: manual)
            clearTask?.cancel()
            clearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds((self?.settings.transitionDuration ?? 0) + 0.1))
                guard !Task.isCancelled else { return }
                self?.previous = nil
            }
        }
    }

    private func scheduleAdvance() {
        advanceTask?.cancel()
        guard pausedAt == nil, let cur = current else { return }
        let remaining = max(0.05, settings.dwell - Date().timeIntervalSince(cur.start))
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.next(manual: false)
        }
    }

    /// 切り替え直後としばらくは（停止中でも）描画を続け、枚数表示も出す
    private func flashHold(hud: Bool) {
        hold = true
        showsHud = hud
        holdTask?.cancel()
        let secs = max(settings.transitionDuration, 1.8) + 0.2
        holdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(secs))
            guard !Task.isCancelled else { return }
            self?.hold = false
        }
    }

    private func finish() {
        stop()
        onFinish?()
    }
}
