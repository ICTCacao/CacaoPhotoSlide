import SwiftUI

/// 選んだ写真だけ、表示時間・エフェクト（切り替え）・表示の仕方（全体を表示／画面いっぱい）を変える。変えない項目は全体の設定のまま
struct PhotoOverrideSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var indices: [Int] = []
    @State private var useDwell = false
    @State private var dwell: Double = 5
    @State private var useTransition = false
    @State private var transition: Transition = .crossfade
    @State private var image: CGImage?
    @State private var useFit = false
    @State private var fit: FitMode = .fit

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
            photoPreview
            thumbnails
            Form {
                LabeledContent {
                    HStack {
                        TextField("", value: $dwell, format: .number)
                            .frame(width: 60).textFieldStyle(.roundedBorder)
                            .disabled(!useDwell)
                        Stepper("", value: $dwell, in: 0.3...300, step: 0.5).labelsHidden().disabled(!useDwell)
                        Text("秒").foregroundStyle(.secondary)
                    }
                } label: {
                    Toggle("表示時間を変える", isOn: $useDwell)
                }
                LabeledContent {
                    Picker("", selection: $transition) {
                        ForEach(Transition.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().disabled(!useTransition)
                } label: {
                    Toggle("エフェクトを変える", isOn: $useTransition)
                }
                LabeledContent {
                    Picker("", selection: $fit) {
                        ForEach(FitMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220).disabled(!useFit)
                } label: {
                    Toggle("表示の仕方を変える", isOn: $useFit)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Text("オフの項目は、設定のタブの値（表示時間 \(ContentView.seconds(model.dwell))、\(model.transition.label)、\(model.fit.label)）に従います。エフェクトは、その写真が出てくるときの切り替えです。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("個別設定を外す") {
                    model.setOverride(indices, dwell: nil, transition: nil, fit: nil)
                    dismiss()
                }
                .disabled(!hasAny)
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("適用") {
                    model.setOverride(indices, dwell: useDwell ? max(0.3, dwell) : nil,
                                      transition: useTransition ? transition : nil,
                                      fit: useFit ? fit : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    /// 対象の写真のサムネイル。1 枚なら大きく、複数なら先頭から並べる（残りは枚数で示す）
    private var thumbnails: some View {
        let urls = indices.filter { model.photos.indices.contains($0) }.map { model.photos[$0] }
        let single = urls.count == 1
        let shown = Array(urls.prefix(single ? 1 : 6))
        return HStack(spacing: 8) {
            Spacer(minLength: 0)
            ForEach(shown, id: \.self) { url in
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15))
                    if let cg = model.thumbnails[url] {
                        Image(decorative: cg, scale: 1).resizable()
                            .aspectRatio(contentMode: single ? .fit : .fill)
                    }
                }
                .frame(width: single ? 240 : 64, height: single ? 135 : 64)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            if urls.count > shown.count {
                Text("ほか \(urls.count - shown.count) 枚").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 先頭の写真を大きく。複数選んでいるときは、小さいサムネイルも並べる
    private var photoPreview: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if indices.count > 1 {
                HStack(spacing: 4) {
                    ForEach(indices.prefix(12), id: \.self) { i in
                        if model.photos.indices.contains(i), let cg = model.thumbnails[model.photos[i]] {
                            Image(decorative: cg, scale: 1)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)).frame(width: 36, height: 36)
                        }
                    }
                    if indices.count > 12 {
                        Text("ほか \(indices.count - 12) 枚").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .task(id: indices.first) {
            guard let i = indices.first, model.photos.indices.contains(i) else { return }
            let url = model.photos[i]
            image = await Task.detached(priority: .userInitiated) { ImageLoader.decode(url, maxPixel: 900) }.value
        }
    }

    private var title: String {
        if indices.count == 1, model.photos.indices.contains(indices[0]) {
            return "\(indices[0] + 1) 枚目  \(model.photos[indices[0]].lastPathComponent)"
        }
        return "選んだ \(indices.count) 枚"
    }

    private var hasAny: Bool {
        indices.contains { model.photos.indices.contains($0) && !(model.overrides[model.photos[$0].path]?.isEmpty ?? true) }
    }

    /// 最初の写真の今の個別設定を出しておく
    private func load() {
        indices = model.selection.sorted()
        for i in indices.prefix(6) { model.requestThumbnail(i) }
        let first = indices.first.flatMap { model.photos.indices.contains($0) ? model.overrides[model.photos[$0].path] : nil }
        useDwell = first?.dwell != nil
        dwell = first?.dwell ?? model.dwell
        useTransition = first?.transition != nil
        transition = first?.transition ?? (model.transition == .none ? .crossfade : model.transition)
        useFit = first?.fit != nil
        fit = first?.fit ?? model.fit
    }
}
