import SwiftUI
import AppKit
import AVFoundation

@Observable @MainActor
final class AppModel {
    private let ud = UserDefaults.standard

    var sources: [URL] = []           // 写真のフォルダやファイル
    var photos: [URL] = []
    var thumbnails: [URL: CGImage] = [:]   // 画面に見えた順に読む
    var removedPaths: Set<String> = []     // パネルで外した写真（流さず、書類にもコピーしない）
    var isScanning = false
    var message: String?
    var isShowing = false

    /// 選んだ写真。1 枚なら「そこから開始」、2 枚以上なら「その写真だけを流す」
    var selection: Set<Int> = []
    private var anchor: Int?           // ⇧クリックの起点
    private var pendingSelection: [String] = []   // 書類を開いた直後、写真を読み終えてから選択に戻す

    /// 音声のタイムライン。変わったら、流している最中ならその場で反映する
    var clips: [MusicClip] = [] {
        didSet { activeController?.updateClips(clips, document: documentURL) }
    }
    var selectedClip: UUID?

    /// 試聴（クリップの範囲だけを鳴らす）
    var auditionID: UUID?
    private var auditionPlayer: AVAudioPlayer?
    private var auditionTimer: Timer?
    var auditionTime: TimeInterval? { auditionPlayer?.currentTime }
    var waveforms: [String: [Float]] = [:]        // クリップの path → 波形
    private var waveformTasks: Set<String> = []

    /// 書類（.cpsd）。nil なら名称未設定
    var documentURL: URL?
    var savingMessage: String?         // 保存中の表示（写真のコピーに時間がかかるとき）
    private var includePhotosDefault = true

    var dwell: Double { didSet { ud.set(dwell, forKey: Prefs.dwell) } }
    var transition: Transition { didSet { ud.set(transition.rawValue, forKey: Prefs.transition) } }
    var transitionDuration: Double { didSet { ud.set(transitionDuration, forKey: Prefs.transitionDuration) } }
    var order: PhotoOrder { didSet { ud.set(order.rawValue, forKey: Prefs.order); if order != oldValue { rescan() } } }
    var loop: Bool { didSet { ud.set(loop, forKey: Prefs.loop) } }
    var recursive: Bool { didSet { ud.set(recursive, forKey: Prefs.recursive); if recursive != oldValue { rescan() } } }
    var fit: FitMode { didSet { ud.set(fit.rawValue, forKey: Prefs.fit) } }
    var exportSize: ExportSize { didSet { ud.set(exportSize.rawValue, forKey: Prefs.exportSize) } }
    var exportFps: Int { didSet { ud.set(exportFps, forKey: Prefs.exportFps) } }
    var displayMode: DisplayMode { didSet { ud.set(displayMode.rawValue, forKey: Prefs.displayMode) } }

    /// 流している最中のコントローラ（タイムラインの再生位置の線と、メイン窓のボタンに使う）
    var activeController: SlideshowController?

    /// 表示時間の選択肢（秒）
    static let dwellChoices: [Double] = [0.3, 0.5, 0.7, 1, 1.5, 2, 3, 4, 5, 7, 10, 15, 20, 30]

    // mp4 書き出し
    var showExport = false
    var exportJob: ExportJob?

    private var scanTask: Task<Void, Never>?
    private var thumbTasks: [URL: Task<Void, Never>] = [:]
    private var window: SlideshowWindow?
    private weak var returnWindow: NSWindow?

    init() {
        dwell = ud.object(forKey: Prefs.dwell) as? Double ?? 5
        transition = Transition(rawValue: ud.string(forKey: Prefs.transition) ?? "") ?? .kenBurns
        transitionDuration = ud.object(forKey: Prefs.transitionDuration) as? Double ?? 1.5
        order = PhotoOrder(rawValue: ud.string(forKey: Prefs.order) ?? "") ?? .name
        loop = ud.object(forKey: Prefs.loop) as? Bool ?? true
        recursive = ud.object(forKey: Prefs.recursive) as? Bool ?? true
        fit = FitMode(rawValue: ud.string(forKey: Prefs.fit) ?? "") ?? .fit
        exportSize = ExportSize(rawValue: ud.string(forKey: Prefs.exportSize) ?? "") ?? .hd1080
        exportFps = ud.object(forKey: Prefs.exportFps) as? Int ?? 30
        displayMode = DisplayMode(rawValue: ud.string(forKey: Prefs.displayMode) ?? "") ?? .fullScreen
    }

