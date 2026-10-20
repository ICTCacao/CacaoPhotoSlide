import AVFoundation
import Foundation

/// 曲の波形（山の高さ 0〜1 を buckets 個）。曲の範囲をつまむ帯の下に描く
enum Waveform {
    static func peaks(url: URL, buckets: Int = 800) -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        var samples: [Float] = []
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
                  let p = ptr else { continue }
            let n = length / 4
            p.withMemoryRebound(to: Float.self, capacity: n) { fp in
                samples.append(contentsOf: UnsafeBufferPointer(start: fp, count: n))
            }
        }
        guard !samples.isEmpty else { return nil }
        let per = max(1, samples.count / buckets)
        var peaks: [Float] = []
        peaks.reserveCapacity(buckets)
        var i = 0
        while i < samples.count {
            var m: Float = 0
            let end = min(samples.count, i + per)
            for j in i..<end { m = max(m, abs(samples[j])) }
            peaks.append(m)
            i = end
        }
        let top = max(peaks.max() ?? 1, 0.01)
        return peaks.map { min(1, $0 / top) }
    }
}
