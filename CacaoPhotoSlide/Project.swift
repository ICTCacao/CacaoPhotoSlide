import Foundation
import UniformTypeIdentifiers

/// タイムラインに置いた音声 1 本
struct MusicClip: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String              // 表示名（元のファイル名）
    var path: String              // 音声ファイル。書類の中なら "audio/xxx.mp3" の相対、それ以外は絶対
    var start: TimeInterval       // タイムライン上の開始秒
    var duration: TimeInterval    // 音源の長さ（秒）
    var inPoint: TimeInterval = 0          // 曲の中の開始位置（秒）
    var outPoint: TimeInterval? = nil      // 曲の中の終了位置（秒）。nil なら最後まで
    var track = 0                          // タイムラインの段（0 が一番上）。段を分ければ重ねて置ける
    var volume: Double = 0.8
    var fadeIn: TimeInterval = 0
    var fadeOut: TimeInterval = 2

    init(name: String, path: String, start: TimeInterval, duration: TimeInterval,
         volume: Double = 0.8, fadeIn: TimeInterval = 0, fadeOut: TimeInterval = 2) {
        self.name = name; self.path = path; self.start = start; self.duration = duration
        self.volume = volume; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }

    /// 古い書類（inPoint / outPoint がない）も読めるように
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        start = try c.decode(TimeInterval.self, forKey: .start)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        inPoint = try c.decodeIfPresent(TimeInterval.self, forKey: .inPoint) ?? 0
        outPoint = try c.decodeIfPresent(TimeInterval.self, forKey: .outPoint)
        track = try c.decodeIfPresent(Int.self, forKey: .track) ?? 0
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 0.8
        fadeIn = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeIn) ?? 0
        fadeOut = try c.decodeIfPresent(TimeInterval.self, forKey: .fadeOut) ?? 2
    }

    /// 使う範囲の終わり（曲の中の秒）
    var effectiveOut: TimeInterval { min(outPoint ?? duration, duration) }
    /// 使う長さ（秒）
    var length: TimeInterval { max(0, effectiveOut - inPoint) }
    /// タイムライン上の終わり
    var end: TimeInterval { start + length }

    /// 実際のファイルの場所（書類の場所を渡すと相対パスを解決する）
    func url(in document: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let document { return document.appendingPathComponent(path) }
        return URL(fileURLWithPath: path)
    }

    static func isAudio(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return t.conforms(to: .audio)
    }
}

/// .cpsd の中の project.json
struct ProjectFile: Codable {
    var version = 1
    var sources: [String] = []        // 写真のフォルダ（絶対パス）
    var selection: [String] = []      // 選んだ写真（絶対パス）
    var dwell: Double = 5
    var transition = Transition.kenBurns.rawValue
    var transitionDuration: Double = 1.5
    var order = PhotoOrder.name.rawValue
    var loop = true
    var recursive = true
    var fit = FitMode.fit.rawValue
    var exportSize = ExportSize.hd1080.rawValue
    var exportFps = 30
    var clips: [MusicClip] = []
    var includesPhotos = false        // true なら photos/ に写真のコピーがあり、それを写真の元にする
    var excluded: [String] = []       // パネルで外した写真（絶対パス）。流さず、書類にもコピーしない

    init() {}

    /// 項目が増えても古い書類を読めるように、無いものは既定値
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
        selection = try c.decodeIfPresent([String].self, forKey: .selection) ?? []
        dwell = try c.decodeIfPresent(Double.self, forKey: .dwell) ?? 5
        transition = try c.decodeIfPresent(String.self, forKey: .transition) ?? Transition.kenBurns.rawValue
        transitionDuration = try c.decodeIfPresent(Double.self, forKey: .transitionDuration) ?? 1.5
        order = try c.decodeIfPresent(String.self, forKey: .order) ?? PhotoOrder.name.rawValue
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? true
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? true
        fit = try c.decodeIfPresent(String.self, forKey: .fit) ?? FitMode.fit.rawValue
        exportSize = try c.decodeIfPresent(String.self, forKey: .exportSize) ?? ExportSize.hd1080.rawValue
        exportFps = try c.decodeIfPresent(Int.self, forKey: .exportFps) ?? 30
        clips = try c.decodeIfPresent([MusicClip].self, forKey: .clips) ?? []
        includesPhotos = try c.decodeIfPresent(Bool.self, forKey: .includesPhotos) ?? false
        excluded = try c.decodeIfPresent([String].self, forKey: .excluded) ?? []
    }
}

