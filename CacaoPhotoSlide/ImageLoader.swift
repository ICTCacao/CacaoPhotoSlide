import Foundation
import ImageIO
import CoreGraphics

/// 写真を画面サイズに縮めて読み、前後数枚をキャッシュしておく
actor ImageLoader {
    private let urls: [URL]
    private let maxPixel: Int
    private var cache: [Int: CGImage] = [:]
    private var tasks: [Int: Task<CGImage?, Never>] = [:]

    init(urls: [URL], maxPixel: Int) {
        self.urls = urls
        self.maxPixel = maxPixel
    }

    func image(at i: Int) async -> CGImage? {
        guard urls.indices.contains(i) else { return nil }
        if let c = cache[i] { return c }
        let task = tasks[i] ?? startLoading(i)
        return await task.value
    }

    /// 今の写真の前後を先に読んでおき、離れたものは捨てる
    func preload(around index: Int, loop: Bool) {
        let n = urls.count
        var keep: Set<Int> = []
        for d in [-1, 0, 1, 2] {
            var j = index + d
            if loop, n > 0 { j = (j % n + n) % n }
            guard (0..<n).contains(j) else { continue }
            keep.insert(j)
            if cache[j] == nil, tasks[j] == nil { _ = startLoading(j) }
        }
        for k in cache.keys where !keep.contains(k) { cache[k] = nil }
        for (k, t) in tasks where !keep.contains(k) { t.cancel(); tasks[k] = nil }
    }

    private func startLoading(_ i: Int) -> Task<CGImage?, Never> {
        let url = urls[i], mp = maxPixel
        let task = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            return ImageLoader.decode(url, maxPixel: mp)
        }
        tasks[i] = task
        Task {
            let img = await task.value
            if tasks[i] == task {
                tasks[i] = nil
                if let img { cache[i] = img }
            }
        }
        return task
    }

    /// EXIF の向きを反映しつつ、長辺 maxPixel 以下に縮めて読む（小さい写真は拡大しない）
    nonisolated static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
