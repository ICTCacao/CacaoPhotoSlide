import SwiftUI
import UniformTypeIdentifiers

extension TrackColors {
    static let palette: [Color] = [.orange, .teal, .purple, .green, .pink, .indigo, .mint, .brown]
    static func color(_ track: Int) -> Color { palette[max(0, track) % palette.count] }
}

/// DaVinci Resolve 風のタイムライン。上からルーラー・写真（V1）・タイトル（T）・音声（A）の各トラック、
/// 赤い再生ヘッド（ルーラーのクリック・ドラッグ、写真のクリックで動かす。再生は ▶ ボタンか Space）。写真はドラッグで並べ替え、横の拡大縮小。音声ファイルは落とした位置に置ける
struct AudioTimelineView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @State private var dragOrigin: [UUID: (start: TimeInterval, track: Int)] = [:]
    @State private var viewport: CGFloat = 0
    @State private var magnifyStart: Double?
    @State private var edgeDrag: (key: String, base: Double, pps: CGFloat)?
    @State private var moveDrag: (id: UUID, base: Double, pps: CGFloat, track: Int)?
    @State private var overlayDrag: (primary: UUID, pps: CGFloat, origins: [UUID: (start: TimeInterval, track: Int)])?   // V2 クリップを（まとめて）動かし中
    @State private var reorder: (from: Int, to: Int)?      // 写真をドラッグして並べ替え中（流す写真の中の番号）
    @State private var hoverTime: TimeInterval = 0    // 右クリックの対象を決めるための、マウスのある時刻

    private let labelWidth: CGFloat = 34
    private let rulerHeight: CGFloat = 18
    private let bandHeight: CGFloat = 40      // 写真（V1）のサムネイルを並べる帯
    private let titleLane: CGFloat = 18
    private let titleStep: CGFloat = 22
    private let clipHeight: CGFloat = 26
    private let laneGap: CGFloat = 6
    private var laneStep: CGFloat { clipHeight + laneGap }
    private let v2Lane: CGFloat = 26
    private let v2Step: CGFloat = 30
    // 上から: ルーラー・T（上ほど大きい番号）・V2 以上（上ほど大きい番号）・V1・A1、A2…
    private var tCount: Int { model.titleTrackCount }
    private var vCount: Int { model.overlayTrackCount }          // V2 以上のトラックの数
    private var tTop: CGFloat { rulerHeight + 4 }
    private var vTop: CGFloat { tTop + CGFloat(tCount) * titleStep + 4 }
    private var bandTop: CGFloat { vTop + CGFloat(vCount) * v2Step + 4 }      // V1（写真の帯）
    private var clipTop: CGFloat { bandTop + bandHeight + 6 }                 // A1
    private func titleY(_ track: Int) -> CGFloat { tTop + CGFloat(tCount - 1 - track) * titleStep }
    private func overlayY(_ track: Int) -> CGFloat { vTop + CGFloat(vCount - 1 - track) * v2Step }
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
                .task {
                    // 書類を開き直したとき、拡大していれば再生ヘッドが見える位置まで送る
                    try? await Task.sleep(for: .milliseconds(200))
                    if model.timelineZoom > 1.01 { proxy.scrollTo("playhead", anchor: .center) }
                }
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
        func label(_ text: String, _ color: Color, y: CGFloat, kind: AppModel.TrackKind?, index: Int = 0) -> some View {
            let ref = TrackRef(kind: kind, index: index)
            let st = model.trackSetting(ref)
            let off = kind == .audio ? st.muted : st.hidden
            return Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                .strikethrough(off)
                .opacity(off ? 0.4 : 1)
                .frame(width: labelWidth - 6, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.editingTrack = ref }
                .help("ダブルクリックで、このトラックの設定（透過率・音量など）")
                .contextMenu {
                    if let kind { trackMenu(kind, index) } else { v1TrackMenu() }
                }
                .offset(y: y)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(0..<tCount), id: \.self) { j in
                label("T\(j + 1)", .cyan, y: titleY(j) + 2, kind: .title, index: j)
            }
            ForEach(Array(0..<vCount), id: \.self) { j in
                label("V\(j + 2)", .indigo, y: overlayY(j) + 5, kind: .overlay, index: j)
            }
            label("V1", .accentColor, y: bandTop + bandHeight / 2 - 7, kind: nil)
            ForEach(Array(0..<model.trackCount), id: \.self) { lane in
                label("A\(lane + 1)", TrackColors.color(lane), y: laneY(lane) + 5, kind: .audio, index: lane)
            }
        }
        .frame(width: labelWidth, height: contentHeight, alignment: .topLeading)
    }

    /// 「トラックの設定…」と、非表示（ミュート）の切り替え
    @ViewBuilder
    private func trackSettingsMenu(_ ref: TrackRef) -> some View {
        let st = model.trackSetting(ref)
        Button("\(ref.name) トラックの設定…") { model.editingTrack = ref }
        if ref.kind == .audio {
            Button(st.muted ? "ミュートを解除" : "ミュート") { model.updateTrackSetting(ref) { $0.muted.toggle() } }
        } else {
            Button(st.hidden ? "表示する" : "非表示にする") { model.updateTrackSetting(ref) { $0.hidden.toggle() } }
        }
    }

    /// トラックの右クリックメニュー: 「○ トラックを削除」と「○ トラックを追加」（DaVinci Resolve と同じ）。削除は空のトラックだけ
    @ViewBuilder
    private func trackMenu(_ kind: AppModel.TrackKind, _ index: Int) -> some View {
        trackSettingsMenu(TrackRef(kind: kind, index: index))
        Divider()
        switch kind {
        case .title:
            Button("T\(index + 1) トラックを削除", role: .destructive) { model.removeTrack(.title, index) }
                .disabled(!model.isTrackEmpty(.title, index))
            Button("T\(model.titleTrackCount + 1) トラックを追加") { model.addTrack(.title) }
        case .overlay:
            Button("V\(index + 2) トラックを削除", role: .destructive) { model.removeTrack(.overlay, index) }
                .disabled(!model.isTrackEmpty(.overlay, index))
            Button("V\(model.overlayTrackCount + 2) トラックを追加") { model.addTrack(.overlay) }
        case .audio:
            Button("A\(index + 1) トラックを削除", role: .destructive) { model.removeTrack(.audio, index) }
                .disabled(!model.isTrackEmpty(.audio, index))
            Button("A\(model.trackCount + 1) トラックを追加") { model.addTrack(.audio) }
        }
    }

    /// V1（写真）の右クリックメニュー。V1 は消せない。V2 以上・T・A のトラックは、ここからも足せる
    @ViewBuilder
    private func v1TrackMenu() -> some View {
        trackSettingsMenu(TrackRef(kind: nil))
        Divider()
        Button("V1 トラックを削除", role: .destructive) {}.disabled(true)
        Button("V\(model.overlayTrackCount + 2) トラックを追加") { model.addTrack(.overlay) }
        Button("T\(model.titleTrackCount + 1) トラックを追加") { model.addTrack(.title) }
        Button("A\(model.trackCount + 1) トラックを追加") { model.addTrack(.audio) }
    }

    // MARK: タイムライン本体

    private func timelineContent(width w: CGFloat, proxy: ScrollViewProxy) -> some View {
        let timing = model.timing
        let urls = model.playURLs
        let total = max(timing.total, 0.001)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(targeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
            // ルーラーと段の下地は別の部品にして、クリップをドラッグしている間は描き直さない
            RulerView(bounds: timing.bounds, total: total,
                      lanes: (0..<model.trackCount).map { lane in model.clips.contains { $0.track == lane } },
                      rulerHeight: rulerHeight, bandTop: bandTop, bandHeight: bandHeight, clipTop: clipTop, laneStep: laneStep, clipHeight: clipHeight,
                      tRows: (0..<tCount).map { titleY($0) }, titleLane: titleLane,
                      vRows: (0..<vCount).map { overlayY($0) }, v2Lane: v2Lane)
                .equatable()
            thumbStrip(width: w, total: total, bounds: timing.bounds, urls: urls)
                .opacity(model.trackSetting(TrackRef(kind: nil)).hidden ? 0.35 : 1)
            overlayTrack(width: w, total: total, bounds: timing.bounds)
            titleTrack(width: w, total: total)
            ForEach(model.clips) { clip in
                clipBar(clip, width: w, total: total)
            }
            audioTrackRows(width: w)
            if model.clips.isEmpty, model.trackCount > 0 {
                Text("ここに音声ファイルをドロップ（置いた位置から鳴ります）")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: w)
                    .offset(y: laneY(0) + 5)
                    .allowsHitTesting(false)
            }
            rulerAndBand(width: w, total: total, timing: timing)
            durationHandles(width: w, total: total, timing: timing)
            playhead(width: w, total: total, proxy: proxy)
        }
        .contentShape(Rectangle())
        .onTapGesture { location in
            // 何もないところ（T・V2 以上・A の行の空き）を押すと、その時刻に再生ヘッドが動く。再生は ▶ ボタンか Space
            model.selectedClip = nil
            model.selectedOverlays = []
            model.scrub(to: Double(max(0, min(location.x, w)) / w) * total)
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers, location in
            let lane = min(model.trackCount - 1, max(0, Int((location.y - clipTop) / laneStep)))
            let inV2 = vCount > 0 && location.y >= vTop && location.y < vTop + CGFloat(vCount) * v2Step
            return handleDrop(providers, at: max(0, location.x / w) * total, track: lane, v2: inV2)
        }
    }

    /// 音声のトラックの行（右クリックでトラックの追加・削除）
    private func audioTrackRows(width w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(0..<model.trackCount), id: \.self) { lane in
                Color.clear
                    .frame(width: w, height: clipHeight)
                    .contentShape(Rectangle())
                    .contextMenu { trackMenu(.audio, lane) }
                    .offset(y: laneY(lane))
            }
        }
    }

    private func addTitleHere(_ time: TimeInterval, track: Int? = nil) {
        model.addTitle(at: time, track: track)
        model.showTitles = true       // 足したら、そのまま文字を決められるように
    }

    // MARK: 写真の右クリック（「写真」のタブのサムネイルと同じメニュー）

    @ViewBuilder
    private func photoMenu(timing: SlideTiming, time: TimeInterval) -> some View {
        v1TrackMenu()
        Divider()
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
            Divider()
            Button("ここに単色画像を追加…") { model.scrub(to: time); model.showColorCard = true }
            Button("ここにタイトルを追加…") { addTitleHere(time) }
        }
    }

    // MARK: ルーラー（スクラブ）と写真の帯（クリックで表示、ドラッグで並べ替え）

    private func rulerAndBand(width w: CGFloat, total: TimeInterval, timing: SlideTiming) -> some View {
        let bounds = timing.bounds
        func time(_ x: CGFloat) -> TimeInterval { Double(max(0, min(x, w)) / w) * total }
        return ZStack(alignment: .topLeading) {
            // ルーラー: ドラッグで再生ヘッドを動かす（表示だけ。再生は ▶ ボタンか Space）
            Color.clear
                .frame(width: w, height: rulerHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in model.scrub(to: time(v.location.x)) }
                )
                .help("クリック・ドラッグで再生ヘッドを動かす（再生は ▶ ボタンか Space）")
            // 写真の帯: クリックでその位置を表示、ドラッグで写真の順番を変える
            Color.clear
                .frame(width: w, height: bandHeight)
                .contentShape(Rectangle())
                .offset(y: bandTop)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if model.activeController != nil {          // 流している間は並べ替えず、スクラブだけ
                                model.scrub(to: time(v.location.x)); return
                            }
                            guard hypot(v.translation.width, v.translation.height) >= 4 else { return }
                            reorder = (timing.index(at: time(v.startLocation.x)), timing.index(at: time(v.location.x)))
                        }
                        .onEnded { v in
                            let r = reorder
                            reorder = nil
                            if let r, r.from != r.to {
                                model.moveTimelinePhoto(from: r.from, to: r.to)
                            } else if hypot(v.translation.width, v.translation.height) < 4 {
                                model.scrub(to: time(v.location.x))
                            }
                        }
                )
                .help("クリックでその写真を表示。ドラッグで順番を変える")
            if let r = reorder, bounds.indices.contains(r.from + 1), bounds.indices.contains(r.to + 1) {
                let x0 = CGFloat(bounds[r.from] / total) * w
                let x1 = CGFloat(bounds[r.from + 1] / total) * w
                Rectangle().fill(Color.accentColor.opacity(0.25))
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .frame(width: max(6, x1 - x0), height: bandHeight)
                    .offset(x: x0, y: bandTop)
                    .allowsHitTesting(false)
                // 落とす位置（後ろへ動かすなら相手の後ろ、前へなら相手の手前）
                let lx = CGFloat((r.to > r.from ? bounds[r.to + 1] : bounds[r.to]) / total) * w
                Rectangle().fill(Color.accentColor)
                    .frame(width: 3, height: bandHeight + 8)
                    .offset(x: max(0, lx - 1.5), y: bandTop - 4)
                    .allowsHitTesting(false)
            }
        }
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverTime = time(p.x) }
        }
        .contextMenu { photoMenu(timing: timing, time: hoverTime) }
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
            ZStack(alignment: .topLeading) {
                playheadMark(x: CGFloat(min(model.playhead, total) / total) * w, width: w)
                Color.clear.frame(width: 2, height: 2).id("playhead")
                    .offset(x: CGFloat(min(model.playhead, total) / total) * w)
            }
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
                        .offset(x: x1 - 8, y: bandTop)
                        .help("つまんで、この写真の表示時間を変える（\(ContentView.seconds(timing.dwells[k]))）")
                    }
                }
            }
        }
    }

    // MARK: V2 のクリップの右クリック（V1 の写真と同じ並び）

    @ViewBuilder
    private func overlayClipMenu(_ clip: OverlayClip) -> some View {
        let id = clip.id
        let n = model.selectedOverlays.contains(id) ? model.selectedOverlays.count : 1
        let ref = TrackRef(kind: .overlay, index: clip.track)
        trackSettingsMenu(ref)
        Divider()
        Button("V\(clip.track + 2) トラックを削除", role: .destructive) { model.removeTrack(.overlay, clip.track) }
            .disabled(!model.isTrackEmpty(.overlay, clip.track))
        Button("V\(model.overlayTrackCount + 2) トラックを追加") { model.addTrack(.overlay) }
        Button("T\(model.titleTrackCount + 1) トラックを追加") { model.addTrack(.title) }
        Button("A\(model.trackCount + 1) トラックを追加") { model.addTrack(.audio) }
        Divider()
        Button(n > 1 ? "選んだ \(n) 枚を外す" : "この写真を外す") {
            if !model.selectedOverlays.contains(id) { model.selectedOverlays = [id] }
            model.removeSelectedOverlays()
        }
        Button("表示時間・エフェクトを変える…") {
            if !model.selectedOverlays.contains(id) { model.selectedOverlays = [id] }
            model.editingOverlay = id
        }
        Button("拡大して見る") { model.viewerImagePath = clip.path }
        Divider()
        Button(n > 1 ? "選んだ \(n) 枚を複製" : "複製") {
            if !model.selectedOverlays.contains(id) { model.selectedOverlays = [id] }
            model.duplicateSelectedOverlays()
        }
        if n > 1 {
            Button("前のクリップの終わりにつなげて並べる") { model.packSelectedOverlays() }
        }
        Button("先頭へ移動") { model.updateOverlay(id) { $0.start = 0 } }
        Divider()
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clip.path)]) }
        Divider()
        Button("ここに単色画像を追加…") { model.showColorCard = true }
        Button("ここにタイトルを追加…") { addTitleHere(model.playhead) }
    }

    // MARK: V2（重ねる写真）のトラック

    private func overlayTrack(width w: CGFloat, total: TimeInterval, bounds: [TimeInterval]) -> some View {
        let layout = OverlayMath.layout(model.overlayClips)
        return ZStack(alignment: .topLeading) {
            // トラックごとの行。ライブラリから写真をドラッグして落とす場所（落とした位置が開始時刻）。右クリックでトラックの追加・削除
            ForEach(Array(0..<vCount), id: \.self) { t in
                Color.clear
                    .frame(width: w, height: v2Lane)
                    .contentShape(Rectangle())
                    .offset(y: overlayY(t))
                    .contextMenu { trackMenu(.overlay, t) }
                    .dropDestination(for: String.self) { items, location in
                        let paths = items.filter { $0.hasPrefix("v2:") }
                            .flatMap { $0.dropFirst(3).split(separator: "\n").map(String.init) }
                        guard !paths.isEmpty else { return false }
                        model.placeOverlays(paths, at: Double(max(0, location.x) / w) * total, track: t)
                        return true
                    }
            }
            if vCount > 0, model.overlayClips.isEmpty {
                Text("V2: 「写真」タブの V2 ライブラリから、ここへドラッグ（写真ファイルを直接落としても置けます）")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: w).offset(y: overlayY(0) + 5)
                    .allowsHitTesting(false)
            }
            ForEach(layout.order) { clip in
                overlayBar(clip, lane: layout.lanes[clip.id] ?? 0, width: w, total: total, bounds: bounds)
            }
        }
    }

    private func overlayBar(_ clip: OverlayClip, lane: Int, width w: CGFloat, total: TimeInterval, bounds: [TimeInterval]) -> some View {
        let s = min(max(0, clip.start), total)
        let end = min(clip.end, total)
        let bw = max(24, CGFloat((end - s) / total) * w)
        let selected = model.selectedOverlays.contains(clip.id)
        let id = clip.id
        let url = URL(fileURLWithPath: clip.path)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).fill(Color.indigo.opacity(selected ? 0.85 : 0.55 * max(0.4, clip.opacity)))
            RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.white.opacity(0.8) : Color.indigo, lineWidth: selected ? 2 : 1)
            HStack(spacing: 4) {
                if let cg = model.thumbnails[url] {
                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 30, height: v2Lane - 4).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 2)).opacity(max(0.35, clip.opacity))
                        .padding(.leading, 2)
                }
                Text(url.lastPathComponent).font(.caption2).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(Int((clip.opacity * 100).rounded()))%").font(.caption2).monospacedDigit().padding(.trailing, 10)
            }
            .foregroundStyle(.white)
        }
        .frame(width: bw, height: v2Lane)
        .overlay(alignment: .trailing) {
            edgeHandle(key: "ov\(id)", base: clip.duration, width: w, total: total, height: v2Lane) { v in
                model.updateOverlay(id) { $0.duration = max(0.3, (v * 10).rounded() / 10) }
            }
        }
        .offset(x: min(CGFloat(s / total) * w, max(0, w - bw)), y: overlayY(lane))
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if overlayDrag?.primary != id {
                        if !model.selectedOverlays.contains(id) { model.selectedOverlays = [id] }
                        var origins: [UUID: (start: TimeInterval, track: Int)] = [:]
                        for c in model.overlayClips where model.selectedOverlays.contains(c.id) { origins[c.id] = (c.start, c.track) }
                        overlayDrag = (id, w / CGFloat(total), origins)
                    }
                    guard let d = overlayDrag, let o = d.origins[id] else { return }
                    var delta = Double(v.translation.width / d.pps)
                    // 吸着（6px 以内）: 0 秒・写真の区切り・選んでいない V2 クリップの始まりと終わり（＝前のクリップの終わりにつなぐ）。
                    // つかんだクリップの始まりと終わりのどちらでも
                    var marks = bounds + [0]
                    for c in model.overlayClips where d.origins[c.id] == nil { marks.append(c.start); marks.append(c.end) }
                    let snap = Double(6 / d.pps)
                    let startPos = o.start + delta, endPos = startPos + clip.duration
                    var best: (dist: Double, adjust: Double)?
                    for m in marks {
                        for adj in [m - startPos, m - endPos] where abs(adj) <= snap && abs(adj) < (best?.dist ?? .infinity) {
                            best = (abs(adj), adj)
                        }
                    }
                    if let best { delta += best.adjust } else { delta = (delta * 10).rounded() / 10 }
                    delta = max(delta, -(d.origins.values.map(\.start).min() ?? 0))       // どれも 0 秒より前には行かない
                    // 上下で V のトラックを変える（上へドラッグすると番号の大きい、上のトラック）
                    let dTrack = -Int((v.translation.height / v2Step).rounded())
                    model.moveOverlays(d.origins, delta: delta, deltaTrack: dTrack, maxTrack: vCount - 1)
                }
                .onEnded { _ in overlayDrag = nil }
        )
        .onTapGesture(count: 2) { model.editingOverlay = id }
        .onTapGesture { location in
            model.selectOverlay(id, modifiers: NSEvent.modifierFlags)
            model.scrub(to: clip.start + Double(location.x / w) * total)      // 押した位置の時刻に、再生ヘッドも動かす
        }
        .contextMenu { overlayClipMenu(clip) }
        .opacity(model.trackSetting(TrackRef(kind: .overlay, index: clip.track)).hidden ? 0.4 : 1)
        .onAppear { model.requestThumbnail(url: url) }
        .help("\(url.lastPathComponent)　\(ExportSheet.clock(clip.start)) 〜 \(ExportSheet.clock(clip.end))　ドラッグで時刻、右端で長さ、ダブルクリックで設定")
    }

    // MARK: タイトルのトラック

    private func titleTrack(width w: CGFloat, total: TimeInterval) -> some View {
        ZStack(alignment: .topLeading) {
            // トラックごとの行。何もないところを右クリックで、その位置にタイトルを足せる／トラックを足す・消す
            ForEach(Array(0..<tCount), id: \.self) { t in
                Color.clear
                    .frame(width: w, height: titleLane)
                    .contentShape(Rectangle())
                    .offset(y: titleY(t))
                    .onContinuousHover { phase in
                        if case .active(let p) = phase { hoverTime = Double(p.x / w) * total }
                    }
                    .contextMenu {
                        Button("ここにタイトルを追加…") { addTitleHere(hoverTime, track: t) }
                        Button("再生ヘッドの位置にタイトルを追加…") { addTitleHere(model.playhead, track: t) }
                        Divider()
                        trackMenu(.title, t)
                    }
            }
            if model.titles.isEmpty {
                Text("T1: 右クリックで、タイトルを追加")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: w).offset(y: titleY(0) + 2)
                    .allowsHitTesting(false)
            }
            ForEach(model.titles) { item in titleBar(item, width: w, total: total) }
        }
    }

    private func titleBar(_ item: TitleItem, width w: CGFloat, total: TimeInterval) -> some View {
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
        .offset(x: min(CGFloat(s / total) * w, max(0, w - bw)), y: titleY(min(item.track, tCount - 1)))
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { v in
                    if moveDrag?.id != id { moveDrag = (id, item.start, w / CGFloat(total), item.track) }
                    if let d = moveDrag, let i = model.titles.firstIndex(where: { $0.id == id }) {
                        model.titles[i].start = max(0, ((d.base + Double(v.translation.width / d.pps)) * 10).rounded() / 10)
                        // 上下でトラックを変える（上へドラッグすると、番号の大きい、上のトラック）
                        model.titles[i].track = min(max(0, d.track - Int((v.translation.height / titleStep).rounded())), tCount - 1)
                    }
                }
                .onEnded { _ in moveDrag = nil }
        )
        .onTapGesture(count: 2) { model.selectedTitleIDs = [id]; model.showTitles = true }
        .onTapGesture { location in
            model.selectedTitleIDs = [id]
            model.scrub(to: item.start + Double(location.x / w) * total)
        }
        .contextMenu {
            Button("編集…") { model.selectedTitleIDs = [id]; model.showTitles = true }
            Button("複製") {
                var copy = item
                copy.id = UUID()
                copy.start = item.start + max(1, item.duration)
                model.titles.append(copy)
                model.selectedTitleIDs = [copy.id]
            }
            Divider()
            Button("削除", role: .destructive) { model.titles.removeAll { $0.id == id } }
        }
        .opacity(model.trackSetting(TrackRef(kind: .title, index: item.track)).hidden ? 0.4 : 1)
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
                .offset(x: tile.x, y: bandTop)
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
            Menu {
                Button("タイトル（再生ヘッドの位置）") { addTitleHere(model.playhead) }
                Button("単色画像…") { model.showColorCard = true }
                Divider()
                Button("音声…") { model.chooseMusic() }
            } label: {
                Label("追加", systemImage: "plus")
            }
            .controlSize(.small)
            .fixedSize()
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
        .opacity(model.trackSetting(TrackRef(kind: .audio, index: clip.track)).muted ? 0.4 : 1)
        .help("\(clip.name)　\(ExportSheet.clock(clip.start)) 〜 \(ExportSheet.clock(clip.end))　左右で位置、上下で段、両端をつまむと頭・終わりを削れます")
        .onTapGesture { location in
            model.selectedClip = clip.id
            model.scrub(to: clip.start + Double(location.x / w) * total)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { v in
                    if dragOrigin[clip.id] == nil {
                        dragOrigin[clip.id] = (clip.start, clip.track)
                        model.selectedClip = clip.id
                    }
                    let origin = dragOrigin[clip.id] ?? (clip.start, clip.track)
                    let snapSeconds = 6 / w * total
                    // 上下でトラックを変える
                    let lane = min(model.trackCount - 1, max(0, origin.track + Int((v.translation.height / laneStep).rounded())))
                    model.moveClip(clip.id, to: origin.start + Double(v.translation.width / w) * total, snap: snapSeconds, track: lane)
                }
                .onEnded { _ in
                    dragOrigin[clip.id] = nil
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
                    // 別のトラックへ（トラックは、A のトラックを右クリックして足す）
                    Picker("トラック", selection: Binding(get: { min(clip.track, model.trackCount - 1) }, set: { model.setTrack(id, $0) })) {
                        ForEach(0..<model.trackCount, id: \.self) { lane in
                            Label("A\(lane + 1)", systemImage: "circle.fill").tag(lane)
                                .foregroundStyle(TrackColors.color(lane))
                        }
                    }
                    .frame(width: 110)
                    .help("このクリップを別のトラックへ。A のトラックは右クリックで追加できます")
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

    private func handleDrop(_ providers: [NSItemProvider], at time: TimeInterval, track: Int, v2: Bool = false) -> Bool {
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
            if v2 {                                   // V2 の段に落とした写真は、V2 ライブラリに入れてその位置に置く
                model.importAndPlaceOverlays(urls.filter { !MusicClip.isAudio($0) }, at: time)
                return
            }
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
    let bandTop: CGFloat           // V1（写真の帯）の上端
    let bandHeight: CGFloat
    let clipTop: CGFloat
    let laneStep: CGFloat
    let clipHeight: CGFloat
    let tRows: [CGFloat]           // T のトラックの行の上端
    let titleLane: CGFloat
    let vRows: [CGFloat]           // V2 以上のトラックの行の上端
    let v2Lane: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let w = size.width
            // 写真の区切り（濃淡を交互に）。多いときは帯だけ
            let bandY = bandTop
            // T・V2 以上のトラックの行の下地（空でも、トラックがあるとわかるように）
            for y in tRows {
                ctx.fill(Path(roundedRect: CGRect(x: 4, y: y, width: size.width - 8, height: titleLane), cornerRadius: 4), with: .color(.secondary.opacity(0.08)))
            }
            for y in vRows {
                ctx.fill(Path(roundedRect: CGRect(x: 4, y: y, width: size.width - 8, height: v2Lane), cornerRadius: 4), with: .color(.indigo.opacity(0.10)))
            }
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
                ctx.stroke(Path { p in p.move(to: CGPoint(x: x, y: rulerHeight - 4)); p.addLine(to: CGPoint(x: x, y: rulerHeight)) },
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
