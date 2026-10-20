import SwiftUI
import AppKit

@Observable @MainActor
final class AppModel {
    private let ud = UserDefaults.standard

    var sources: [URL] = []           // ドロップされたフォルダやファイル
    var photos: [URL] = []
    var thumbnails: [Int: CGImage] = [:]   // 画面に見えた順に読む
    var startIndex: Int?                   // クリックで選んだ開始写真（nil なら最初から）
    var isScanning = false
    var message: String?
    var isShowing = false

    var dwell: Double { didSet { ud.set(dwell, forKey: Prefs.dwell) } }
    var transition: Transition { didSet { ud.set(transition.rawValue, forKey: Prefs.transition) } }
    var transitionDuration: Double { didSet { ud.set(transitionDuration, forKey: Prefs.transitionDuration) } }
    var order: PhotoOrder { didSet { ud.set(order.rawValue, forKey: Prefs.order); if order != oldValue { rescan() } } }
    var loop: Bool { didSet { ud.set(loop, forKey: Prefs.loop) } }
    var recursive: Bool { didSet { ud.set(recursive, forKey: Prefs.recursive); if recursive != oldValue { rescan() } } }
    var fit: FitMode { didSet { ud.set(fit.rawValue, forKey: Prefs.fit) } }

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
        startIndex = nil
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

    /// 開始写真の表示用（「12 枚目  IMG_0012.jpg」）
    var startLabel: String? {
        guard let i = startIndex, photos.indices.contains(i) else { return nil }
        return "\(i + 1) 枚目  \(photos[i].lastPathComponent)"
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

    func startSlideshow() {
        guard !photos.isEmpty, window == nil else { return }
        var list = photos
        var first = startIndex.flatMap { photos.indices.contains($0) ? $0 : nil } ?? 0
        if order == .random {
            let startURL = list[first]
            list.shuffle()
            // 選んだ写真があれば、それを先頭にしてから始める
            if startIndex != nil, let k = list.firstIndex(of: startURL) { list.swapAt(0, k) }
            first = 0
        }
        let settings = SlideshowSettings(
            dwell: dwell,
            transition: transition,
            transitionDuration: transition == .none ? 0 : transitionDuration,
            loop: loop,
            fit: fit)
        returnWindow = NSApp.keyWindow
        let screen = returnWindow?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let pixels = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        let maxPixel = min(8192, Int(pixels * 1.3))
        let controller = SlideshowController(urls: list, settings: settings, maxPixel: maxPixel)
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
}