    // MARK: 受け取り

    /// 落とされたもの・開いたものを受け取る。.cpsd は書類として開き、音声はタイムラインの末尾へ、残りは写真に
    func load(_ urls: [URL]) {
        if let doc = urls.first(where: { ProjectDocument.isDocument($0) }) {
            openDocument(doc)
            return
        }
        let audio = urls.filter { MusicClip.isAudio($0) }
        for a in audio { addClip(url: a, at: nil) }
        let list = urls.filter { !MusicClip.isAudio($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !list.isEmpty else { return }
        setSources(list)
    }

    private func setSources(_ list: [URL]) {
        sources = list
        removedPaths = []
        ud.set(list.map(\.path), forKey: Prefs.lastSources)
        rescan()
    }

    /// 前回の書類かフォルダがまだあれば読み直す
    func restoreLast() {
        guard sources.isEmpty else { return }
        if let path = ud.string(forKey: Prefs.lastDocument), FileManager.default.fileExists(atPath: path) {
            openDocument(URL(fileURLWithPath: path))
            return
        }
        if let paths = ud.stringArray(forKey: Prefs.lastSources) {
            let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty { setSources(urls) }
        }
    }

    func rescan() {
        scanTask?.cancel()
        for t in thumbTasks.values { t.cancel() }
        thumbTasks = [:]
        thumbnails = [:]
        selection = []
        anchor = nil
        guard !sources.isEmpty else { photos = []; return }
        let srcs = sources, rec = recursive, ord = order
        isScanning = true
        message = nil
        scanTask = Task {
            let removed = removedPaths
            let list = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.collect(from: srcs, recursive: rec, order: ord).filter { !removed.contains($0.path) }
            }.value
            guard !Task.isCancelled else { return }
            photos = list
            isScanning = false
            message = list.isEmpty ? "写真が見つかりませんでした" : nil
            if !pendingSelection.isEmpty {
                let wanted = Set(pendingSelection)
                selection = Set(list.indices.filter { wanted.contains(list[$0].path) })
                pendingSelection = []
            }
        }
    }

    /// サムネイルが画面に出たら読む（読み終わったものは持っておく）
    func requestThumbnail(_ i: Int) {
        guard photos.indices.contains(i) else { return }
        let url = photos[i]
        guard thumbnails[url] == nil, thumbTasks[url] == nil else { return }
        thumbTasks[url] = Task { [weak self] in
            let img = await Task.detached(priority: .utility) { ImageLoader.decode(url, maxPixel: 128) }.value
            guard let self, !Task.isCancelled else { return }
            thumbTasks[url] = nil
            if let img { thumbnails[url] = img }
        }
    }

    func cancelThumbnail(_ i: Int) {
        guard photos.indices.contains(i) else { return }
        thumbTasks[photos[i]]?.cancel()
        thumbTasks[photos[i]] = nil
    }

    // MARK: 写真を外す

    /// その写真を外す。選んだ中の 1 枚なら、選んだ写真を全部外す
    func removePhoto(_ i: Int) {
        if selection.contains(i), selection.count >= 2 { removeSelectedPhotos() } else { removePhotos([i]) }
    }

    func removeSelectedPhotos() { removePhotos(Array(selection)) }

    private func removePhotos(_ indices: [Int]) {
        let set = Set(indices.filter { photos.indices.contains($0) })
        guard !set.isEmpty else { return }
        for i in set { removedPaths.insert(photos[i].path) }
        photos = photos.enumerated().filter { !set.contains($0.offset) }.map(\.element)
        selection = []
        anchor = nil
    }

    var removedCount: Int { removedPaths.count }

    func restoreRemovedPhotos() {
        guard !removedPaths.isEmpty else { return }
        removedPaths = []
        rescan()
    }

    // MARK: 写真の選択

    /// クリック: その 1 枚。⌘: 追加／解除。⇧: 起点からの範囲を追加
    func click(_ i: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
            anchor = i
        } else if modifiers.contains(.shift), let a = anchor {
            selection.formUnion(min(a, i)...max(a, i))
        } else {
            selection = [i]
            anchor = i
        }
    }

    func selectAll() { selection = Set(photos.indices) }

    func clearSelection() {
        selection = []
        anchor = nil
    }