/// フォルダ形式の書類 .cpsd（project.json + audio/）
enum ProjectDocument {
    static let pathExtension = "cpsd"
    static let type = UTType(exportedAs: "com.ictcacao.cacaophotoslide.cpsd", conformingTo: .package)

    static func isDocument(_ url: URL) -> Bool { url.pathExtension.lowercased() == pathExtension }

    /// 書く。音声ファイルは audio/ にコピーして相対パスにする。使われなくなった音声は消す。
    /// photos を渡すと、その順番で photos/ にコピーし（0001_ の連番で順番を保つ）、selected は書類の中の相対パスで記録する
    static func save(_ project: ProjectFile, to url: URL, photos: [URL]? = nil, selected: [URL] = [],
                     progress: ((Int, Int) -> Void)? = nil) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let audioDir = url.appendingPathComponent("audio")
        try fm.createDirectory(at: audioDir, withIntermediateDirectories: true)
        var file = project
        if let photos {
            let photosDir = url.appendingPathComponent("photos")
            try fm.createDirectory(at: photosDir, withIntermediateDirectories: true)
            var names: [String] = []
            var map: [URL: String] = [:]
            for (i, src) in photos.enumerated() {
                progress?(i, photos.count)
                let name: String
                if src.standardizedFileURL.deletingLastPathComponent() == photosDir.standardizedFileURL {
                    name = src.lastPathComponent        // すでに書類の中
                } else {
                    name = String(format: "%04d_%@", i + 1, src.lastPathComponent)
                    let dest = photosDir.appendingPathComponent(name)
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: src, to: dest)
                }
                names.append(name)
                map[src.standardizedFileURL] = name
            }
            let keep = Set(names)
            for item in (try? fm.contentsOfDirectory(atPath: photosDir.path)) ?? [] where !keep.contains(item) {
                try? fm.removeItem(at: photosDir.appendingPathComponent(item))
            }
            file.includesPhotos = true
            file.selection = selected.compactMap { map[$0.standardizedFileURL] }.map { "photos/\($0)" }
        } else {
            file.includesPhotos = false
            try? fm.removeItem(at: url.appendingPathComponent("photos"))
        }
        var used: Set<String> = []
        for i in file.clips.indices {
            let clip = file.clips[i]
            let src = clip.url(in: url)
            var destName = src.lastPathComponent
            var dest = audioDir.appendingPathComponent(destName)
            if src.standardizedFileURL != dest.standardizedFileURL {
                // 同名で別のファイルがあれば番号を付ける
                var n = 2
                while fm.fileExists(atPath: dest.path), !fm.contentsEqual(atPath: src.path, andPath: dest.path) {
                    destName = "\(src.deletingPathExtension().lastPathComponent)-\(n).\(src.pathExtension)"
                    dest = audioDir.appendingPathComponent(destName)
                    n += 1
                }
                if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: src, to: dest) }
            }
            file.clips[i].path = "audio/\(destName)"
            used.insert(destName)
        }
        for item in (try? fm.contentsOfDirectory(atPath: audioDir.path)) ?? [] where !used.contains(item) {
            try? fm.removeItem(at: audioDir.appendingPathComponent(item))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(file).write(to: url.appendingPathComponent("project.json"), options: .atomic)
    }

    static func load(from url: URL) throws -> ProjectFile {
        let data = try Data(contentsOf: url.appendingPathComponent("project.json"))
        return try JSONDecoder().decode(ProjectFile.self, from: data)
    }
}
