import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false
    @AppStorage("previewHeight") private var previewHeight = 300.0   // プレビューの画面の高さ（境目をドラッグして変える）
    @State private var splitStart: Double?
    @State private var dropTarget: Int?      // 並べ替えのドラッグで、差し込み先に光らせる写真

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: Bindable(model).tab) {
                ForEach(MainTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)
            .padding(.top, 14)
            Group {
                switch model.tab {
                case .photos:
                    dropZone
                        .padding(18)
                case .preview:
                    ScrollView(.vertical) { previewTab.padding(18) }
                case .settings:
                    ScrollView(.vertical) { settings(Bindable(model)).padding(18) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .onChange(of: model.tab) { old, new in
            // プレビューのタブを離れたら、そこで流していたものは止める
            if old == .preview, new != .preview, model.isPreviewing { model.stopSlideshow() }
        }
        .navigationTitle(model.documentTitle)
        .navigationSubtitle(model.documentURL == nil ? "" : "CacaoPhotoSlide 書類")
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in handleDrop(providers) }
        .sheet(isPresented: Bindable(model).showExport) {
            ExportSheet().environment(model)
        }
        .sheet(isPresented: Bindable(model).showOverrides) {
            PhotoOverrideSheet().environment(model)
        }
        .sheet(isPresented: Bindable(model).showTitles) {
            TitlesSheet().environment(model)
        }
        .sheet(isPresented: Binding(
            get: { model.viewerIndex != nil },
            set: { if !$0 { model.viewerIndex = nil } })
        ) {
            PhotoViewerView().environment(model)
        }
    }

    // MARK: ドロップ先

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(targeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
            if model.photos.isEmpty && !model.isScanning {
                emptyState
            } else {
                photoSummary
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("ここに写真のフォルダをドロップ")
                .font(.title3)
            Text("音声ファイルや .cpsd 書類も落とせます")
                .font(.callout).foregroundStyle(.secondary)
            if let m = model.message {
                Text(m).foregroundStyle(.secondary)
            }
            Button("開く…") { model.openPanel() }
                .padding(.top, 4)
        }
    }

    private var photoSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(sourceTitle)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("読み込み中…").foregroundStyle(.secondary)
                } else {
                    Text("\(model.photos.count) 枚").monospacedDigit().fontWeight(.semibold)
                }
                if model.removedCount > 0 {
                    Button("外した \(model.removedCount) 枚を戻す") { model.restoreRemovedPhotos() }
                        .controlSize(.small)
                }
                Button {
                    model.openViewer()
                } label: {
                    Label("拡大表示", systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .disabled(model.photos.isEmpty)
                .help("選んだ写真（なければ先頭）を大きく見る（⌘Y）")
                Button {
                    model.openOverrides()
                } label: {
                    Label("個別設定", systemImage: "slider.horizontal.3")
                }
                .controlSize(.small)
                .disabled(model.selection.isEmpty)
                .help("選んだ写真だけ、表示時間とエフェクトを変える")
                Button("開く…") { model.openPanel() }
            }
            HStack(spacing: 6) {
                if let label = model.selectionLabel {
                    Image(systemName: model.selection.count >= 2 ? "checkmark.circle.fill" : "play.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(label).lineLimit(1).truncationMode(.middle)
                    Button {
                        model.clearSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("選択を解除して、全部を最初から")
                } else {
                    Text("クリック: その写真から開始　⌘ / ⇧クリック: 複数を選んで、その写真だけを流す　ダブルクリック: すぐ開始　ドラッグ: 並べ替え　右クリック: 個別設定・写真を外す")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .font(.callout)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                    ForEach(model.photos.indices, id: \.self) { i in
                        thumbnailCell(i)
                    }
                }
                .padding(2)
            }
        }
        .padding(14)
    }

    private func thumbnailCell(_ i: Int) -> some View {
        let selected = model.selection.contains(i)
        let multi = model.selection.count >= 2
        return Button {
            model.click(i, modifiers: NSEvent.modifierFlags)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                if let cg = model.thumbnails[model.photos[i]] {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Image(systemName: multi ? "checkmark.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(3)
                }
            }
            .overlay(alignment: .topLeading) {
                if let o = model.overrides[model.photos[i].path], !o.isEmpty {
                    HStack(spacing: 2) {
                        Image(systemName: o.transition == nil ? "clock" : "wand.and.stars")
                        if let d = o.dwell { Text(d == d.rounded() ? "\(Int(d))s" : String(format: "%.1fs", d)) }
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(3)
                }
            }
            .overlay(alignment: .leading) {
                if dropTarget == i {
                    Capsule().fill(Color.accentColor).frame(width: 4, height: 64).offset(x: -5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(dragPayload(i))
        .dropDestination(for: String.self) { items, _ in
            let moved = items.flatMap { $0.split(separator: ",").compactMap { Int($0) } }
            model.movePhotos(moved, to: i)
            return !moved.isEmpty
        } isTargeted: { over in
            if over { dropTarget = i } else if dropTarget == i { dropTarget = nil }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if model.selection.count < 2 { model.selection = [i] }
            model.startSlideshow(from: i)
        })
        .help("\(i + 1) / \(model.photos.count)  \(model.photos[i].lastPathComponent)")
        .contextMenu {
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
        .onAppear { model.requestThumbnail(i) }
        .onDisappear { model.cancelThumbnail(i) }
    }

    /// ドラッグで運ぶ写真の番号（選んだ写真の 1 枚をつかんだら、選んだ写真ぜんぶ）
    private func dragPayload(_ i: Int) -> String {
        let idx = model.selection.contains(i) && model.selection.count >= 2 ? model.selection.sorted() : [i]
        return idx.map(String.init).joined(separator: ",")
    }

    private var sourceTitle: String {
        let names = model.sources.map(\.lastPathComponent)
        if names.count <= 2 { return names.joined(separator: "、") }
        return "\(names[0]) ほか \(names.count - 1) 件"
    }

    // MARK: プレビュー

    private var previewTab: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.black
                if model.isPreviewing, let c = model.activeController {
                    SlideshowView(controller: c)
                } else {
                    PreviewStill()
                    if !model.photos.isEmpty && !model.isScanning {
                        Button {
                            model.startPreview(at: model.timing.index(at: model.playhead))
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(radius: 6)
                        }
                        .buttonStyle(.plain)
                        .help("再生ヘッドの写真から、ここで流してみる（音声も鳴ります）")
                    } else {
                        Text("「写真」のタブで写真を開いてください").foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)
            .frame(height: CGFloat(previewHeight))
            splitter
            transport
            AudioTimelineView().environment(model)
        }
    }

    /// プレビューとタイムラインの境目。上下にドラッグしてプレビューの大きさを変える
    private var splitter: some View {
        ZStack {
            Rectangle().fill(Color.clear).frame(height: 12)
            Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 56, height: 4)
        }
        .contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    if splitStart == nil { splitStart = previewHeight }
                    previewHeight = min(900, max(120, (splitStart ?? previewHeight) + v.translation.height))
                }
                .onEnded { _ in splitStart = nil }
        )
        .help("上下にドラッグして、プレビューの大きさを変える")
    }

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                if model.isPreviewing, let c = model.activeController { c.previousSlide() } else { model.stepPlayhead(-1) }
            } label: { Image(systemName: "backward.end.fill") }
                .help("前の写真")
                .disabled(model.photos.isEmpty)
            if model.isPreviewing, let c = model.activeController {
                Button { c.togglePause() } label: {
                    Label(c.isPaused ? "再開" : "一時停止", systemImage: c.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 80)
                }
                .keyboardShortcut(.space, modifiers: [])
            } else {
                Button { model.startPreview(at: model.timing.index(at: model.playhead)) } label: {
                    Label("再生", systemImage: "play.fill").frame(width: 80)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.photos.isEmpty || model.isScanning || model.isShowing)
            }
            Button { model.stopSlideshow() } label: { Image(systemName: "stop.fill") }
                .disabled(!model.isPreviewing)
                .help("停止（今の位置に再生ヘッドが残ります）")
            Button {
                if model.isPreviewing, let c = model.activeController { c.next() } else { model.stepPlayhead(1) }
            } label: { Image(systemName: "forward.end.fill") }
                .help("次の写真")
                .disabled(model.photos.isEmpty)
            Group {
                if model.isPreviewing, let c = model.activeController {
                    TimelineView(.animation(paused: c.timelinePaused)) { ctx in
                        Text(ExportSheet.clock(c.timelineTime(at: ctx.date)))
                    }
                } else {
                    Text(ExportSheet.clock(model.playhead))
                }
            }
            .monospacedDigit()
            Text("/ \(ExportSheet.clock(model.totalDuration))").foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Text("\(model.playCount) 枚")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        return s >= 60 ? "\(s / 60) 分 \(s % 60) 秒" : "\(s) 秒"
    }

    // MARK: 設定

    private func settings(_ model: Bindable<AppModel>) -> some View {
        let choices = AppModel.dwellChoices
        let dwellIndex = Binding<Double>(
            get: {
                let d = model.dwell.wrappedValue
                let i = choices.indices.min { abs(choices[$0] - d) < abs(choices[$1] - d) } ?? 0
                return Double(i)
            },
            set: { model.dwell.wrappedValue = choices[Int($0.rounded())] })
        return Form {
            LabeledContent("表示時間") {
                HStack {
                    Slider(value: dwellIndex, in: 0...Double(choices.count - 1), step: 1)
                    Text(Self.seconds(model.dwell.wrappedValue))
                        .monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            Picker("切り替え", selection: model.transition) {
                ForEach(Transition.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("切り替えの長さ") {
                HStack {
                    Slider(value: model.transitionDuration, in: 0.3...3, step: 0.1)
                    Text(Self.seconds(min(model.transitionDuration.wrappedValue, model.dwell.wrappedValue)))
                        .monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            .disabled(model.transition.wrappedValue == .none)
            LabeledContent("最後のフェードアウト") {
                HStack {
                    Slider(value: model.endFade, in: 0...10, step: 0.5)
                    Text(model.endFade.wrappedValue == 0 ? "なし" : Self.seconds(model.endFade.wrappedValue))
                        .monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            .help("最後の写真が終わる、この秒数前から黒へ。「繰り返す」がオンのときは画面ではかかりません")
            LabeledContent("タイトルなど") {
                HStack {
                    Text(model.titles.wrappedValue.isEmpty ? "なし" : "\(model.titles.wrappedValue.count) 件")
                        .foregroundStyle(.secondary)
                    Button("編集…") { model.showTitles.wrappedValue = true }
                }
            }
            Picker("順番", selection: model.order) {
                ForEach(PhotoOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("手動: 写真をドラッグして並べた順。ドラッグすると自動で手動になります")
            Picker("表示", selection: model.fit) {
                ForEach(FitMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("表示先", selection: model.displayMode) {
                ForEach(DisplayMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 24) {
                Toggle("繰り返す", isOn: model.loop)
                Toggle("サブフォルダも含める", isOn: model.recursive)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: 426)
    }

    static func seconds(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v)) 秒" : String(format: "%.1f 秒", v)
    }

    // MARK: 下段

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Space  停止 / 再開　　←  →  前へ / 次へ")
                Text("Esc  終了")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            if let saving = model.savingMessage {
                ProgressView().controlSize(.small)
                Text(saving).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Button {
                model.showExport = true
            } label: {
                Label("mp4 に書き出す…", systemImage: "film")
            }
            .controlSize(.large)
            .disabled(model.photos.isEmpty || model.isScanning || model.isShowing)
            if model.isShowing, let c = model.activeController {
                Button {
                    c.togglePause()
                } label: {
                    Label(c.isPaused ? "再開" : "一時停止", systemImage: c.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 80)
                }
                .controlSize(.large)
                Button {
                    model.stopSlideshow()
                } label: {
                    Label("終了", systemImage: "stop.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    model.startSlideshow()
                } label: {
                    Label("スライドショーを開始", systemImage: "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.photos.isEmpty || model.isScanning)
            }
        }
    }

    // MARK: ドロップ

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let targets = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !targets.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in targets {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.load(urls)
        }
        return true
    }
}

/// プレビューで流していないときの静止画（再生ヘッドの位置の写真に、その時刻のタイトルを重ねて）
private struct PreviewStill: View {
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?

    private var url: URL? {
        let urls = model.playURLs
        guard !urls.isEmpty else { return nil }
        return urls[min(urls.count - 1, model.timing.index(at: model.playhead))]
    }

    private var fit: FitMode {
        let n = model.playURLs.count
        guard n > 0 else { return model.fit }
        return model.timing.fits[min(n - 1, model.timing.index(at: model.playhead))]
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: fit == .fill ? .fill : .fit)
            }
            // 出し始めの 0.5 秒のフェードを待たずに見えるよう、少し進めた時刻で描く
            TitleOverlay(items: model.titles, time: model.playhead + TitleMath.fade)
        }
        .clipped()
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await Task.detached(priority: .userInitiated) { ImageLoader.decode(url, maxPixel: 1280) }.value
        }
    }
}
