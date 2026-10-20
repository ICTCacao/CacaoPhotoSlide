import AVFoundation
import Foundation

/// 全画面のスライドショーで、タイムラインの時刻に合わせてクリップを鳴らす
@MainActor
final class MusicTimeline {
    private struct Item {
        var clip: MusicClip
        let player: AVAudioPlayer
        var needsSeek = false
        var seekAfter = Date.distantPast     // ドラッグ中は合わせ直しを待つ（止まってから 1 回だけ）
    }
    private var items: [Item] = []
    private var base: TimeInterval = 0
    private var baseDate = Date()
    private var playing = false
    private var timer: Timer?
    private var stopped = false

    init?(clips: [MusicClip], document: URL?) {
        for clip in clips {
            guard let p = try? AVAudioPlayer(contentsOf: clip.url(in: document)) else { continue }
            p.prepareToPlay()
            items.append(Item(clip: clip, player: p))
        }
        if items.isEmpty { return nil }
    }

    var time: TimeInterval { playing ? base + Date().timeIntervalSince(baseDate) : base }

    /// 時刻を合わせ直す（最初・矢印で飛んだとき・最初に戻ったとき）。鳴っている曲はここで頭出しする
    func set(time t: TimeInterval, playing p: Bool) {
        base = t
        baseDate = Date()
        playing = p
        for item in items where item.player.isPlaying { item.player.pause() }
        tick(seek: true)
        restartTimer()
    }

    /// クリップが変わった（流している途中でドラッグした等）。変わったものだけ位置を合わせ直す
    func update(clips: [MusicClip], document: URL?) {
        guard !stopped else { return }
        var newItems: [Item] = []
        for clip in clips {
            if let old = items.first(where: { $0.clip.id == clip.id }), old.clip.path == clip.path {
                let moved = old.clip.start != clip.start || old.clip.inPoint != clip.inPoint || old.clip.effectiveOut != clip.effectiveOut
                var item = Item(clip: clip, player: old.player, needsSeek: old.needsSeek || moved, seekAfter: old.seekAfter)
                if moved { item.seekAfter = Date().addingTimeInterval(0.15) }
                newItems.append(item)
            } else if let p = try? AVAudioPlayer(contentsOf: clip.url(in: document)) {
                p.prepareToPlay()
                newItems.append(Item(clip: clip, player: p, needsSeek: true))
            }
        }
        for old in items where !newItems.contains(where: { $0.player === old.player }) { old.player.stop() }
        items = newItems
        // 描画を止めないよう、ここでは音を触らない（次の tick で合わせる）
    }

    func pause() {
        base = time
        baseDate = Date()
        playing = false
        for item in items where item.player.isPlaying { item.player.pause() }
        restartTimer()
    }

    /// 止めたところから続ける（曲の位置はプレイヤーが覚えている）
    func resume() {
        baseDate = Date()
        playing = true
        tick(seek: false)
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil
        guard playing else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(seek: false) }
        }
    }

    /// 短くフェードアウトして止める
    func stop(fade: TimeInterval = 0.8) {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        let players = items.map(\.player)
        items = []
        for p in players where p.isPlaying { p.setVolume(0, fadeDuration: fade) }
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.05) { for p in players { p.stop() } }
    }

    /// 鳴っている曲の位置は触らない（毎回合わせると音が飛ぶ）。鳴らし始めるときだけ頭出しする
    private func tick(seek: Bool) {
        guard !stopped else { return }
        let t = time
        for i in items.indices {
            let c = items[i].clip, p = items[i].player
            let local = t - c.start                 // クリップの中の経過秒
            guard local >= 0, local < c.length else {
                if p.isPlaying { p.stop() }
                p.currentTime = c.inPoint
                continue
            }
            var v = c.volume
            if c.fadeIn > 0 { v *= min(1, local / c.fadeIn) }
            if c.fadeOut > 0 { v *= min(1, (c.length - local) / c.fadeOut) }
            p.volume = Float(max(0, v))
            guard playing else { continue }
            let want = c.inPoint + local
            if !p.isPlaying {
                // 鳴らし始め（または飛んだ直後）だけ位置を合わせる。曲の中の開始位置ぶんずらす
                if seek || items[i].needsSeek || abs(p.currentTime - want) > 1.0 { p.currentTime = want }
                p.play()
                items[i].needsSeek = false
            } else if items[i].needsSeek, Date() >= items[i].seekAfter {
                // 鳴っている最中に動かされた → 動かし終わってから、そのクリップだけ位置を合わせ直す
                p.currentTime = want
                items[i].needsSeek = false
            }
        }
    }
}
