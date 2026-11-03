import SwiftUI

/// V2（重ねる写真）のライブラリ。V1 の写真とは別に持つ。ここからタイムラインの V2 へドラッグして置く
struct OverlayLibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var anchor: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(Color.secondary.opacity(0.4))
            if model.overlayLibrary.isEmpty { emptyState } else { library }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.on.square")
                .font(.system(size: 52)).foregroundStyle(.secondary)
            Text("ここに V2（重ねる写真）の写真やフォルダをドロップ").font(.title3)
            Text("ロゴ・ワイプ・飾りなど、V1 の写真の上に透明度を付けて重ねる写真のライブラリです")
                .font(.callout).foregroundStyle(.secondary)
            Button("写真を追加…") { model.openOverlayPanel() }.padding(.top, 4)
        }
    }

    private var selectedPaths: [String] { model.overlayLibrary.filter { model.overlaySelection.contains($0) } }

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.on.square").foregroundStyle(.secondary)
                Text("V2 ライブラリ").fontWeight(.semibold)
                Text("\(model.overlayLibrary.count) 枚").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button {
                    place(selectedPaths)
                } label: { Label("タイムラインに置く", systemImage: "arrow.down.to.line") }
                    .controlSize(.small)
                    .disabled(model.overlaySelection.isEmpty)
                    .help("選んだ写真を、再生ヘッドの位置から V2 に置く")
                Button(role: .destructive) {
                    model.removeOverlayLibrary(model.overlaySelection)
                } label: { Label("外す", systemImage: "minus.circle") }
                    .controlSize(.small)
                    .disabled(model.overlaySelection.isEmpty)
                    .help("選んだ写真をライブラリから外す（タイムラインに置いたものも消えます）")
                Button("写真を追加…") { model.openOverlayPanel() }
            }
            Text("クリック: 選ぶ　⌘ / ⇧クリック: 複数　ドラッグ: タイムラインの V2 へ置く　ダブルクリック: 再生ヘッドの位置に置く")
                .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(model.overlayLibrary, id: \.self) { path in cell(path) }
                }
                .padding(2)
            }
        }
        .padding(14)
    }

    private func cell(_ path: String) -> some View {
        let url = URL(fileURLWithPath: path)
        let selected = model.overlaySelection.contains(path)
        let used = model.overlayClips.filter { $0.path == path }.count
        return Button {
            click(path)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                if let cg = model.thumbnails[url] {
                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 84, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3) }
            }
            .overlay(alignment: .topTrailing) {
                if used > 0 {
                    Text("\(used)").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.indigo, in: Capsule()).foregroundStyle(.white).padding(3)
                        .help("タイムラインで \(used) 回使っています")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .draggable(dragPayload(path))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.overlaySelection = [path]
            place([path])
        })
        .help(url.lastPathComponent)
        .contextMenu {
            Button("タイムラインに置く") {
                if !model.overlaySelection.contains(path) { model.overlaySelection = [path] }
                place(selectedPaths)
            }
            Button("ライブラリから外す") {
                model.removeOverlayLibrary(model.overlaySelection.contains(path) ? model.overlaySelection : [path])
            }
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .onAppear { model.requestThumbnail(url: url) }
    }

    /// クリック: その 1 枚。⌘: 追加／解除。⇧: 起点からの範囲を追加
    private func click(_ path: String) {
        let flags = NSEvent.modifierFlags
        let lib = model.overlayLibrary
        if flags.contains(.command) {
            if model.overlaySelection.contains(path) { model.overlaySelection.remove(path) } else { model.overlaySelection.insert(path) }
            anchor = path
        } else if flags.contains(.shift), let a = anchor, let i = lib.firstIndex(of: a), let j = lib.firstIndex(of: path) {
            model.overlaySelection.formUnion(lib[min(i, j)...max(i, j)])
        } else {
            model.overlaySelection = [path]
            anchor = path
        }
    }

    /// ドラッグで運ぶもの（選んでいる写真の 1 枚をつかんだら、選んでいる写真ぜんぶ）
    private func dragPayload(_ path: String) -> String {
        let paths = model.overlaySelection.contains(path) && model.overlaySelection.count >= 2 ? selectedPaths : [path]
        return "v2:" + paths.joined(separator: "\n")
    }

    private func place(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        model.placeOverlays(paths, at: model.playhead)
        model.tab = .preview          // 置いた結果が見えるように、タイムラインのタブへ
    }
}
