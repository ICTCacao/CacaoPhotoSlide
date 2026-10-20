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

/// 書き出しに入れるクリップ（トラックは先に読んでおく。track は asset を弱参照しかしないので asset も持つ）
struct MusicSource {
    let clip: MusicClip
    let asset: AVURLAsset
    let track: AVAssetTrack
    let duration: CMTime
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
        // クリップのトラックは先に読んでおく（読めないものは飛ばす）
        var music: [MusicSource] = []
        for clip in settings.clips {
            let asset = AVURLAsset(url: clip.url(in: settings.document))
            if let track = try? await asset.loadTracks(withMediaType: .audio).first,
               let duration = try? await asset.load(.duration), duration.seconds > 0.1 {
                music.append(MusicSource(clip: clip, asset: asset, track: track, duration: duration))
            }
        }
        let musicSources = music
        let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try run(urls: urls, settings: settings, options: options, music: musicSources, output: output, flag: flag) { p in
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

    private static func run(urls: [URL], settings: SlideshowSettings, options: ExportOptions, music: [MusicSource], output: URL,
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

        // 音声: クリップごとに合成トラックを作って置き、音量とフェードのカーブを掛けてミックスし、PCM で読んで AAC で書く
        let videoDuration = CMTime(value: CMTimeValue(total), timescale: CMTimeScale(fps))
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        if !music.isEmpty {
            let comp = AVMutableComposition()
            var params: [AVMutableAudioMixInputParameters] = []
            var tracks: [AVCompositionTrack] = []
            for m in music where m.clip.start < videoDuration.seconds {
                guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let start = CMTime(seconds: m.clip.start, preferredTimescale: 600)
                let inPoint = CMTime(seconds: min(m.clip.inPoint, m.duration.seconds), preferredTimescale: 600)
                let usable = CMTime(seconds: max(0, min(m.clip.effectiveOut, m.duration.seconds) - inPoint.seconds), preferredTimescale: 600)
                let len = CMTimeMinimum(usable, CMTimeSubtract(videoDuration, start))
                guard len.seconds > 0.05 else { continue }
                do {
                    try track.insertTimeRange(CMTimeRange(start: inPoint, duration: len), of: m.track, at: start)
                } catch {
                    NSLog("CacaoPhotoSlide: 音声を置けません %@: %@", m.clip.name, error.localizedDescription)
                    continue
                }
                let p = AVMutableAudioMixInputParameters(track: track)
                let vol = Float(m.clip.volume)
                p.setVolume(vol, at: .zero)
                let end = CMTimeAdd(start, len)
                if m.clip.fadeIn > 0 {
                    let fi = CMTime(seconds: min(m.clip.fadeIn, len.seconds / 2), preferredTimescale: 600)
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: start, duration: fi))
                }
                // 動画の終わりで切れるクリップは 3 秒で、そうでなければ指定のフェードアウト
                let cut = CMTimeCompare(end, videoDuration) >= 0
                let foSec = min(cut ? 3.0 : m.clip.fadeOut, len.seconds / 2)
                if foSec > 0 {
                    let fo = CMTime(seconds: foSec, preferredTimescale: 600)
                    p.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0, timeRange: CMTimeRange(start: CMTimeSubtract(end, fo), duration: fo))
                }
                params.append(p)
                tracks.append(track)
            }
            if tracks.isEmpty { NSLog("CacaoPhotoSlide: 音声トラックなし") }
            if !tracks.isEmpty, let reader = try? AVAssetReader(asset: comp) {
                let mix = AVMutableAudioMix()
                mix.inputParameters = params
                let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ])
                out.audioMix = mix
                let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ])
                ain.expectsMediaDataInRealTime = false
                if reader.canAdd(out), writer.canAdd(ain) {
                    reader.add(out)
                    writer.add(ain)
                    audioReader = reader
                    audioOutput = out
                    audioInput = ain
                } else {
                    NSLog("CacaoPhotoSlide: 音声の読み書きを追加できません canAddOut=%d canAddIn=%d", reader.canAdd(out), writer.canAdd(ain))
                }
            }
        }

        guard writer.startWriting() else { throw ExportError.writer(writer.error?.localizedDescription ?? "開始できません") }
        writer.startSession(atSourceTime: .zero)
        if let r = audioReader, !r.startReading() {
            NSLog("CacaoPhotoSlide: 音声を読み始められません: %@", r.error?.localizedDescription ?? "?")
            audioReader = nil; audioOutput = nil; audioInput?.markAsFinished()
        }

        // 音声は映像より少し先まで書いておく（インターリーブ）
        var audioDone = audioOutput == nil
        var audioTime = CMTime.zero
        func feedAudio(upTo limit: CMTime) {
            guard !audioDone, let out = audioOutput, let ain = audioInput else { return }
            while audioTime < limit {
                guard ain.isReadyForMoreMediaData else { usleep(2000); continue }
                guard let sb = out.copyNextSampleBuffer() else {
                    if let r = audioReader, r.status == .failed { NSLog("CacaoPhotoSlide: 音声の読み込みに失敗: %@", r.error?.localizedDescription ?? "?") }
                    ain.markAsFinished(); audioDone = true; return
                }
                audioTime = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sb), CMSampleBufferGetDuration(sb))
                if !ain.append(sb) { ain.markAsFinished(); audioDone = true; return }
            }
        }

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
            feedAudio(upTo: CMTimeAdd(CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)), CMTime(seconds: 1, preferredTimescale: 600)))
            if f % 10 == 0 { progress(Double(f) / Double(total)) }
        }
        input.markAsFinished()
        feedAudio(upTo: CMTimeAdd(videoDuration, CMTime(seconds: 1, preferredTimescale: 600)))
        if !audioDone { audioInput?.markAsFinished() }
        audioReader?.cancelReading()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        if writer.status != .completed {
            throw ExportError.writer(writer.error?.localizedDescription ?? "完了できませんでした")
        }
        progress(1)
    }
}
