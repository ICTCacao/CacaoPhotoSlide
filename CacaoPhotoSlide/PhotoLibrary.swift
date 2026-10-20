import Foundation
import ImageIO
import UniformTypeIdentifiers

/// フォルダから写真を集めて並べる
enum PhotoLibrary {
    static func isImage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        // SVG は public.image だが ImageIO で読めないので外す
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    /// ドロップされたフォルダ・ファイルから画像だけを集める
    static func collect(from sources: [URL], recursive: Bool, order: PhotoOrder) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for src in sources {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                var opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
                if !recursive { opts.insert(.skipsSubdirectoryDescendants) }
                guard let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey], options: opts) else { continue }
                for case let u as URL in e {
                    guard (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                    if isImage(u) { out.append(u) }
                }
            } else if isImage(src) {
                out.append(src)
            }
        }
        return sorted(out, by: order)
    }

    static func sorted(_ urls: [URL], by order: PhotoOrder) -> [URL] {
        func byName(_ a: URL, _ b: URL) -> Bool { a.path.localizedStandardCompare(b.path) == .orderedAscending }
        switch order {
        case .name, .random:
            // ランダムは開始のたびにシャッフルするので、ここでは名前順
            return urls.sorted(by: byName)
        case .date:
            let dated = urls.map { ($0, captureDate($0)) }
            return dated.sorted { a, b in a.1 == b.1 ? byName(a.0, b.0) : a.1 < b.1 }.map(\.0)
        }
    }

    /// EXIF の撮影日時。なければファイルの作成日
    static func captureDate(_ url: URL) -> Date {
        if let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let s = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String,
           let d = exifFormatter.date(from: s) {
            return d
        }
        let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return v?.creationDate ?? v?.contentModificationDate ?? .distantPast
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
}
