import SwiftUI
import AppKit
import AVFoundation

/// 「写真」のタブで見るライブラリ
enum LibraryMode: String, CaseIterable, Identifiable {
    case v1, v2
    var id: String { rawValue }
    var label: String {
        switch self {
        case .v1: return "V1 トラック"
        case .v2: return "V2 トラック"
        }
    }
}

/// 窓の上のタブ
enum MainTab: String, CaseIterable, Identifiable {
    case photos, preview, settings
    var id: String { rawValue }
    var label: String {
        switch self {
        case .photos: return "写真"
        case .preview: return "タイムライン"
        case .settings: return "設定"
        }
    }
}

@Observable @MainActor
final class AppModel {
    private let ud = UserDefaults.standard

    var sources: [URL] = []           // 写真のフォルダやファイル
    var photos: [URL] = []
    var thumbnails: [URL: CGImage] = [:]   // 画面に見えた順に読む
    var removedPaths: Set<String> = []     // パネルで外した写真（流さず、書類にもコピーしない）
    var isScanning = false
    var message: String?
    var isShowing = false             // 全画面（別ウインドウ）で流している
    var isPreviewing = false          // プレビューのタブの中で流している
    var playhead: TimeInterval = 0    // タイムラインの再生ヘッド（流していないときの位置。静止画のプレビューもここ）
    var timelineZoom: Double = 1      // タイムラインの横の拡大率（1 で全体が収まる）
    var previewHeight: Double = 300 { didSet { ud.set(previewHeight, forKey: "previewHeight") } }   // プレビューの画面の高さ（境目をドラッグして変える）
    var tab: MainTab = .photos

    /// 選んだ写真。1 枚なら「そこから開始」、2 枚以上なら「その写真だけを流す」
    var selection: Set<Int> = []
    private var anchor: Int?           // ⇧クリックの起点
    private var pendingSelection: [String] = []   // 書類を開いた直後、写真を読み終えてから選択に戻す

