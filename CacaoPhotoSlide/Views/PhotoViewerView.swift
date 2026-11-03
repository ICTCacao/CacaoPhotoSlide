import SwiftUI
import ImageIO

/// 写真を大きく見る。← → で前後、順番の入れ替えもここからできる
struct PhotoViewerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var image: CGImage?
    @State private var info: String = ""
    @State private var loading = false

    private var index: Int { model.viewerIndex ?? 0 }
    private var url: URL? { model.photos.indices.contains(index) ? model.photos[index] : nil }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if loading {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .frame(minWidth: 640, idealWidth: 900, minHeight: 480, idealHeight: 700)
        .task(id: url) { await load() }
        .onChange(of: model.viewerIndex) { _, new in if new == nil { dismiss() } }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index <= 0)
                .help("前の写真（←）")
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index >= model.photos.count - 1)
                .help("次の写真（→）")
            VStack(alignment: .leading, spacing: 2) {
                Text(url?.lastPathComponent ?? "").lineLimit(1).truncationMode(.middle)
                Text("\(index + 1) / \(model.photos.count)　\(info)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button {
                model.viewerIndex = model.movePhoto(index, by: -1)
            } label: { Label("前へ", systemImage: "arrow.left.to.line") }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .disabled(index <= 0)
                .help("この写真を 1 つ前に動かす（⌥←）")
            Button {
                model.viewerIndex = model.movePhoto(index, by: 1)
            } label: { Label("後ろへ", systemImage: "arrow.right.to.line") }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .disabled(index >= model.photos.count - 1)
                .help("この写真を 1 つ後ろに動かす（⌥→）")
            Button {
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } label: { Image(systemName: "folder") }
                .help("Finder で表示")
            Button(role: .destructive) {
                model.removePhoto(index)
            } label: { Image(systemName: "trash") }
                .help("この写真を外す")
            Button("閉じる") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
        .background(.bar)
    }

    private func step(_ d: Int) {
        let n = index + d
        guard model.photos.indices.contains(n) else { return }
        model.showViewer(n)
    }

    private func load() async {
        guard let url else { image = nil; info = ""; return }
        loading = true
        let result = await Task.detached(priority: .userInitiated) { () -> (CGImage?, String) in
            let img = ImageLoader.decode(url, maxPixel: 3200)
            var parts: [String] = []
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
               let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int {
                parts.append("\(w)×\(h)")
            }
            let d = PhotoLibrary.captureDate(url)
            if d != .distantPast {
                parts.append(d.formatted(date: .numeric, time: .shortened))
            }
            return (img, parts.joined(separator: "　"))
        }.value
        guard !Task.isCancelled else { return }
        image = result.0
        info = result.1
        loading = false
    }
}
