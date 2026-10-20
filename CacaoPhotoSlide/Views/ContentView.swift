import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            dropZone
            settings(Bindable(model))
            footer
        }
        .padding(18)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in handleDrop(providers) }
    }

    // MARK: ドロップ先

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(targeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.4))
            if model.photos.isEmpty && !model.isScanning {
                emptyState
            } else {
                photoSummary
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("ここに写真のフォルダをドロップ")
                .font(.title3)
            if let m = model.message {
                Text(m).foregroundStyle(.secondary)
            }
            Button("開く…") { model.openPanel() }
                .padding(.top, 4)
        }
    }

    private var photoSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(sourceTitle)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("読み込み中…").foregroundStyle(.secondary)
                } else {
                    Text("\(model.photos.count) 枚").monospacedDigit().fontWeight(.semibold)
                }
                Button("開く…") { model.openPanel() }
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                    ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, cg in
                        ZStack {
                            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                            if let cg {
                                Image(decorative: cg, scale: 1)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                if model.photos.count > model.thumbnails.count {
                    Text("ほか \(model.photos.count - model.thumbnails.count) 枚")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                }
            }
        }
        .padding(14)
    }

    private var sourceTitle: String {
        let names = model.sources.map(\.lastPathComponent)
        if names.count <= 2 { return names.joined(separator: "、") }
        return "\(names[0]) ほか \(names.count - 1) 件"
    }

    // MARK: 設定

    private func settings(_ model: Bindable<AppModel>) -> some View {
        Form {
            LabeledContent("表示時間") {
                HStack {
                    Slider(value: model.dwell, in: 1...30, step: 1)
                    Text("\(Int(model.dwell.wrappedValue)) 秒")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Picker("切り替え", selection: model.transition) {
                ForEach(Transition.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("切り替えの長さ") {
                HStack {
                    Slider(value: model.transitionDuration, in: 0.3...3, step: 0.1)
                    Text(String(format: "%.1f 秒", model.transitionDuration.wrappedValue))
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            .disabled(model.transition.wrappedValue == .none)
            Picker("順番", selection: model.order) {
                ForEach(PhotoOrder.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("表示", selection: model.fit) {
                ForEach(FitMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 24) {
                Toggle("繰り返す", isOn: model.loop)
                Toggle("サブフォルダも含める", isOn: model.recursive)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .frame(height: 292)
    }

    // MARK: 下段

    private var footer: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Space  停止 / 再開　　←  →  前へ / 次へ")
                Text("Esc  終了")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.startSlideshow()
            } label: {
                Label("スライドショーを開始", systemImage: "play.fill")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.photos.isEmpty || model.isScanning || model.isShowing)
        }
    }

    // MARK: ドロップ

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let targets = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !targets.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in targets {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.load(urls)
        }
        return true
    }
}
