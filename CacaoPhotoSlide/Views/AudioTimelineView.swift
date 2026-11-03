import SwiftUI
import UniformTypeIdentifiers

extension TrackColors {
    static let palette: [Color] = [.orange, .teal, .purple, .green, .pink, .indigo, .mint, .brown]
    static func color(_ track: Int) -> Color { palette[max(0, track) % palette.count] }
}

/// DaVinci Resolve 風のタイムライン。上からルーラー・写真（V1）・タイトル（T）・音声（A）の各トラック、
/// 赤い再生ヘッド（ルーラーと写真の帯をドラッグでスクラブ、クリックでそこから再生）、横の拡大縮小。音声ファイルは落とした位置に置ける
struct AudioTimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var dragOrigin: [UUID: (start: TimeInterval, track: Int)] = [:]
    @State private var viewport: CGFloat = 0
    @State private var magnifyStart: Double?
    @State private var edgeDrag: (key: String, base: Double, pps: CGFloat)?
    @State private var moveDrag: (id: UUID, base: Double, pps: CGFloat)?
    @State private var hoverTime: TimeInterval = 0    // 右クリックの対象を決めるための、マウスのある時刻

    private let labelWidth: CGFloat = 34
    private let rulerHeight: CGFloat = 18
    private let bandHeight: CGFloat = 40      // 写真（V1）のサムネイルを並べる帯
    private let titleLane: CGFloat = 18
    private let titleStep: CGFloat = 22
    private let clipHeight: CGFloat = 26
    private let laneGap: CGFloat = 6
    private var laneStep: CGFloat { clipHeight + laneGap }
    private var titleTop: CGFloat { rulerHeight + bandHeight + 6 }
    private var titleRows: Int { max(1, model.titles.count) }
    private var clipTop: CGFloat { titleTop + CGFloat(titleRows) * titleStep + 4 }
    private func laneY(_ track: Int) -> CGFloat { clipTop + CGFloat(track) * laneStep }
    private var contentHeight: CGFloat { clipTop + CGFloat(model.trackCount) * laneStep + 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(alignment: .top, spacing: 0) {
                trackLabels
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        let w = max(100, viewport) * CGFloat(model.timelineZoom)
                        timelineContent(width: w, proxy: proxy)
                            .frame(width: w, height: contentHeight)
                    }
                    .frame(height: contentHeight + (model.timelineZoom > 1.01 ? 14 : 0))
                    .simultaneousGesture(
                        MagnifyGesture()
                            .onChanged { v in
                                if magnifyStart == nil { magnifyStart = model.timelineZoom }
                                model.timelineZoom = min(24, max(1, (magnifyStart ?? 1) * v.magnification))
                            }
                            .onEnded { _ in magnifyStart = nil }
                    )
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { viewport = g.size.width }
                        .onChange(of: g.size.width) { _, new in viewport = new }
                })
            }
            clipEditor
        }
    }

    // MARK: トラック名（左の固定の列）

    private var trackLabels: some View {
        func label(_ text: String, _ color: Color) -> some View {
            Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                .frame(width: labelWidth - 6, alignment: .trailing)
        }
        return ZStack(alignment: .topLeading) {
            label("V1", .accentColor).offset(y: rulerHeight + bandHeight / 2 - 7)
            ForEach(Array(0..<titleRows), id: \.self) { j in
                label("T\(j + 1)", .cyan).offset(y: titleTop + CGFloat(j) * titleStep + 2)
            }
            ForEach(Array(0..<model.trackCount), id: \.self) { lane in
                label("A\(lane + 1)", TrackColors.color(lane)).offset(y: laneY(lane) + 5)
            }
        }
        .frame(width: labelWidth, height: contentHeight, alignment: .topLeading)
    }

    // MARK: タイムライン本体

    private func timelineContent(width w: CGFloat, proxy: ScrollViewProxy) -> some View {
        let timing = model.timing
        let urls = model.playURLs
        let total = max(timing.total, 0.001)
        let scrubHeight = rulerHeight + bandHeight
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
            // ルーラーと段の下地は別の部品にして、クリップをドラッグしている間は描き直さない
            RulerView(bounds: timing.bounds, total: total,
                      lanes: (0..<model.trackCount).map { lane in model.clips.contains { $0.track == lane } },
                      rulerHeight: rulerHeight, bandHeight: bandHeight, clipTop: clipTop, laneStep: laneStep, clipHeight: clipHeight)
                .equatable()
            thumbStrip(width: w, total: total, bounds: timing.bounds, urls: urls)
            titleTrack(width: w, total: total)
            ForEach(model.clips) { clip in
                clipBar(clip, width: w, total: total)
            }
            // 空の段の案内
            let emptyLane = model.trackCount - 1
            Text(model.clips.isEmpty ? "ここに音声ファイルをドロップ（置いた位置から鳴ります）" : "ここに落とすと新しいトラック（ファイルでも、置いてあるクリップでも）")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: w)
                .offset(y: laneY(emptyLane) + 5)
                .allowsHitTesting(false)
            // ルーラーと写真の帯: ドラッグで再生ヘッドを動かす（スクラブ）。クリックなら、そこから再生
            Color.clear
                .frame(width: w, height: scrubHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in model.scrub(to: Double(v.location.x / w) * total) }
                        .onEnded { v in
                            guard hypot(v.translation.width, v.translation.height) < 3, !model.isPreviewing, !model.isShowing else { return }
                            model.startPreview(at: timing.index(at: Double(v.location.x / w) * total))
                        }
                )
                .help("ドラッグで再生ヘッドを動かす。クリックでそこから再生")
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hoverTime = Double(p.x / w) * total }
                }
                .contextMenu { photoMenu(timing: timing, time: hoverTime) }
            durationHandles(width: w, total: total, timing: timing)
            playhead(width: w, total: total, proxy: proxy)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedClip = nil }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers, location in
            let lane = min(model.trackCount - 1, max(0, Int((location.y - clipTop) / laneStep)))
            return handleDrop(providers, at: max(0, location.x / w) * total, track: lane)
        }
    }

    // MARK: 写真の右クリック（「写真」のタブのサムネイルと同じメニュー）

    @ViewBuilder
    private func photoMenu(timing: SlideTiming, time: TimeInterval) -> some View {
        if let i = model.photoIndex(playIndex: timing.index(at: time)) {
            if model.selection.contains(i), model.selection.count >= 2 {
                Button("選んだ \(model.selection.count) 枚を外す") { model.removeSelectedPhotos() }
            } else {
                Button("この写真を外す") { model.removePhoto(i) }
            }
            Button("表示時間・エフェクトを変える…") { model.openOverrides(for: i) }
            Button("拡大して見る") { model.showViewer(i) }
            Divider()
            let targets = model.selection.contains(i) ? model.selection.sorted() : [i]
            Button("先頭へ移動") { model.moveToEdge(targets, front: true) }
            Button("最後へ移動") { model.moveToEdge(targets, front: false) }
            Divider()
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([model.photos[i]]) }
        }
    }

    // MARK: 再生ヘッド

    @ViewBuilder
    private func playhead(width w: CGFloat, total: TimeInterval, proxy: ScrollViewProxy) -> some View {
        if let c = model.activeController {
            TimelineView(.animation(paused: c.timelinePaused)) { ctx in
                playheadMark(x: CGFloat(c.timelineTime(at: ctx.date) / total) * w, width: w)
            }
            .allowsHitTesting(false)
            // 拡大しているとき、流している間は再生ヘッドが見える位置へ送る
            if model.timelineZoom > 1.01, !c.timelinePaused {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    Color.clear.frame(width: 2, height: 2).id("playhead")
                        .offset(x: CGFloat(c.timelineTime(at: ctx.date) / total) * w)
                        .task(id: ctx.date) {
                            withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("playhead", anchor: .center) }
                        }
                }
                .allowsHitTesting(false)
            }
        } else {
            playheadMark(x: CGFloat(min(model.playhead, total) / total) * w, width: w)
                .allowsHitTesting(false)
        }
    }

    private func playheadMark(x: CGFloat, width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.red).frame(width: 2, height: contentHeight)
                .offset(x: min(max(0, x - 1), w - 2))
            Image(systemName: "arrowtriangle.down.fill").font(.system(size: 10)).foregroundStyle(.red)
                .offset(x: min(max(0, x - 5), w - 10), y: -1)
        }
    }

    // MARK: 端をつまむ（写真の長さ・タイトルの長さ）

    private func edgeHandle(key: String, base: Double, width w: CGFloat, total: TimeInterval, height: CGFloat,
                            apply: @escaping (Double) -> Void) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8, height: height)
            .overlay(Capsule().fill(Color.white.opacity(0.85)).frame(width: 3, height: max(6, height - 10)))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if edgeDrag?.key != key { edgeDrag = (key, base, w / CGFloat(total)) }
                        if let d = edgeDrag { apply(d.base + Double(v.translation.width / d.pps)) }
                    }
                    .onEnded { _ in edgeDrag = nil }
            )
    }

    /// 写真の右端をつまんで、その写真の表示時間を変える（個別設定になり、後ろの写真は詰まる／ずれる）
    private func durationHandles(width w: CGFloat, total: TimeInterval, timing: SlideTiming) -> some View {
        let bounds = timing.bounds
        return ZStack(alignment: .topLeading) {
            if timing.count <= 600 {
                ForEach(0..<timing.count, id: \.self) { k in
                    let x1 = CGFloat(bounds[k + 1] / total) * w
                    if CGFloat((bounds[k + 1] - bounds[k]) / total) * w >= 14 {
                        edgeHandle(key: "photo\(k)", base: timing.dwells[k], width: w, total: total, height: bandHeight) { v in
                            model.setPhotoDwell(playIndex: k, dwell: max(0.3, (v * 10).rounded() / 10))
                        }
                        .offset(x: x1 - 8, y: rulerHeight)
                        .help("つまんで、この写真の表示時間を変える（\(ContentView.seconds(timing.dwells[k]))）")
                    }
                }
            }
        }
    }

    // MARK: タイトルのトラック

    private func titleTrack(width w: CGFloat, total: TimeInterval) -> some View {
        ZStack(alignment: .topLeading) {
            if model.titles.isEmpty {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: w - 8, height: titleLane)
                    .offset(x: 4, y: titleTop)
                Text("ここをクリックで、再生ヘッドの位置にタイトルを足す")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: w).offset(y: titleTop + 2)
                    .allowsHitTesting(false)
                Color.clear.frame(width: w - 8, height: titleLane).contentShape(Rectangle())
                    .offset(x: 4, y: titleTop)
                    .onTapGesture { model.addTitle(at: model.playhead) }
            }
            ForEach(model.titles) { item in titleBar(item, width: w, total: total) }
        }
    }

    private func titleBar(_ item: TitleItem, width w: CGFloat, total: TimeInterval) -> some View {
        let j = model.titles.firstIndex(where: { $0.id == item.id }) ?? 0
        let s = min(max(0, item.start), total)
        let end = item.duration > 0 ? min(item.start + item.duration, total) : total
        let bw = max(24, CGFloat((end - s) / total) * w)
        let id = item.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.cyan.opacity(0.6))
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.cyan, lineWidth: 1)
            HStack(spacing: 3) {
                Image(systemName: "textformat").font(.system(size: 9))
                Text(item.text.components(separatedBy: "\n").first ?? "").font(.caption2).lineLimit(1)
            }
            .padding(.horizontal, 5)
            .foregroundStyle(.white)
        }
        .frame(width: bw, height: titleLane)
        .overlay(alignment: .trailing) {
            if item.duration > 0 {
                edgeHandle(key: "title\(id)", base: item.duration, width: w, total: total, height: titleLane) { v in
                    if let i = model.titles.firstIndex(where: { $0.id == id }) {
                        model.titles[i].duration = max(0.5, (v * 10).rounded() / 10)
                    }
                }
            }
        }
        .offset(x: min(CGFloat(s / total) * w, max(0, w - bw)), y: titleTop + CGFloat(j) * titleStep)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if moveDrag?.id != id { moveDrag = (id, item.start, w / CGFloat(total)) }
                    if let d = moveDrag, let i = model.titles.firstIndex(where: { $0.id == id }) {
                        model.titles[i].start = max(0, ((d.base + Double(v.translation.width / d.pps)) * 10).rounded() / 10)
                    }
                }
                .onEnded { _ in moveDrag = nil }
        )
        .onTapGesture(count: 2) { model.showTitles = true }
        .help("「\(item.text)」　ドラッグで出す時刻、右端で長さ。ダブルクリックで編集")
    }

    // MARK: 写真のサムネイル

    /// 写真の区切りに合わせてサムネイルを並べる。区切りが細いときは、重ならないように間引く
    private func thumbStrip(width w: CGFloat, total: TimeInterval, bounds: [TimeInterval], urls: [URL]) -> some View {
        let tw = bandHeight * 1.4
        var tiles: [(k: Int, x: CGFloat, width: CGFloat)] = []
        var lastEnd: CGFloat = -1
        if urls.count == bounds.count - 1, urls.count <= 5000 {
            for k in urls.indices {
                let x0 = CGFloat(bounds[k] / total) * w
                let x1 = CGFloat(bounds[k + 1] / total) * w
                if x1 - x0 >= tw {
                    tiles.append((k, x0, x1 - x0)); lastEnd = x1
                } else if x0 >= lastEnd - 0.5, w - x0 >= 8 {
                    tiles.append((k, x0, min(tw, w - x0))); lastEnd = x0 + tw
                }
            }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(tiles, id: \.k) { tile in
                let url = urls[tile.k]
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(Color.secondary.opacity(0.2))
                    if let cg = model.thumbnails[url] {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: tile.width, height: bandHeight)
                            .clipped()
                    }
                    Text("\(tile.k + 1)")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 3)
                        .background(.black.opacity(0.55))
                        .foregroundStyle(.white)
                }
                .frame(width: tile.width, height: bandHeight)
                .clipped()
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5))
                .offset(x: tile.x, y: rulerHeight)
                .onAppear {
                    if let i = model.photos.firstIndex(of: url) { model.requestThumbnail(i) }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: 見出し

    private var header: some View {
        HStack(spacing: 10) {
            Label("タイムライン", systemImage: "waveform")
                .fontWeight(.semibold)
            Text("所要時間 \(ExportSheet.clock(model.totalDuration))　（\(model.playSummary)）")
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 4) {
                Button { model.timelineZoom = max(1, model.timelineZoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.borderless).help("縮小")
                Slider(value: Binding(get: { log2(model.timelineZoom) }, set: { model.timelineZoom = pow(2, $0) }), in: 0...4.5)
                    .frame(width: 100)
                    .help("タイムラインの横の拡大率（ピンチでも）")
                Button { model.timelineZoom = min(24, model.timelineZoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.borderless).help("拡大")
                Button("全体") { model.timelineZoom = 1 }
                    .controlSize(.small).disabled(model.timelineZoom <= 1.01)
            }
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
                    if dragOrigin[clip.id] == nil {
                        dragOrigin[clip.id] = (clip.start, clip.track)
                        model.selectedClip = clip.id
                        model.frozenTrackCount = model.trackCount     // ドラッグ中は段の数を固定
                    }
                    let origin = dragOrigin[clip.id] ?? (clip.start, clip.track)
                    let snapSeconds = 6 / w * total
                    // 上下で段を変える。一番下の空の段に入れれば新しいトラック
                    let lane = min(model.trackCount - 1, max(0, origin.track + Int((v.translation.height / laneStep).rounded())))
                    model.moveClip(clip.id, to: origin.start + Double(v.translation.width / w) * total, snap: snapSeconds, track: lane)
                }
                .onEnded { _ in
                    dragOrigin[clip.id] = nil
                    model.frozenTrackCount = nil
                    model.compactTracks()       // 空いた段を詰めて、空の段を改めて 1 つ出す
                }
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
                    // 段（トラック）を変える。「新しいトラック」を選ぶと段が増える
                    let usedLanes = model.trackCount - 1
                    Picker("トラック", selection: Binding(get: { min(clip.track, usedLanes) }, set: { model.setTrack(id, $0) })) {
                        ForEach(0..<usedLanes, id: \.self) { lane in
                            Label("トラック \(lane + 1)", systemImage: "circle.fill").tag(lane)
                                .foregroundStyle(TrackColors.color(lane))
                        }
                        Divider()
                        Text("新しいトラック").tag(usedLanes)
                    }
                    .frame(width: 150)
                    .help("このクリップを別の段へ。「新しいトラック」で段を増やす")
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
    let bounds: [TimeInterval]     // 写真の区切り（写真の数 + 1 個）
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
            let count = bounds.count - 1
            if count > 0, count <= 600 {
                for k in 0..<count {
                    let x0 = CGFloat(bounds[k] / total) * w
                    let x1 = CGFloat(bounds[k + 1] / total) * w
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