    /// 見出しに出す文
    var selectionLabel: String? {
        if selection.count >= 2 { return "選んだ \(selection.count) 枚だけを流します" }
        guard let i = selection.first, photos.indices.contains(i) else { return nil }
        return "開始: \(i + 1) 枚目  \(photos[i].lastPathComponent)"
    }

    /// 流す写真と、何枚目から始めるか（順番がランダムなら、ここで混ぜる）
    func makePlaylist(startingAt preferred: Int? = nil) -> (urls: [URL], start: Int) {
        var list: [URL]
        var first = 0
        if selection.count >= 2 {
            let idx = selection.sorted()
            list = idx.map { photos[$0] }
            if let p = preferred, let k = idx.firstIndex(of: p) { first = k }
        } else {
            list = photos
            if let p = preferred ?? selection.first, photos.indices.contains(p) { first = p }
        }
        if order == .random {
            let startURL = list.isEmpty ? nil : list[first]
            list.shuffle()
            if preferred != nil || selection.count == 1, let u = startURL, let k = list.firstIndex(of: u) { list.swapAt(0, k) }
            first = 0
        }
        return (list, first)
    }

    /// 今の設定（切り替えは表示時間より長くしない）
    var slideshowSettings: SlideshowSettings {
        SlideshowSettings(
            dwell: dwell,
            transition: transition,
            transitionDuration: transition == .none ? 0 : min(transitionDuration, dwell),
            loop: loop,
            fit: fit,
            clips: clips,
            document: documentURL)
    }

    // MARK: 所要時間・タイムライン

    /// 流す枚数（選んだ写真だけなら、その枚数）
    var playCount: Int { selection.count >= 2 ? selection.count : photos.count }

    /// 所要時間（秒）。最後の黒へのフェードを含む
    var totalDuration: TimeInterval { VideoExporter.duration(count: playCount, settings: slideshowSettings) }

    /// 音声ファイルをタイムラインに置く。at が nil なら最後のクリップの後ろ（なければ 0 秒）。track は段
    func addClip(url: URL, at start: TimeInterval?, track: Int = 0) {
        let asset = AVURLAsset(url: url)
        Task { [weak self] in
            let d = (try? await asset.load(.duration))?.seconds ?? 0
            guard let self, d > 0.1 else { return }
            let s = start ?? (clips.map(\.end).max() ?? 0)
            var clip = MusicClip(name: url.lastPathComponent, path: url.path, start: max(0, s), duration: d)
            clip.track = max(0, track)
            clips.append(clip)
            selectedClip = clip.id
            if start == nil { resolveOverlaps() }   // Dock や「音声を追加…」から来たものは、重ならない段へ
        }
    }

    /// 段の数（使っている段 + 落とすための空の段 1 つ。最低 2 段）。ドラッグ中は固定して、段が次々に生えないようにする
    var trackCount: Int { frozenTrackCount ?? max(2, (clips.map(\.track).max() ?? -1) + 2) }
    var frozenTrackCount: Int?

