import SwiftUI
import UniformTypeIdentifiers

extension TrackColors {
    static let palette: [Color] = [.orange, .teal, .purple, .green, .pink, .indigo, .mint, .brown]
    static func color(_ track: Int) -> Color { palette[max(0, track) % palette.count] }
}

/// 所要時間のルーラーと写真の区切り、その下に音声クリップ。音声ファイルを落とした位置に置ける
struct AudioTimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var dragOrigin: [UUID: (start: TimeInterval, track: Int)] = [:]

    private let rulerHeight: CGFloat = 18
    private let bandHeight: CGFloat = 14
    private let clipHeight: CGFloat = 26
    private let clipTop: CGFloat = 36
    private let laneGap: CGFloat = 6
    private var laneStep: CGFloat { clipHeight + laneGap }
    private func laneY(_ track: Int) -> CGFloat { clipTop + CGFloat(track) * laneStep }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            GeometryReader { geo in
                let w = geo.size.width
                let total = max(model.totalDuration, 0.001)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
                    // ルーラーと段の下地は別の部品にして、クリップをドラッグしている間は描き直さない
                    RulerView(count: model.playCount, dwell: model.dwell, total: total,
                              lanes: (0..<model.trackCount).map { lane in model.clips.contains { $0.track == lane } },
                              rulerHeight: rulerHeight, bandHeight: bandHeight, clipTop: clipTop, laneStep: laneStep, clipHeight: clipHeight)
                        .equatable()
                    ForEach(model.clips) { clip in
                        clipBar(clip, width: w, total: total)
                    }
                    // 再生位置の線（流している間）
                    if let c = model.activeController {
                        TimelineView(.animation(paused: c.timelinePaused)) { ctx in
                            let x = CGFloat(c.timelineTime(at: ctx.date) / total) * w
                            Rectangle().fill(Color.red).frame(width: 2, height: geo.size.height)
                                .offset(x: min(max(0, x - 1), w - 2))
                            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 9)).foregroundStyle(.red)
                                .offset(x: min(max(0, x - 5), w - 10), y: -1)
                        }
                        .allowsHitTesting(false)
                    }
                    // 空の段の案内
                    let emptyLane = model.trackCount - 1
                    Text(model.clips.isEmpty ? "ここに音声ファイルをドロップ（置いた位置から鳴ります）" : "ここに落とすと新しいトラック（段を分ければ重ねて置けます）")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .offset(y: laneY(emptyLane) + 5)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    model.selectedClip = nil
                    // 流している間は、押した時刻の写真へ飛ぶ
                    if let c = model.activeController, location.y < clipTop {
                        c.jump(to: Double(location.x / w) * total)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $targeted) { providers, location in
                    let lane = min(model.trackCount - 1, max(0, Int((location.y - clipTop) / laneStep)))
                    return handleDrop(providers, at: max(0, location.x / w) * total, track: lane)
                }
            }
            .frame(height: clipTop + CGFloat(model.trackCount) * laneStep + 4)
            clipEditor
        }
    }

    // MARK: 見出し

    private var header: some View {
        HStack(spacing: 10) {
            Label("タイムライン", systemImage: "waveform")
                .fontWeight(.semibold)
            Text("所要時間 \(ExportSheet.clock(model.totalDuration))　（\(model.playCount) 枚 × \(ContentView.seconds(model.dwell))）")
                .foregroundStyle(.secondary)
            Spacer()
            Button("音声を追加…") { model.chooseMusic() }
                .controlSize(.small)
        }
        .font(.callout)
    }

    // MARK: ルーラーと写真の区切り（RulerView に分けた）

    static func clockShort(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: クリップ

    private func clipBar(_ clip: MusicClip, width w: CGFloat, total: TimeInterval) -> some View {
        let x0 = CGFloat(clip.start / total) * w
        let visible = max(0, min(clip.length, total - clip.start))
        let cw = max(24, CGFloat(visible / total) * w)
        let selected = model.selectedClip == clip.id
        let cut = clip.end > total + 0.01
        let color = TrackColors.color(clip.track)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? color.opacity(0.85) : color.opacity(0.55))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.primary.opacity(0.7) : color, lineWidth: selected ? 2 : 1)
            HStack(spacing: 4) {
                Image(systemName: "music.note").font(.system(size: 10))
                Text(clip.name).font(.caption).lineLimit(1)
                if cut { Image(systemName: "scissors").font(.system(size: 9)).help("スライドショーの終わりで切れます") }
            }
            .padding(.horizontal, 6)
            .foregroundStyle(.white)
        }
        .frame(width: cw, height: clipHeight)
        .overlay(alignment: .leading) {
            trimHandle(clip, width: w, total: total, head: true)
        }
        .overlay(alignment: .trailing) {
            if !cut { trimHandle(clip, width: w, total: total, head: false) }
        }
        .offset(x: min(x0, w - cw), y: laneY(clip.track))
        .help("\(clip.name)　\(ExportSheet.clock(clip.start)) 〜 \(ExportSheet.clock(clip.end))　左右で位置、上下で段、両端をつまむと頭・終わりを削れます")
        .onTapGesture { model.selectedClip = clip.id }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if dragOrigin[clip.id] == nil { dragOrigin[clip.id] = (clip.start, clip.track); model.selectedClip = clip.id }
                    let origin = dragOrigin[clip.id] ?? (clip.start, clip.track)
                    let snapSeconds = 6 / w * total
                    // 上下は、使っている段の範囲だけ（一番下の空の段は新しいファイルを落とすとき専用。動かしても段は増えない）
                    let lane = min(model.trackCount - 2, max(0, origin.track + Int((v.translation.height / laneStep).rounded())))
                    model.moveClip(clip.id, to: origin.start + Double(v.translation.width / w) * total, snap: snapSeconds, track: lane)
                }
                .onEnded { _ in dragOrigin[clip.id] = nil; model.compactTracks() }
        )
        .contextMenu {
            Button("削除") { model.removeClip(clip.id) }
        }
    }

    /// クリップの端のつまみ。左は頭を削る（音は同じ位置に留まる）、右は終わりを削る
    @State private var trimLast: CGFloat = 0
    private func trimHandle(_ clip: MusicClip, width w: CGFloat, total: TimeInterval, head: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8)
            .overlay(RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.7)).frame(width: 2, height: clipHeight - 10))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        let delta = Double((v.translation.width - trimLast) / w) * total
                        trimLast = v.translation.width
                        model.selectedClip = clip.id
                        if head {
                            model.trimHead(clip.id, by: delta)
                        } else {
                            model.updateClip(clip.id) { $0.outPoint = $0.effectiveOut + delta }
                        }
                    }
                    .onEnded { _ in trimLast = 0 }
            )
    }

    // MARK: 選んだクリップの編集

    @ViewBuilder private var clipEditor: some View {
        if let id = model.selectedClip, let clip = model.clips.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    Image(systemName: "music.note").foregroundStyle(TrackColors.color(clip.track))
                    Text(clip.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 200, alignment: .leading)
                        .help(clip.url(in: model.documentURL).path)
                    Button {
                        model.toggleAudition(id)
                    } label: {
                        Label(model.auditionID == id ? "停止" : "試聴", systemImage: model.auditionID == id ? "stop.fill" : "play.fill")
                            .frame(width: 44)
                    }
                    .help("このクリップの範囲だけを聴く")
                    Text("曲の長さ \(ExportSheet.clock(clip.duration))").foregroundStyle(.secondary)
                    secondsField("置く位置", value: clip.start) { model.moveClip(id, to: $0) }
                    HStack(spacing: 4) {
                        Text("音量")
                        Slider(value: Binding(get: { clip.volume }, set: { v in model.updateClip(id) { $0.volume = v } }), in: 0...1)
                            .frame(width: 90)
                        Text("\(Int((clip.volume * 100).rounded())) %").monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                    Spacer()
                    Button(role: .destructive) { model.removeClip(id) } label: { Image(systemName: "trash") }
                        .help("このクリップを外す")
                }
                ClipRangeView(clip: clip).environment(model)
                HStack(spacing: 14) {
                    Text("曲の範囲").foregroundStyle(.secondary).fixedSize()
                    secondsField("開始位置", value: clip.inPoint) { v in model.updateClip(id) { $0.inPoint = v } }
                    Text("〜")
                    secondsField("終了位置", value: clip.effectiveOut) { v in model.updateClip(id) { $0.outPoint = v } }
                    Text("（使う長さ \(ExportSheet.clock(clip.length))）").foregroundStyle(.secondary).fixedSize()
                    Divider().frame(height: 14)
                    HStack(spacing: 4) {
                        Text("フェードイン").fixedSize()
                        Stepper(value: Binding(get: { clip.fadeIn }, set: { v in model.updateClip(id) { $0.fadeIn = v } }), in: 0...30, step: 0.5) {
                            Text(ContentView.seconds(clip.fadeIn)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    HStack(spacing: 4) {
                        Text("アウト").fixedSize()
                        Stepper(value: Binding(get: { clip.fadeOut }, set: { v in model.updateClip(id) { $0.fadeOut = v } }), in: 0...30, step: 0.5) {
                            Text(ContentView.seconds(clip.fadeOut)).monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Spacer()
                }
            }
            .font(.callout)
            .controlSize(.small)
        } else {
            Text(model.clips.isEmpty
                 ? "音声はタイムラインに落とすか「音声を追加…」。何本でも重ねられ、ドラッグで位置を変えられます"
                 : "クリップをクリックすると、置く位置・曲の範囲（開始位置〜終了位置）・音量・フェードイン／アウトを直せます")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 「ラベル [ 12.3 ] 秒」の入力欄
    private func secondsField(_ label: String, value: TimeInterval, set: @escaping (TimeInterval) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
            TextField("", value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
            Text("秒")
        }
    }

    // MARK: ドロップ

    private func handleDrop(_ providers: [NSItemProvider], at time: TimeInterval, track: Int) -> Bool {
        let targets = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !targets.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in targets {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let audio = urls.filter { MusicClip.isAudio($0) }
            if audio.isEmpty { model.load(urls) } else { for a in audio { model.addClip(url: a, at: time, track: track) } }
        }
        return true
    }
}

/// 時間の目盛り・写真の区切り・段の下地。入力が同じなら描き直さない
struct RulerView: View, Equatable {
    let count: Int
    let dwell: Double
    let total: TimeInterval
    let lanes: [Bool]            // 段ごとに、クリップがあるか
    let rulerHeight: CGFloat
    let bandHeight: CGFloat
    let clipTop: CGFloat
    let laneStep: CGFloat
    let clipHeight: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            // 写真の区切り（濃淡を交互に）。多いときは帯だけ
            let bandY = rulerHeight
            if count > 0, count <= 600, dwell > 0 {
                for k in 0..<count {
                    let x0 = CGFloat(Double(k) * dwell / total) * w
                    let x1 = CGFloat(Double(k + 1) * dwell / total) * w
                    let rect = CGRect(x: x0, y: bandY, width: max(0.5, x1 - x0), height: bandHeight)
                    ctx.fill(Path(rect), with: .color(k.isMultiple(of: 2) ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.2)))
                }
            } else {
                ctx.fill(Path(CGRect(x: 0, y: bandY, width: w, height: bandHeight)), with: .color(Color.accentColor.opacity(0.3)))
            }
            // 時間の目盛り
            let step = Self.tickStep(total: total, width: w)
            var t: TimeInterval = 0
            while t <= total + 0.001 {
                let x = CGFloat(t / total) * w
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: rulerHeight - 4)); p.addLine(to: CGPoint(x: x, y: rulerHeight + bandHeight)) },
                           with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                let label = Text(AudioTimelineView.clockShort(t)).font(.system(size: 9)).foregroundStyle(.secondary)
                let resolved = ctx.resolve(label)
                let ls = resolved.measure(in: CGSize(width: 60, height: 12))
                var lx = x + 2
                if lx + ls.width > w { lx = x - ls.width - 2 }
                ctx.draw(resolved, at: CGPoint(x: lx, y: 1), anchor: .topLeading)
                t += step
            }
            // 段の下地（空の段は点線）
            for (lane, used) in lanes.enumerated() {
                let rect = CGRect(x: 4, y: clipTop + CGFloat(lane) * laneStep - 2, width: size.width - 8, height: clipHeight + 4)
                let path = Path(roundedRect: rect, cornerRadius: 6)
                if used {
                    ctx.fill(path, with: .color(.secondary.opacity(0.06)))
                } else {
                    ctx.stroke(path, with: .color(.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
    }

    private static func tickStep(total: TimeInterval, width: CGFloat) -> TimeInterval {
        let candidates: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600]
        let minPx: CGFloat = 56
        for c in candidates where CGFloat(c / total) * width >= minPx { return c }
        return candidates.last!
    }
}
