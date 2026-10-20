import Foundation
import AVFoundation
import CoreGraphics
import Observation

/// mp4 のサイズ（すべて 16:9、最大 4K）
enum ExportSize: String, CaseIterable, Identifiable {
    case hd720, hd1080, qhd1440, uhd2160
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hd720: return "720p（1280×720）"
        case .hd1080: return "1080p（1920×1080）"
        case .qhd1440: return "1440p（2560×1440）"
        case .uhd2160: return "4K（3840×2160）"
        }
    }
    var size: CGSize {
        switch self {
        case .hd720: return CGSize(width: 1280, height: 720)
        case .hd1080: return CGSize(width: 1920, height: 1080)
        case .qhd1440: return CGSize(width: 2560, height: 1440)
        case .uhd2160: return CGSize(width: 3840, height: 2160)
        }
    }
}

struct ExportOptions {
    var size: CGSize
    var fps: Int
}

/// 書き出しの進み具合（画面に出す）
@Observable @MainActor
final class ExportJob {
    enum State { case running, done(URL), failed(String), cancelled }
    var progress: Double = 0
    var state: State = .running
    let flag = CancelFlag()
    func cancel() { flag.cancel() }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

enum ExportError: LocalizedError {
    case writer(String), noImages, pixelBuffer, cancelled
    var errorDescription: String? {
        switch self {
        case .writer(let s): return "書き出せませんでした: \(s)"
        case .noImages: return "読める写真がありません"
        case .pixelBuffer: return "フレームの用意に失敗しました"
        case .cancelled: return "中止しました"
        }
    }
}

/// スライドショーを 1 コマずつ描いて mp4（H.264）にする
enum VideoExporter {
    /// 全体の長さ（秒）。最後は切り替えの長さぶん黒にフェードする
    static func duration(count: Int, settings: SlideshowSettings) -> TimeInterval {
        let tr = min(settings.transitionDuration, settings.dwell)
        return Double(count) * settings.dwell + tr
    }

    @MainActor static func export(urls: [URL], settings: SlideshowSettings, options: ExportOptions, to output: URL, job: ExportJob) async {
        let flag = job.flag
        let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try run(urls: urls, settings: settings, options: options, output: output, flag: flag) { p in
                    Task { @MainActor in job.progress = p }
                }
                return .success(output)
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let url): job.state = .done(url)
        case .failure(let e):
            if let ee = e as? ExportError, case .cancelled = ee { job.state = .cancelled }
            else { job.state = .failed(e.localizedDescription) }
        }
    }

    private static func run(urls: [URL], settings: SlideshowSettings, options: ExportOptions, output: URL,
                            flag: CancelFlag, progress: @escaping (Double) -> Void) throws {
        let n = urls.count
        guard n > 0 else { throw ExportError.noImages }
        let w = Int(options.size.width), h = Int(options.size.height)
        let fps = options.fps
        let dwell = settings.dwell
        let tr = min(settings.transitionDuration, dwell)
        let total = Int((Double(n) * dwell + tr) * Double(fps) + 0.5)
        let motions = (0..<n).map { _ in KenBurnsMotion.random() }
        let maxPixel = Int(Double(max(w, h)) * 1.3)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let bitrate = Int(Double(w * h * fps) * 0.15)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        guard writer.canAdd(input) else { throw ExportError.writer("入力を追加できません") }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "開始できません") }
        writer.startSession(atSourceTime: .zero)

        // 写真は今のと前のだけ持つ
        var cache: [Int: CGImage] = [:]
        func image(_ k: Int) -> CGImage? {
            if let c = cache[k] { return c }
            let img = ImageLoader.decode(urls[k], maxPixel: maxPixel)
            if let img { cache[k] = img }
            for key in cache.keys where key < k - 1 { cache[key] = nil }
            return img
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let size = CGSize(width: w, height: h)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        for f in 0..<total {
            if flag.isCancelled {
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: output)
                throw ExportError.cancelled
            }
            let t = Double(f) / Double(fps)
            let k = min(n - 1, Int(t / dwell))
            let start = Double(k) * dwell
            let tt = tr > 0 ? min(1, max(0, (t - start) / tr)) : 1
            let eased = TransitionMath.easeInOut(tt)
            var layers: [FrameLayer] = []
            if eased < 1, k > 0, let prev = image(k - 1) {
                let p = min(1, max(0, (t - Double(k - 1) * dwell) / (dwell + tr)))
                layers.append(FrameLayer(image: prev, motion: motions[k - 1], motionProgress: p,
                                         fx: TransitionMath.outgoing(settings.transition, t: eased, width: size.width)))
            }
            if let cur = image(k) {
                var fx = TransitionMath.incoming(settings.transition, t: eased, width: size.width)
                let end = Double(n) * dwell
                if t > end, tr > 0 { fx.opacity *= max(0, 1 - (t - end) / tr) }   // 最後は黒へ
                let p = min(1, max(0, (t - start) / (dwell + tr)))
                layers.append(FrameLayer(image: cur, motion: motions[k], motionProgress: p, fx: fx))
            }

            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBuffer }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw ExportError.pixelBuffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace, bitmapInfo: bitmapInfo) {
                FrameRenderer.draw(layers, in: ctx, size: size, transition: settings.transition, fit: settings.fit)
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))) {
                throw ExportError.writer(writer.error?.localizedDescription ?? "フレームを書けません")
            }
            if f % 10 == 0 { progress(Double(f) / Double(total)) }
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            throw ExportError.writer(writer.error?.localizedDescription ?? "完了できませんでした")
        }
        progress(1)
    }
}