    /// 同じ段で時間が重なっているクリップを、別の段に振り分ける（古い書類や、重ねて置いたとき）
    func resolveOverlaps() {
        var placed: [MusicClip] = []
        for c in clips.sorted(by: { $0.start < $1.start }) {
            var clip = c
            var lane = clip.track
            func overlaps(_ a: MusicClip, _ b: MusicClip) -> Bool { a.start < b.end && b.start < a.end }
            while placed.contains(where: { $0.track == lane && overlaps($0, clip) }) { lane += 1 }
            clip.track = lane
            placed.append(clip)
        }
        let byID = Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.track) })
        for i in clips.indices { clips[i].track = byID[clips[i].id] ?? clips[i].track }
    }

    /// クリップを別の段へ（lane が使っている段の数と同じなら新しい段）。空いた段は詰める
    func setTrack(_ id: UUID, _ lane: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].track = max(0, lane)
        compactTracks()
    }

    /// 使っていない段を詰める
    func compactTracks() {
        let used = Set(clips.map(\.track)).sorted()
        let map = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($0.element, $0.offset) })
        for i in clips.indices { clips[i].track = map[clips[i].track] ?? 0 }
    }

    /// クリップを動かす（写真の区切りに吸着できる）。track を渡すと段も変える
    func moveClip(_ id: UUID, to start: TimeInterval, snap: TimeInterval? = nil, track: Int? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var s = max(0, start)
        if let snap, dwell > 0 {
            let k = (s / dwell).rounded()
            if abs(k * dwell - s) <= snap { s = k * dwell }
            if abs(s) <= snap { s = 0 }
        }
        clips[i].start = s
        if let track { clips[i].track = max(0, track) }
    }

    func updateClip(_ id: UUID, _ change: (inout MusicClip) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        change(&clips[i])
        // 範囲は 0 ≤ 開始位置 < 終了位置 ≤ 曲の長さ に収める
        var c = clips[i]
        c.inPoint = min(max(0, c.inPoint), max(0, c.duration - 0.1))
        if let o = c.outPoint {
            c.outPoint = min(max(c.inPoint + 0.1, o), c.duration)
            if c.outPoint! >= c.duration - 0.001 { c.outPoint = nil }
        }
        c.fadeIn = max(0, min(c.fadeIn, c.length))
        c.fadeOut = max(0, min(c.fadeOut, c.length))
        clips[i] = c
    }

    func toggleAudition(_ id: UUID) {
        if auditionID == id { stopAudition(); return }
        stopAudition()
        guard let clip = clips.first(where: { $0.id == id }),
              let p = try? AVAudioPlayer(contentsOf: clip.url(in: documentURL)) else { return }
        p.currentTime = clip.inPoint
        p.volume = Float(clip.volume * (clip.fadeIn > 0 ? 0 : 1))
        p.play()
        auditionPlayer = p
        auditionID = id
        auditionTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.auditionTick() }
        }
    }

    private func auditionTick() {
        guard let p = auditionPlayer, let id = auditionID, let c = clips.first(where: { $0.id == id }) else { stopAudition(); return }
        let local = p.currentTime - c.inPoint
        guard p.isPlaying, local >= -0.05, local < c.length else { stopAudition(); return }
        var v = c.volume
        if c.fadeIn > 0 { v *= min(1, max(0, local) / c.fadeIn) }
        if c.fadeOut > 0 { v *= min(1, (c.length - local) / c.fadeOut) }
        p.volume = Float(max(0, v))
    }

    func stopAudition() {
        auditionTimer?.invalidate()
        auditionTimer = nil
        auditionPlayer?.stop()
        auditionPlayer = nil
        auditionID = nil
    }

    func removeClip(_ id: UUID) {
        if auditionID == id { stopAudition() }
        clips.removeAll { $0.id == id }
        if selectedClip == id { selectedClip = nil }
        compactTracks()
    }

    /// 波形をまだ読んでいなければ読む
    func requestWaveform(for clip: MusicClip) {
        let key = clip.path
        guard waveforms[key] == nil, !waveformTasks.contains(key) else { return }
        waveformTasks.insert(key)
        let url = clip.url(in: documentURL)
        Task { [weak self] in
            let peaks = await Task.detached(priority: .utility) { Waveform.peaks(url: url) }.value
            guard let self else { return }
            waveformTasks.remove(key)
            if let peaks { waveforms[key] = peaks }
        }
    }

    /// クリップの左端をつまんで頭を削る（音はタイムライン上の同じ位置に留まる）
    func trimHead(_ id: UUID, by delta: TimeInterval) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let c = clips[i]
        let newIn = min(max(0, c.inPoint + delta), c.effectiveOut - 0.1)
        let applied = newIn - c.inPoint
        updateClip(id) { $0.inPoint = newIn; $0.start = max(0, c.start + applied) }
    }

    func chooseMusic() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio]
        panel.message = "タイムラインに置く音声ファイルを選んでください"
        panel.prompt = "追加"
        if panel.runModal() == .OK { for u in panel.urls { addClip(url: u, at: nil) } }
    }

    // MARK: 書類（.cpsd）

    var documentTitle: String { documentURL?.deletingPathExtension().lastPathComponent ?? "名称未設定" }

    private var projectFile: ProjectFile {
        var f = ProjectFile()
        f.sources = sources.map(\.path)
        f.selection = selection.sorted().compactMap { photos.indices.contains($0) ? photos[$0].path : nil }
        f.dwell = dwell
        f.transition = transition.rawValue
        f.transitionDuration = transitionDuration
        f.order = order.rawValue
        f.loop = loop
        f.recursive = recursive
        f.fit = fit.rawValue
        f.exportSize = exportSize.rawValue
        f.exportFps = exportFps
        f.clips = clips
        f.excluded = Array(removedPaths).sorted()
        return f
    }

    func newDocument() {
        documentURL = nil
        ud.removeObject(forKey: Prefs.lastDocument)
        removedPaths = []
        clips = []
        selectedClip = nil
        sources = []
        photos = []
        thumbnails = [:]
        selection = []
        message = nil
    }

    func openDocument(_ url: URL) {
        do {
            let f = try ProjectDocument.load(from: url)
            documentURL = url
            ud.set(url.path, forKey: Prefs.lastDocument)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            dwell = f.dwell
            transition = Transition(rawValue: f.transition) ?? .kenBurns
            transitionDuration = f.transitionDuration
            loop = f.loop
            fit = FitMode(rawValue: f.fit) ?? .fit
            exportSize = ExportSize(rawValue: f.exportSize) ?? .hd1080
            exportFps = f.exportFps
            clips = f.clips.map { c in
                var c = c
                // 書類の中の相対パスは、そのままにしておく（documentURL で解決する）
                if !c.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: url.appendingPathComponent(c.path).path) { c.path = "" }
                return c
            }.filter { !$0.path.isEmpty }
            resolveOverlaps()
            selectedClip = nil
            removedPaths = Set(f.excluded)
            // 選んだ写真は、書類の中の相対パスなら書類の場所で解決する
            pendingSelection = f.selection.map { $0.hasPrefix("/") ? $0 : url.appendingPathComponent($0).path }
            // order / recursive は didSet で rescan が走るので、先に揃えてから写真を読む
            let newOrder = PhotoOrder(rawValue: f.order) ?? .name
            let newRecursive = f.recursive
            let packaged = url.appendingPathComponent("photos")
            let srcs: [URL]
            if f.includesPhotos, FileManager.default.fileExists(atPath: packaged.path) {
                srcs = [packaged]       // 写真のコピーが入っていれば、それを元にする（自己完結）
            } else {
                srcs = f.sources.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            }
            if order != newOrder { order = newOrder }
            if recursive != newRecursive { recursive = newRecursive }
            sources = srcs
            ud.set(srcs.map(\.path), forKey: Prefs.lastSources)
            message = f.sources.isEmpty ? nil : (srcs.isEmpty ? "写真のフォルダが見つかりません" : nil)
            rescan()
        } catch {
            message = "書類を開けませんでした: \(error.localizedDescription)"
        }
    }

    /// 書類の中に写真を入れているか
    var documentHasPhotos: Bool {
        guard let doc = documentURL else { return false }
        return sources.contains { $0.standardizedFileURL == doc.appendingPathComponent("photos").standardizedFileURL }
    }

    /// 保存（場所が決まっていなければ聞く）。すでに写真入りの書類なら、そのまま写真も更新する
    func saveDocument() {
        if let url = documentURL { write(to: url, includePhotos: documentHasPhotos) } else { saveDocumentAs() }
    }

    func saveDocumentAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectDocument.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = (documentURL?.lastPathComponent)
            ?? "\(sources.first?.deletingPathExtension().lastPathComponent ?? "スライドショー").\(ProjectDocument.pathExtension)"
        panel.message = "スライドショーの書類（.cpsd）として保存します。音声ファイルは書類の中にコピーされます"
        let check = NSButton(checkboxWithTitle: "写真も書類の中にコピーする（\(photos.count) 枚。外した写真は入れない）", target: nil, action: nil)
        check.state = includePhotosDefault ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 32))
        check.frame = NSRect(x: 10, y: 6, width: 400, height: 20)
        box.addSubview(check)
        panel.accessoryView = box
        guard panel.runModal() == .OK, let url = panel.url else { return }
        includePhotosDefault = check.state == .on
        write(to: url, includePhotos: check.state == .on)
    }

    private func write(to url: URL, includePhotos: Bool) {
        guard savingMessage == nil else { return }
        var file = projectFile
        // 別の場所に保存するときは、今の書類の中の音声を絶対パスにしてからコピーさせる
        if let cur = documentURL, cur.standardizedFileURL != url.standardizedFileURL {
            for i in file.clips.indices where !file.clips[i].path.hasPrefix("/") {
                file.clips[i].path = cur.appendingPathComponent(file.clips[i].path).path
            }
        }
        // 写真を入れるなら、開いている写真を全部（パネルで外したものは除く）今の順番で
        let photoList: [URL]? = includePhotos ? photos : nil
        let selected = selection.sorted().compactMap { photos.indices.contains($0) ? photos[$0] : nil }
        if !includePhotos {
            file.selection = selected.map(\.path)
        }
        savingMessage = includePhotos ? "保存中…" : nil
        let fileToWrite = file
        Task { [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    try ProjectDocument.save(fileToWrite, to: url, photos: photoList, selected: selected) { i, n in
                        if i % 10 == 0 { Task { @MainActor [weak self] in self?.savingMessage = "保存中… 写真 \(i) / \(n)" } }
                    }
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            savingMessage = nil
            switch result {
            case .success:
                let wasPackaged = documentHasPhotos
                documentURL = url
                ud.set(url.path, forKey: Prefs.lastDocument)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                // 保存後は書類の中の相対パスで持つ
                if let saved = try? ProjectDocument.load(from: url) {
                    let byID = Dictionary(uniqueKeysWithValues: saved.clips.map { ($0.id, $0) })
                    for c in clips { if let n = byID[c.id], let wf = waveforms[c.path] { waveforms[n.path] = wf } }
                    clips = clips.map { byID[$0.id] ?? $0 }
                    // 写真を入れたときは、書類の中の写真を元にして読み直す（外した写真はコピーしていないので消えた扱い）
                    if includePhotos, !wasPackaged || saved.includesPhotos {
                        let packaged = url.appendingPathComponent("photos")
                        if sources.first?.standardizedFileURL != packaged.standardizedFileURL {
                            pendingSelection = saved.selection.map { url.appendingPathComponent($0).path }
                            removedPaths = []
                            sources = [packaged]
                            ud.set([packaged.path], forKey: Prefs.lastSources)
                            rescan()
                        }
                    }
                }
            case .failure(let error):
                let alert = NSAlert()
                alert.messageText = "保存できませんでした"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: 開く・Finder

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .image, .audio, ProjectDocument.type]
        panel.message = "写真のフォルダ（または写真・音声・.cpsd 書類）を選んでください"
        panel.prompt = "選択"
        if panel.runModal() == .OK { load(panel.urls) }
    }

    func revealSources() {
        guard !sources.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(sources)
    }

    // MARK: スライドショー

    func startSlideshow(from preferred: Int? = nil) {
        guard !photos.isEmpty, window == nil else { return }
        let (list, first) = makePlaylist(startingAt: preferred)
        guard !list.isEmpty else { return }
        stopAudition()
        returnWindow = NSApp.keyWindow
        let screen = returnWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let pixels = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        let maxPixel = min(8192, Int(pixels * 1.3))
        let controller = SlideshowController(urls: list, settings: slideshowSettings, maxPixel: maxPixel)
        let w = SlideshowWindow.present(controller: controller, on: screen, mode: displayMode) { [weak self] in
            self?.slideshowEnded()
        }
        controller.onFinish = { [weak w] in w?.close() }
        window = w
        activeController = controller
        isShowing = true
        controller.start(at: first)
    }

    func stopSlideshow() { window?.close() }

    private func slideshowEnded() {
        window = nil
        activeController = nil
        isShowing = false
        NSApp.activate(ignoringOtherApps: true)
        returnWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: mp4 書き出し

    var exportCount: Int { playCount }
    var exportDuration: TimeInterval { totalDuration }

    var isExporting: Bool {
        if let job = exportJob, case .running = job.state { return true }
        return false
    }

    /// 保存先を聞いて書き出す
    func exportMovie() {
        guard !photos.isEmpty, !isExporting else { return }
        let (list, _) = makePlaylist()
        guard !list.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        let base = documentURL?.deletingPathExtension().lastPathComponent
            ?? sources.first?.deletingPathExtension().lastPathComponent ?? "Slideshow"
        panel.nameFieldStringValue = "\(base).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.message = "スライドショーを mp4 として保存します"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let job = ExportJob()
        exportJob = job
        let settings = slideshowSettings
        let options = ExportOptions(size: exportSize.size, fps: exportFps)
        Task {
            await VideoExporter.export(urls: list, settings: settings, options: options, to: url, job: job)
        }
    }

    func finishExport() {
        exportJob = nil
        showExport = false
    }
}