    /// 音声のタイムライン。変わったら、流している最中ならその場で反映する
    var clips: [MusicClip] = [] {
        didSet { activeController?.updateClips(effectiveClips, document: documentURL) }
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
    var endFade: Double { didSet { ud.set(endFade, forKey: Prefs.endFade) } }
    var titles: [TitleItem] = [] {
        didSet { ud.set(try? JSONEncoder().encode(titles), forKey: Prefs.titles); syncLive() }
    }
    var showTitles = false
    /// トラックごとの設定（透過率・非表示・音量・ミュート）。鍵は TrackRef.key
    var trackSettings: [String: TrackSettings] = [:] {
        didSet { ud.set(try? JSONEncoder().encode(trackSettings), forKey: Prefs.trackSettings); syncLive() }
    }
    var editingTrack: TrackRef?
    /// トラックの数（右クリックで足す・消す）。中身が使っている数より少なくはならない
    var titleTracks = 1 { didSet { ud.set(titleTracks, forKey: "titleTracks") } }
    var overlayTracks = 0 { didSet { ud.set(overlayTracks, forKey: "overlayTracks") } }
    var audioTracks = 1 { didSet { ud.set(audioTracks, forKey: "audioTracks") } }
    /// 写真ごとの表示時間・切り替え（写真のパスがキー。全体の設定を変えても、ここは変わらない）
    var overrides: [String: PhotoOverride] = [:] {
        didSet { ud.set(try? JSONEncoder().encode(overrides), forKey: Prefs.overrides) }
    }
    var showOverrides = false
    var showColorCard = false
    var libraryMode: LibraryMode = .v1
    /// V2（重ねる写真）のライブラリ。写真のパス。V1 の写真とは別に持つ
    var overlayLibrary: [String] = [] {
        didSet { ud.set(try? JSONEncoder().encode(overlayLibrary), forKey: "overlayLibrary") }
    }
    /// V2 のクリップ（タイムラインに置いたもの）
    var overlayClips: [OverlayClip] = [] {
        didSet { ud.set(try? JSONEncoder().encode(overlayClips), forKey: "overlayClips"); syncLive() }
    }
    var overlaySelection: Set<String> = []     // V2 ライブラリで選んでいる写真
    var selectedOverlays: Set<UUID> = []       // タイムラインで選んでいる V2 クリップ
    var overlayAnchor: UUID?                   // ⇧クリックの起点
    var editingOverlay: UUID?                  // 設定の画面を開いている V2 クリップ
    /// タイムラインの V1 で選んでいる写真。「写真」のタブの選択（＝その写真だけを流す）とは別で、流す写真は変わらない
    var timelineSelection: Set<URL> = []
    var timelineAnchor: Int?
    var overrideTargetIndices: [Int]?          // 表示時間・エフェクトの画面の対象（nil なら「写真」のタブの選択）
    var viewerImagePath: String?               // 拡大して見ている V2 の写真
    var selectedTitleIDs: Set<UUID> = []   // タイトルの編集画面で選んでいるタイトル（プレビューに出す）
    var transitionDuration: Double { didSet { ud.set(transitionDuration, forKey: Prefs.transitionDuration) } }
    var order: PhotoOrder {
        didSet {
            ud.set(order.rawValue, forKey: Prefs.order)
            guard order != oldValue else { return }
            // 手動にしたときは今の並びをそのまま手動の並びにする（読み直さない）
            if order == .manual { manualOrder = photos.map(\.path) } else { rescan() }
        }
    }
    /// 手動で並べた順（写真の絶対パス）
    var manualOrder: [String] = [] { didSet { ud.set(manualOrder, forKey: Prefs.manualOrder) } }
    /// 拡大表示している写真（photos の番号）。nil なら閉じている
    var viewerIndex: Int?
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
        endFade = ud.object(forKey: Prefs.endFade) as? Double ?? 0
        titleTracks = ud.object(forKey: "titleTracks") as? Int ?? 1
        overlayTracks = ud.object(forKey: "overlayTracks") as? Int ?? 0
        audioTracks = ud.object(forKey: "audioTracks") as? Int ?? 1
        previewHeight = ud.object(forKey: "previewHeight") as? Double ?? 300
        if let d = ud.data(forKey: Prefs.overrides), let o = try? JSONDecoder().decode([String: PhotoOverride].self, from: d) { overrides = o }
        if let d = ud.data(forKey: "overlayLibrary"), let v = try? JSONDecoder().decode([String].self, from: d) { overlayLibrary = v }
        if let d = ud.data(forKey: "overlayClips"), let v = try? JSONDecoder().decode([OverlayClip].self, from: d) { overlayClips = v }
        if let d = ud.data(forKey: Prefs.trackSettings), let v = try? JSONDecoder().decode([String: TrackSettings].self, from: d) { trackSettings = v }
        if let d = ud.data(forKey: Prefs.titles), let t = try? JSONDecoder().decode([TitleItem].self, from: d) { titles = t }
        order = PhotoOrder(rawValue: ud.string(forKey: Prefs.order) ?? "") ?? .name
        manualOrder = ud.stringArray(forKey: Prefs.manualOrder) ?? []
        loop = ud.object(forKey: Prefs.loop) as? Bool ?? true
        recursive = ud.object(forKey: Prefs.recursive) as? Bool ?? true
        fit = FitMode(rawValue: ud.string(forKey: Prefs.fit) ?? "") ?? .fit
        exportSize = ExportSize(rawValue: ud.string(forKey: Prefs.exportSize) ?? "") ?? .hd1080
        exportFps = ud.object(forKey: Prefs.exportFps) as? Int ?? 30
        displayMode = DisplayMode(rawValue: ud.string(forKey: Prefs.displayMode) ?? "") ?? .fullScreen
        // 起動したあとで resolveTrackOverlaps() を呼ぶ（init の中では self の準備が終わっていないため onAppear で）
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
        overrides = [:]
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
        viewerIndex = nil
        guard !sources.isEmpty else { photos = []; return }
        let srcs = sources, rec = recursive, ord = order, man = manualOrder
        isScanning = true
        message = nil
        scanTask = Task {
            let removed = removedPaths
            let list = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.collect(from: srcs, recursive: rec, order: ord, manual: man).filter { !removed.contains($0.path) }
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
        requestThumbnail(url: photos[i])
    }

    func requestThumbnail(url: URL) {
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

    func removePhotos(_ indices: [Int]) {
        let set = Set(indices.filter { photos.indices.contains($0) })
        guard !set.isEmpty else { return }
        for i in set { removedPaths.insert(photos[i].path) }
        photos = photos.enumerated().filter { !set.contains($0.offset) }.map(\.element)
        selection = []
        anchor = nil
        if let v = viewerIndex { viewerIndex = photos.isEmpty ? nil : min(v, photos.count - 1) }
    }

    var removedCount: Int { removedPaths.count }

    func restoreRemovedPhotos() {
        guard !removedPaths.isEmpty else { return }
        removedPaths = []
        rescan()
    }

    // MARK: 並べ替え

    /// moved の写真を、残りの写真の at 番目に差し込む。並べ替えたら順番は「手動」になる。選択は同じ写真のまま
    private func reorder(_ moved: [Int], insertAt at: Int) {
        let movedSet = Set(moved.filter { photos.indices.contains($0) })
        guard !movedSet.isEmpty else { return }
        let items = movedSet.sorted().map { photos[$0] }
        var rest = photos.enumerated().filter { !movedSet.contains($0.offset) }.map(\.element)
        rest.insert(contentsOf: items, at: min(max(0, at), rest.count))
        guard rest != photos else { return }
        let keepSelected = Set(selection.compactMap { photos.indices.contains($0) ? photos[$0] : nil })
        photos = rest
        selection = Set(rest.indices.filter { keepSelected.contains(rest[$0]) })
        anchor = nil
        if order != .manual { order = .manual }
        manualOrder = photos.map(\.path)
    }

    /// ドラッグで target の位置へ。前へ動かすときは target の手前、後ろへ動かすときは target の後ろに入る
    func movePhotos(_ indices: [Int], to target: Int) {
        let moved = Set(indices.filter { photos.indices.contains($0) }).sorted()
        guard let first = moved.first, photos.indices.contains(target), !moved.contains(target) else { return }
        var at = target - moved.filter { $0 < target }.count
        if first < target { at += 1 }
        reorder(moved, insertAt: at)
    }

    /// 選んだ写真を 1 つ前／後ろへ
    func moveSelection(by delta: Int) {
        let moved = selection.sorted()
        guard let first = moved.first, let last = moved.last else { return }
        movePhotos(moved, to: delta < 0 ? first - 1 : last + 1)
    }

    /// 選んだ（または指定した）写真を先頭／最後へ
    func moveToEdge(_ indices: [Int], front: Bool) {
        reorder(indices, insertAt: front ? 0 : Int.max)
    }

    /// 1 枚を delta だけ動かして、動いた先の番号を返す（拡大表示の中から使う）
    @discardableResult
    func movePhoto(_ i: Int, by delta: Int) -> Int {
        let target = min(max(0, i + delta), photos.count - 1)
        guard photos.indices.contains(i), target != i else { return i }
        movePhotos([i], to: target)
        return target
    }

    // MARK: 拡大表示

    /// 拡大表示を開く。番号がなければ選んでいる写真（なければ先頭）
    func openViewer(_ i: Int? = nil) {
        let idx = i ?? selection.min() ?? 0
        guard photos.indices.contains(idx), !isShowing else { return }
        viewerIndex = idx
    }

    func showViewer(_ i: Int) {
        guard photos.indices.contains(i) else { return }
        viewerIndex = i
        if selection.count < 2 { selection = [i]; anchor = i }
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
            transitionDuration: transitionDuration,
            loop: loop,
            fit: fit,
            clips: effectiveClips,
            document: documentURL,
            endFade: endFade,
            titles: effectiveTitles,
            overrides: overrides,
            overlayClips: effectiveOverlays,
            v1Opacity: v1Opacity)
    }

    // MARK: 所要時間・タイムライン

    /// 流す枚数（選んだ写真だけなら、その枚数）
    var playCount: Int { selection.count >= 2 ? selection.count : photos.count }

    /// 所要時間（秒）。最後の黒へのフェードを含む
    var totalDuration: TimeInterval { timing.total }

    /// 流す写真（選んだ写真だけなら、その写真）。ランダムのときは今の並びで数える
    var playURLs: [URL] {
        selection.count >= 2 ? selection.sorted().compactMap { photos.indices.contains($0) ? photos[$0] : nil } : photos
    }

    /// 流す写真ごとの長さと開始時刻（個別設定を反映）
    var timing: SlideTiming { SlideTiming(urls: playURLs, settings: slideshowSettings) }

    /// 個別設定のある写真の数（流す写真のうち）
    var overrideCountInPlay: Int { playURLs.filter { !(overrides[$0.path]?.isEmpty ?? true) }.count }

    /// 「12 枚 × 5 秒」の形の説明（個別設定があれば添える）
    var playSummary: String {
        let n = overrideCountInPlay
        return "\(playCount) 枚 × \(ContentView.seconds(dwell))" + (n > 0 ? "（うち \(n) 枚は個別設定）" : "")
    }

    // MARK: 再生ヘッド

    /// タイムライン上の k 番目の写真が、photos の何番目か
    func photoIndex(playIndex k: Int) -> Int? {
        let urls = playURLs
        return urls.indices.contains(k) ? photos.firstIndex(of: urls[k]) : nil
    }

    /// 再生ヘッドを動かす（スクラブ）。流している最中なら、その時刻の写真へ飛ぶ
    func scrub(to time: TimeInterval) {
        let t = min(max(0, time), timing.total)
        playhead = t
        if let c = activeController {
            // 同じ写真の中でも、時刻が離れていれば、その時刻へ飛ぶ（ドラッグ中の細かい動きは無視）
            if let cur = c.current, c.timing.index(at: t) == cur.index, abs(t - c.timelineTime(at: Date())) < 0.25 { return }
            c.jump(to: t)
        }
    }

    /// 前／後ろの写真の頭へ（流していないとき）。前へは、写真の途中ならその写真の頭
    func stepPlayhead(_ delta: Int) {
        let tm = timing
        guard tm.count > 0 else { return }
        let i = tm.index(at: playhead)
        var target = i + delta
        if delta < 0, playhead > tm.starts[i] + 0.05 { target = i }
        playhead = tm.starts[min(max(0, target), tm.count - 1)]
    }

    /// 流す写真の k 番目の表示時間を変える（タイムラインで端をドラッグ）。全体の設定と同じなら個別設定を外す
    func setPhotoDwell(playIndex k: Int, dwell newDwell: TimeInterval) {
        let urls = playURLs
        guard urls.indices.contains(k), let i = photos.firstIndex(of: urls[k]) else { return }
        let cur = overrides[photos[i].path]
        setOverride([i], dwell: abs(newDwell - dwell) < 0.001 ? nil : newDwell, transition: cur?.transition, fit: cur?.fit)
    }

    /// タイムラインの V1 の写真を押したとき。クリック: その 1 枚。⌘: 追加／解除。⇧: 起点から押した所まで
    func selectTimelinePhoto(_ k: Int, modifiers: NSEvent.ModifierFlags) {
        let urls = playURLs
        guard urls.indices.contains(k) else { return }
        if modifiers.contains(.command) {
            if timelineSelection.contains(urls[k]) { timelineSelection.remove(urls[k]) } else { timelineSelection.insert(urls[k]) }
            timelineAnchor = k
        } else if modifiers.contains(.shift), let a = timelineAnchor, urls.indices.contains(a) {
            timelineSelection.formUnion(urls[min(a, k)...max(a, k)])
        } else {
            timelineSelection = [urls[k]]
            timelineAnchor = k
        }
    }

    /// タイムラインで選んでいる写真の、photos の番号
    var timelineSelectedIndices: [Int] { photos.indices.filter { timelineSelection.contains(photos[$0]) } }

    /// 選んでいる写真をまとめて、k1 番目の写真の位置へ動かす
    func moveTimelineGroup(from k0: Int, to k1: Int) {
        let idx = timelineSelectedIndices
        guard idx.count >= 2, let j = photoIndex(playIndex: k1), !idx.contains(j), let first = idx.first else { return }
        let url = photos[first]
        movePhotos(idx, to: j)
        if let nk = playURLs.firstIndex(of: url) { playhead = timing.starts[nk] }
    }

    /// タイムラインで写真をドラッグして並べ替える（流す写真の k0 番目を k1 番目の位置へ）。再生ヘッドは動かした写真の頭へ
    func moveTimelinePhoto(from k0: Int, to k1: Int) {
        guard let i = photoIndex(playIndex: k0), let j = photoIndex(playIndex: k1), i != j else { return }
        let url = photos[i]
        movePhotos([i], to: j)
        if let nk = playURLs.firstIndex(of: url) { playhead = timing.starts[nk] }
    }

    /// 再生ヘッドの位置にタイトルを足す
    func addTitle(at time: TimeInterval, track: Int? = nil) {
        var item = TitleItem()
        item.start = (time * 10).rounded() / 10
        if !titles.isEmpty { item.anchor = .top; item.size = 0.05 }
        item.track = track.map { min(max(0, $0), titleTrackCount - 1) } ?? freeTitleTrack(start: item.start, end: item.start + item.duration)
        titles.append(item)
        selectedTitleIDs = [item.id]
    }

    // MARK: トラックの設定

    /// 流している最中（プレビュー・全画面）に、タイトル・V2・トラックの設定の変更をその場で反映する
    private func syncLive() {
        activeController?.applyLive(clips: effectiveClips, titles: effectiveTitles, overlays: effectiveOverlays,
                                    v1Opacity: v1Opacity, document: documentURL)
    }

    func trackSetting(_ ref: TrackRef) -> TrackSettings { trackSettings[ref.key] ?? TrackSettings() }

    func updateTrackSetting(_ ref: TrackRef, _ change: (inout TrackSettings) -> Void) {
        var s = trackSetting(ref)
        change(&s)
        s.opacity = min(1, max(0, s.opacity))
        s.volume = min(1, max(0, s.volume))
        if s.isDefault { trackSettings[ref.key] = nil } else { trackSettings[ref.key] = s }
    }

    /// V1 全体の濃さ（非表示なら 0）
    var v1Opacity: Double { let s = trackSetting(TrackRef(kind: nil)); return s.hidden ? 0 : s.opacity }

    /// 再生・書き出しに使う、トラックの設定を反映したもの
    var effectiveClips: [MusicClip] {
        clips.compactMap { c in
            let s = trackSetting(TrackRef(kind: .audio, index: c.track))
            if s.muted { return nil }
            var c = c
            c.volume *= s.volume
            return c
        }
    }

    var effectiveTitles: [TitleItem] {
        titles.compactMap { t in
            let s = trackSetting(TrackRef(kind: .title, index: t.track))
            if s.hidden { return nil }
            var t = t
            t.opacity *= s.opacity
            return t
        }
    }

    var effectiveOverlays: [OverlayClip] {
        overlayClips.compactMap { c in
            let s = trackSetting(TrackRef(kind: .overlay, index: c.track))
            if s.hidden { return nil }
            var c = c
            c.opacity *= s.opacity
            return c
        }
    }

    /// トラックを消したとき、上のトラックの設定を 1 つ下げる
    private func shiftTrackSettings(_ kind: TrackKind, removed index: Int, count: Int) {
        var out = trackSettings
        for i in index..<max(index, count) {
            let from = TrackRef(kind: kind, index: i + 1).key, to = TrackRef(kind: kind, index: i).key
            out[to] = out[from]
            out[from] = nil
        }
        if trackSettings != out { trackSettings = out }
    }

    // MARK: トラック（T・V2 以上・A）

    enum TrackKind: Hashable { case title, overlay, audio }

    /// それぞれのトラックの数（中身が使っている数より少なくはならない）
    var titleTrackCount: Int { max(0, titleTracks, (titles.map(\.track).max() ?? -1) + 1) }
    var overlayTrackCount: Int { max(0, overlayTracks, (overlayClips.map(\.track).max() ?? -1) + 1) }
    var trackCount: Int { max(0, audioTracks, (clips.map(\.track).max() ?? -1) + 1) }     // 音声のトラック

    func addTrack(_ kind: TrackKind) {
        switch kind {
        case .title: titleTracks = titleTrackCount + 1
        case .overlay: overlayTracks = overlayTrackCount + 1
        case .audio: audioTracks = trackCount + 1
        }
    }

    func isTrackEmpty(_ kind: TrackKind, _ index: Int) -> Bool {
        switch kind {
        case .title: return !titles.contains { $0.track == index }
        case .overlay: return !overlayClips.contains { $0.track == index }
        case .audio: return !clips.contains { $0.track == index }
        }
    }

    /// 空のトラックを消す（上のトラックは 1 つ下がる）。V1（写真）だけは消せない
    func removeTrack(_ kind: TrackKind, _ index: Int) {
        guard isTrackEmpty(kind, index) else { return }
        switch kind {
        case .title:
            let n = titleTrackCount
            guard n > 0 else { return }
            for i in titles.indices where titles[i].track > index { titles[i].track -= 1 }
            shiftTrackSettings(.title, removed: index, count: n - 1)
            titleTracks = n - 1
        case .overlay:
            let n = overlayTrackCount
            guard n > 0 else { return }
            for i in overlayClips.indices where overlayClips[i].track > index { overlayClips[i].track -= 1 }
            shiftTrackSettings(.overlay, removed: index, count: n - 1)
            overlayTracks = n - 1
        case .audio:
            let n = trackCount
            guard n > 0 else { return }
            for i in clips.indices where clips[i].track > index { clips[i].track -= 1 }
            shiftTrackSettings(.audio, removed: index, count: n - 1)
            audioTracks = n - 1
        }
    }

    /// 時間の重なる項目を、別のトラックへ振り分ける（古い書類や、重ねて置いたとき）
    func resolveTrackOverlaps() {
        func resolve<T>(_ items: inout [T], track: WritableKeyPath<T, Int>, span: (T) -> (Double, Double)) {
            var placed: [(track: Int, s: Double, e: Double)] = []
            for idx in items.indices.sorted(by: { span(items[$0]).0 < span(items[$1]).0 }) {
                let (s, e) = span(items[idx])
                var t = max(0, items[idx][keyPath: track])
                while placed.contains(where: { $0.track == t && $0.s < e && s < $0.e }) { t += 1 }
                items[idx][keyPath: track] = t
                placed.append((t, s, e))
            }
        }
        var ts = titles
        resolve(&ts, track: \.track) { ($0.start, $0.duration > 0 ? $0.start + $0.duration : 1e9) }
        if ts != titles { titles = ts }
        var os = overlayClips
        resolve(&os, track: \.track) { ($0.start, $0.end) }
        if os != overlayClips { overlayClips = os }
    }

    private func freeTitleTrack(start: Double, end: Double) -> Int {
        let e = end > start ? end : 1e9
        for t in 0..<titleTrackCount {
            let busy = titles.contains { $0.track == t && $0.start < e && start < ($0.duration > 0 ? $0.start + $0.duration : 1e9) }
            if !busy { return t }
        }
        return titleTrackCount
    }

    private func freeOverlayTrack(start: Double, end: Double) -> Int {
        for t in 0..<overlayTrackCount {
            if !overlayClips.contains(where: { $0.track == t && $0.start < end && start < $0.end }) { return t }
        }
        return overlayTrackCount
    }

    // MARK: V2（重ねる写真）

    /// V2 ライブラリに写真を足す（フォルダも可）。足した写真のパスを返す
    @discardableResult
    func addOverlayPhotos(_ urls: [URL]) -> [String] {
        let found = PhotoLibrary.collect(from: urls, recursive: true, order: .name)
        var added: [String] = []
        for u in found where !overlayLibrary.contains(u.path) {
            overlayLibrary.append(u.path)
            added.append(u.path)
        }
        return added
    }

    func openOverlayPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .image]
        panel.message = "V2（重ねる写真）のライブラリに入れる写真（またはフォルダ）を選んでください"
        panel.prompt = "追加"
        if panel.runModal() == .OK { addOverlayPhotos(panel.urls) }
    }

    func removeOverlayLibrary(_ paths: Set<String>) {
        overlayLibrary.removeAll { paths.contains($0) }
        let gone = Set(overlayClips.filter { paths.contains($0.path) }.map(\.id))
        overlayClips.removeAll { paths.contains($0.path) }
        overlaySelection.subtract(paths)
        selectedOverlays.subtract(gone)
        if let e = editingOverlay, gone.contains(e) { editingOverlay = nil }
    }

    /// ライブラリの写真をタイムラインの V2 に置く（複数なら、続けて並べる）。表示時間は全体の設定と同じ
    func placeOverlays(_ paths: [String], at time: TimeInterval, track: Int? = nil) {
        var t = max(0, time)
        var ids: Set<UUID> = []
        for p in paths where overlayLibrary.contains(p) {
            var clip = OverlayClip(path: p, start: t, duration: dwell)
            clip.track = track ?? freeOverlayTrack(start: clip.start, end: clip.end)   // 指定がなければ、空いている V のトラックへ（なければ足す）
            overlayClips.append(clip)
            ids.insert(clip.id)
            t += clip.duration
        }
        if !ids.isEmpty { selectedOverlays = ids }
    }

    /// ファイルをタイムラインの V2 に直接落としたとき: ライブラリにも入れて、その位置に置く
    func importAndPlaceOverlays(_ urls: [URL], at time: TimeInterval) {
        let found = PhotoLibrary.collect(from: urls, recursive: true, order: .name)
        for u in found where !overlayLibrary.contains(u.path) { overlayLibrary.append(u.path) }
        placeOverlays(found.map(\.path), at: time)
    }

    func updateOverlay(_ id: UUID, _ change: (inout OverlayClip) -> Void) {
        guard let i = overlayClips.firstIndex(where: { $0.id == id }) else { return }
        var c = overlayClips[i]
        change(&c)
        c.start = max(0, c.start)
        c.duration = max(0.3, c.duration)
        c.opacity = min(1, max(0, c.opacity))
        c.scale = min(4, max(0.05, c.scale))
        overlayClips[i] = c
    }

    func removeOverlayClip(_ id: UUID) {
        overlayClips.removeAll { $0.id == id }
        selectedOverlays.remove(id)
        if editingOverlay == id { editingOverlay = nil }
    }

    /// クリック: その 1 件。⌘: 追加／解除。⇧: 起点から押したものまで（開始時刻の順）を追加
    func selectOverlay(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        let order = overlayClips.sorted { $0.start < $1.start }.map(\.id)
        if modifiers.contains(.command) {
            if selectedOverlays.contains(id) { selectedOverlays.remove(id) } else { selectedOverlays.insert(id) }
            overlayAnchor = id
        } else if modifiers.contains(.shift), let a = overlayAnchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
            selectedOverlays.formUnion(order[min(i, j)...max(i, j)])
        } else {
            selectedOverlays = [id]
            overlayAnchor = id
        }
    }

    /// 選んだ V2 クリップをまとめて動かす（origins は動かし始める前の開始時刻とトラック）
    func moveOverlays(_ origins: [UUID: (start: TimeInterval, track: Int)], delta: TimeInterval, deltaTrack: Int, maxTrack: Int) {
        var out = overlayClips
        for i in out.indices {
            guard let o = origins[out[i].id] else { continue }
            out[i].start = max(0, o.start + delta)
            out[i].track = min(max(0, o.track + deltaTrack), max(0, maxTrack))
        }
        if out != overlayClips { overlayClips = out }
    }

    /// 選んだ V2 クリップを、開始時刻の順に、前のクリップの終わりに続けて並べる（先頭は動かさない）
    func packSelectedOverlays() {
        var out = overlayClips
        let idx = out.indices.filter { selectedOverlays.contains(out[$0].id) }.sorted { out[$0].start < out[$1].start }
        guard idx.count >= 2 else { return }
        var t = out[idx[0]].end
        for i in idx.dropFirst() {
            out[i].start = t
            t = out[i].end
        }
        overlayClips = out
    }

    func removeSelectedOverlays() {
        let ids = selectedOverlays
        overlayClips.removeAll { ids.contains($0.id) }
        selectedOverlays = []
        if let e = editingOverlay, ids.contains(e) { editingOverlay = nil }
    }

    func duplicateSelectedOverlays() {
        var added: Set<UUID> = []
        for c in overlayClips.filter({ selectedOverlays.contains($0.id) }).sorted(by: { $0.start < $1.start }) {
            var copy = c
            copy.id = UUID()
            copy.start = c.end
            copy.track = freeOverlayTrack(start: copy.start, end: copy.end)
            overlayClips.append(copy)
            added.insert(copy.id)
        }
        if !added.isEmpty { selectedOverlays = added }
    }

    func duplicateOverlayClip(_ id: UUID) {
        guard let c = overlayClips.first(where: { $0.id == id }) else { return }
        var copy = c
        copy.id = UUID()
        copy.start = c.end
        copy.track = freeOverlayTrack(start: copy.start, end: copy.end)
        overlayClips.append(copy)
        selectedOverlays = [copy.id]
    }

    // MARK: 単色画像

    /// 単色画像のファイルを置く場所（普通の写真として扱えるよう、実ファイルにする）
    private static var colorCardDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CacaoPhotoSlide/ColorCards", isDirectory: true)
    }

    /// 単色画像を、再生ヘッドの位置（写真の途中なら、その写真の後ろ）に足す
    func addColorCard(_ color: NSColor, dwell cardDwell: TimeInterval) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        let hex = String(format: "%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                         Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        let dir = Self.colorCardDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("単色-\(hex)-\(UUID().uuidString.prefix(6)).png")
        guard let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return }

        // 入れる位置（photos の番号）
        var p = photos.count
        let urls = playURLs
        if !urls.isEmpty {
            let tm = timing
            let k = tm.index(at: playhead)
            if let base = photoIndex(playIndex: k) { p = playhead <= tm.starts[k] + 0.05 ? base : base + 1 }
        }
        selection = []
        anchor = nil
        photos.insert(url, at: min(max(0, p), photos.count))
        sources.append(url)                       // 読み直しても残るように
        ud.set(sources.map(\.path), forKey: Prefs.lastSources)
        if order != .manual { order = .manual }
        manualOrder = photos.map(\.path)
        if abs(cardDwell - dwell) > 0.001 { overrides[url.path] = PhotoOverride(dwell: cardDwell, transition: nil) }
        message = nil
    }

    // MARK: 写真ごとの設定

    /// 個別設定を開く。i を指定して、選んでいない写真なら、その 1 枚を選ぶ
    func openOverrides(for i: Int? = nil) {
        if let i, photos.indices.contains(i), !selection.contains(i) { selection = [i]; anchor = i }
        guard !selection.isEmpty else { return }
        showOverrides = true
    }

    /// 選んだ写真に表示時間・切り替え・収め方を設定する（nil は全体の設定に従う）。両方 nil なら個別設定を外す
    func setOverride(_ indices: [Int], dwell: TimeInterval?, transition: Transition?, fit: FitMode? = nil) {
        var o = overrides
        for i in indices where photos.indices.contains(i) {
            let v = PhotoOverride(dwell: dwell, transition: transition, fit: fit)
            if v.isEmpty { o[photos[i].path] = nil } else { o[photos[i].path] = v }
        }
        overrides = o
    }

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

    /// クリップを別のトラックへ
    func setTrack(_ id: UUID, _ lane: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].track = min(max(0, lane), trackCount - 1)
    }

    /// クリップを動かす（写真の区切りに吸着できる）。track を渡すと段も変える
    func moveClip(_ id: UUID, to start: TimeInterval, snap: TimeInterval? = nil, track: Int? = nil) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        var s = max(0, start)
        if let snap {
            // 写真の区切りに吸着
            let marks = timing.starts
            if let near = marks.min(by: { abs($0 - s) < abs($1 - s) }), abs(near - s) <= snap { s = near }
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
        f.endFade = endFade
        f.titles = titles
        f.overrides = overrides.filter { !$0.value.isEmpty }
        f.overlayLibrary = overlayLibrary
        f.titleTracks = titleTrackCount
        f.trackSettings = trackSettings
        f.overlayTracks = overlayTrackCount
        f.audioTracks = trackCount
        f.overlayClips = overlayClips
        f.view = ViewState(tab: tab.rawValue, timelineZoom: timelineZoom, previewHeight: previewHeight, playhead: playhead)
        f.order = order.rawValue
        f.loop = loop
        f.recursive = recursive
        f.fit = fit.rawValue
        f.exportSize = exportSize.rawValue
        f.exportFps = exportFps
        f.clips = clips
        f.excluded = Array(removedPaths).sorted()
        f.manualOrder = order == .manual ? manualOrder : []
        return f
    }

    func newDocument() {
        documentURL = nil
        ud.removeObject(forKey: Prefs.lastDocument)
        removedPaths = []
        titles = []
        overrides = [:]
        overlayLibrary = []
        overlayClips = []
        overlaySelection = []
        selectedOverlays = []
        titleTracks = 1; overlayTracks = 0; audioTracks = 1
        trackSettings = [:]
        clips = []
        selectedClip = nil
        sources = []
        photos = []
        thumbnails = [:]
        selection = []
        viewerIndex = nil
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
            endFade = f.endFade
            titles = f.titles
            if let v = f.view {                      // 画面の状態を再現
                tab = MainTab(rawValue: v.tab) ?? .photos
                timelineZoom = min(24, max(1, v.timelineZoom))
                previewHeight = min(900, max(120, v.previewHeight))
                playhead = max(0, v.playhead)
            }
            overlayLibrary = f.overlayLibrary.map { $0.hasPrefix("/") ? $0 : url.appendingPathComponent($0).path }
            overlayClips = f.overlayClips.map { c in
                var c = c
                if !c.path.hasPrefix("/") { c.path = url.appendingPathComponent(c.path).path }
                return c
            }
            overlaySelection = []
            selectedOverlays = []
            trackSettings = f.trackSettings ?? [:]
            titleTracks = f.titleTracks ?? 1; overlayTracks = f.overlayTracks ?? 0; audioTracks = f.audioTracks ?? 1
            resolveTrackOverlaps()
            overrides = Dictionary(f.overrides.map { ($0.key.hasPrefix("/") ? $0.key : url.appendingPathComponent($0.key).path, $0.value) },
                                   uniquingKeysWith: { a, _ in a })
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
            // 起動引数 -selectFirstClip YES で最初のクリップを選んでおく（記事の画面写真用）
            selectedClip = ud.bool(forKey: "selectFirstClip") ? clips.first?.id : nil
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
            manualOrder = f.manualOrder.map { $0.hasPrefix("/") ? $0 : url.appendingPathComponent($0).path }
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
                    if includePhotos {
                        overlayLibrary = saved.overlayLibrary.map { $0.hasPrefix("/") ? $0 : url.appendingPathComponent($0).path }
                        overlayClips = saved.overlayClips.map { c in
                            var c = c
                            if !c.path.hasPrefix("/") { c.path = url.appendingPathComponent(c.path).path }
                            return c
                        }
                        overlaySelection = []
                        overrides = Dictionary(saved.overrides.map { ($0.key.hasPrefix("/") ? $0.key : url.appendingPathComponent($0.key).path, $0.value) },
                                               uniquingKeysWith: { a, _ in a })
                    }
                    if includePhotos, order == .manual {
                        manualOrder = saved.manualOrder.map { url.appendingPathComponent($0).path }
                    }
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
        if isPreviewing { stopSlideshow() }
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

    /// 起動引数 -demoSheet titles / overlay / track で、書類を開いたあとに編集の画面を開く（記事の画面写真を撮るための隠し機能）
    func demoOpenSheet() {
        guard let kind = ud.string(forKey: "demoSheet") else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            switch kind {
            case "titles": selectedTitleIDs = titles.first.map { [$0.id] } ?? []; showTitles = true
            case "overlay": editingOverlay = overlayClips.first?.id
            case "track": editingTrack = TrackRef(kind: .overlay, index: 0)
            default: break
            }
        }
    }

    private var spaceMonitor: Any?

    /// タイムラインのタブで Space: 流している間は一時停止／再開、止まっているときは再生ヘッドの位置から再生。
    /// 文字を入力している最中と、シート（編集画面）が開いている間は、Space をそのまま渡す
    func installSpaceKey() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  tab == .preview, !isShowing, !photos.isEmpty,
                  let window = event.window, window.attachedSheet == nil, window === NSApp.mainWindow || window.isKeyWindow,
                  !(window.firstResponder is NSText) else { return event }
            if isPreviewing, let c = activeController {
                c.togglePause()
            } else if !isScanning {
                startPreview(atTime: playhead)
            }
            return nil
        }
    }

    func stopSlideshow() {
        if isPreviewing {
            if let c = activeController { playhead = min(c.timelineTime(at: Date()), timing.total) }   // 止めた位置を残す
            activeController?.stop()
            activeController = nil
            isPreviewing = false
        } else {
            window?.close()
        }
    }

    /// プレビューのタブの中で流す（音声も鳴る）。全画面と同じ描画
    /// time はタイムライン上の時刻。その時刻から再生する（写真の途中でも、V2・タイトル・音声の途中でも）。nil なら最初から
    func startPreview(atTime time: TimeInterval? = nil) {
        guard !photos.isEmpty, window == nil, !isPreviewing else { return }
        var preferred: Int?
        var offset: TimeInterval = 0
        if let time {
            let tm = timing
            let k = tm.index(at: time)
            if playURLs.indices.contains(k) {
                preferred = photos.firstIndex(of: playURLs[k])
                offset = max(0, min(time - tm.starts[k], tm.dwells[k]))
            }
        }
        let (list, first) = makePlaylist(startingAt: preferred)
        guard !list.isEmpty else { return }
        stopAudition()
        let controller = SlideshowController(urls: list, settings: slideshowSettings, maxPixel: 1600)
        controller.onFinish = { [weak self] in self?.stopSlideshow(); self?.playhead = 0 }   // 最後まで流したら頭へ
        activeController = controller
        isPreviewing = true
        controller.start(at: first, offset: offset)
    }

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
