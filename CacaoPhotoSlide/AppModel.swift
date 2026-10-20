import SwiftUI
import AppKit

@Observable @MainActor
final class AppModel {
    private let ud = UserDefaults.standard

    var sources: [URL] = []           // ドロップされたフォルダやファイル
    var photos: [URL] = []
    var thumbnails: [Int: CGImage] = [:]   // 画面に見えた順に読む
    var isScanning = false
    var message: String?
    var isShowing = false

    /// 選んだ写真。1 枚なら「そこから開始」、2 枚以上なら「その写真だけを流す」
    var selection: Set<Int> = []
    private var anchor: Int?           // ⇧クリックの起点

    var dwell: Double { didSet { ud.set(dwell, forKey: Prefs.dwell) } }
    var transition: Transition { didSet { ud.set(transition.rawValue, forKey: Prefs.transition) } }
    var transitionDuration: Double { didSet { ud.set(transitionDuration, forKey: Prefs.transitionDuration) } }
    var order: PhotoOrder { didSet { ud.set(order.rawValue, forKey: Prefs.order); if order != oldValue { rescan() } } }
    var loop: Bool { didSet { ud.set(loop, forKey: Prefs.loop) } }
    var recursive: Bool { didSet { ud.set(recursive, forKey: Prefs.recursive); if recursive != oldValue { rescan() } } }
    var fit: FitMode { didSet { ud.set(fit.rawValue, forKey: Prefs.fit) } }
    var exportSize: ExportSize { didSet { ud.set(exportSize.rawValue, forKey: Prefs.exportSize) } }
    var exportFps: Int { didSet { ud.set(exportFps, forKey: Prefs.exportFps) } }

    /// 表示時間の選択肢（秒）
    static let dwellChoices: [Double] = [0.3, 0.5, 0.7, 1, 1.5, 2, 3, 4, 5, 7, 10, 15, 20, 30]

    // mp4 書き出し
    var showExport = false
    var exportJob: ExportJob?

    private var scanTask: Task<Void, Never>?
    private var thumbTasks: [Int: Task<Void, Never>] = [:]
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
    }

    // MARK: 写真を集める

    func load(_ urls: [URL]) {
        let list = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !list.isEmpty else { return }
        sources = list
        ud.set(list.map(\.path), forKey: Prefs.lastSources)
        rescan()
    }

    /// 前回のフォルダがまだあれば読み直す
    func restoreLastSources() {
        guard sources.isEmpty, let paths = ud.stringArray(forKey: Prefs.lastSources) else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !urls.isEmpty { load(urls) }
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
            let list = await Task.detached(priority: .userInitiated) {
                PhotoLibrary.collect(from: srcs, recursive: rec, order: ord)
            }.value
            guard !Task.isCancelled else { return }
            photos = list
            isScanning = false
            message = list.isEmpty ? "写真が見つかりませんでした" : nil
        }
    }

    /// サムネイルが画面に出たら読む（読み終わったものは持っておく）
    func requestThumbnail(_ i: Int) {
        guard photos.indices.contains(i), thumbnails[i] == nil, thumbTasks[i] == nil else { return }
        let url = photos[i]
        thumbTasks[i] = Task { [weak self] in
            let img = await Task.detached(priority: .utility) { ImageLoader.decode(url, maxPixel: 128) }.value
            guard let self, !Task.isCancelled else { return }
            thumbTasks[i] = nil
            if let img { thumbnails[i] = img }
        }
    }

    func cancelThumbnail(_ i: Int) {
        thumbTasks[i]?.cancel()
        thumbTasks[i] = nil
    }

    // MARK: 選択

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

    func selectAll() {
        selection = Set(photos.indices)
    }

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
            // 開始写真を決めていれば、それを先頭にしてから始める
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
            fit: fit)
    }

    // MARK: 開く・Finder

    func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .image]
        panel.message = "写真のフォルダ（または写真）を選んでください"
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
        returnWindow = NSApp.keyWindow
        let screen = returnWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let pixels = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        let maxPixel = min(8192, Int(pixels * 1.3))
        let controller = SlideshowController(urls: list, settings: slideshowSettings, maxPixel: maxPixel)
        let w = SlideshowWindow.present(controller: controller, on: screen) { [weak self] in
            self?.slideshowEnded()
        }
        controller.onFinish = { [weak w] in w?.close() }
        window = w
        isShowing = true
        controller.start(at: first)
    }

    private func slideshowEnded() {
        window = nil
        isShowing = false
        NSApp.activate(ignoringOtherApps: true)
        returnWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: mp4 書き出し

    var exportCount: Int { selection.count >= 2 ? selection.count : photos.count }

    var exportDuration: TimeInterval {
        VideoExporter.duration(count: exportCount, settings: slideshowSettings)
    }

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
        let base = sources.first?.deletingPathExtension().lastPathComponent ?? "Slideshow"
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
