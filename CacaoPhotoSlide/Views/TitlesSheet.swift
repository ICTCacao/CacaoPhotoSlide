import SwiftUI

/// タイトルの編集。左にタイトルの一覧、右で選んだタイトルを調整する（⇧・⌘で複数選択すると、変更は選んだすべてに効く）
struct TitlesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// 選んでいるタイトル（何も選んでいなければ先頭）
    private var selectedIDs: Set<UUID> {
        let valid = model.selectedTitleIDs.intersection(Set(model.titles.map(\.id)))
        if !valid.isEmpty { return valid }
        return model.titles.first.map { [$0.id] } ?? []
    }

    /// 右で編集しているタイトル（一覧の順で、選んでいる先頭）
    private var active: TitleItem? { model.titles.first { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                listPane
                    .frame(width: 250)
                Divider()
                detailPane
            }
            Divider()
            HStack {
                Text("一覧は ⇧・⌘ クリックで複数選択。右の変更は、選んだすべてに効きます（文字だけは先頭の 1 件）")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 900, height: 680)
    }

    // MARK: 左: 一覧

    private var listPane: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { selectedIDs }, set: { model.selectedTitleIDs = $0 })) {
                ForEach(model.titles) { item in
                    row(item).tag(item.id)
                        .contextMenu {
                            Button("複製") { duplicate(item.id) }
                            Button("削除", role: .destructive) { remove([item.id]) }
                        }
                }
            }
            .listStyle(.inset)
            Divider()
            HStack(spacing: 8) {
                Button {
                    model.addTitle(at: model.playhead)
                } label: { Label("追加", systemImage: "plus") }
                Button { duplicate(active?.id) } label: { Image(systemName: "plus.square.on.square") }
                    .help("選んだタイトルを複製").disabled(active == nil)
                Button(role: .destructive) { remove(selectedIDs) } label: { Image(systemName: "trash") }
                    .help("選んだタイトルを削除").disabled(model.titles.isEmpty)
                Spacer()
                Text("\(model.titles.count) 件").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
    }

    private func row(_ item: TitleItem) -> some View {
        HStack(spacing: 8) {
            Text("T\(item.track + 1)")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.cyan.opacity(0.7), in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text.components(separatedBy: "\n").first.flatMap { $0.isEmpty ? nil : $0 } ?? "（空）")
                    .lineLimit(1)
                Text("\(ExportSheet.clock(item.start)) 〜 \(item.duration > 0 ? ExportSheet.clock(item.start + item.duration) : "最後まで")")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func duplicate(_ id: UUID?) {
        guard let id, let src = model.titles.first(where: { $0.id == id }) else { return }
        var copy = src
        copy.id = UUID()
        copy.start = src.duration > 0 ? src.start + src.duration : src.start + 1
        model.titles.append(copy)
        model.selectedTitleIDs = [copy.id]
    }

    private func remove(_ ids: Set<UUID>) {
        model.titles.removeAll { ids.contains($0.id) }
        model.selectedTitleIDs = []
    }

    // MARK: 右: 調整

    private var detailPane: some View {
        VStack(spacing: 0) {
            preview
                .padding([.top, .horizontal], 14)
            if let item = active {
                ScrollView { editor(item).padding(14) }
            } else {
                Spacer()
                Text("左の「追加」でタイトルを足します").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 選んでいるタイトルだけを見せる（動きは、タイムラインの再生や mp4 で見られる）
    private var preview: some View {
        ZStack {
            Color.black
            if let first = model.photos.first, let cg = model.thumbnails[first] {
                Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit).opacity(0.5)
            }
            TitleOverlay(items: model.titles.filter { selectedIDs.contains($0.id) }, time: nil)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxHeight: 230)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4)))
    }

    /// 選んだすべてに書き込む（文字だけは別）
    private func bind<T>(_ key: WritableKeyPath<TitleItem, T>) -> Binding<T> {
        Binding(
            get: { active?[keyPath: key] ?? TitleItem()[keyPath: key] },
            set: { v in
                let ids = selectedIDs
                for i in model.titles.indices where ids.contains(model.titles[i].id) { model.titles[i][keyPath: key] = v }
            })
    }

    private func editor(_ item: TitleItem) -> some View {
        Form {
            Section {
                if selectedIDs.count > 1 {
                    Text("\(selectedIDs.count) 件を選択中（文字は、先頭の 1 件だけ編集）").font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("文字（改行できます）").font(.callout).foregroundStyle(.secondary)
                    TextField("", text: Binding(
                        get: { active?.text ?? "" },
                        set: { v in if let id = active?.id, let i = model.titles.firstIndex(where: { $0.id == id }) { model.titles[i].text = v } }),
                        axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...4)
                        .multilineTextAlignment(.leading)      // 左寄せで入力する
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Section("位置") {
                Picker("トラック", selection: bind(\.track)) {
                    ForEach(0..<max(1, model.titleTrackCount), id: \.self) { Text("T\($0 + 1)").tag($0) }
                }
                Picker("位置", selection: bind(\.anchor)) {
                    ForEach(TitleAnchor.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("微調整") {
                    HStack(spacing: 14) {
                        nudge("横", bind(\.offsetX))
                        nudge("縦", bind(\.offsetY))
                        Button("元に戻す") {
                            let ids = selectedIDs
                            for i in model.titles.indices where ids.contains(model.titles[i].id) {
                                model.titles[i].offsetX = 0; model.titles[i].offsetY = 0
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            Section("見た目") {
                ColorPicker("色", selection: Binding(
                    get: { active?.swiftUIColor ?? .white },
                    set: { c in
                        let ids = selectedIDs
                        for i in model.titles.indices where ids.contains(model.titles[i].id) { model.titles[i].swiftUIColor = c }
                    }))
                LabeledContent("大きさ") {
                    HStack {
                        Slider(value: bind(\.size), in: 0.02...0.2)
                        PercentField(value: bind(\.size), range: 0.01...0.5)
                            .help("文字の大きさ（画面の高さに対する割合）")
                    }
                }
                Picker("フォント", selection: bind(\.fontName)) {
                    Text("標準").tag("")
                    let rec = TitleFont.recommendedInstalled
                    if !rec.isEmpty {
                        Divider()
                        ForEach(rec, id: \.self) { Text($0).tag($0) }
                    }
                    Divider()
                    ForEach(TitleFont.all.filter { !rec.contains($0) }, id: \.self) { Text($0).tag($0) }
                }
                HStack(spacing: 24) {
                    Toggle("太字", isOn: bind(\.bold))
                    Toggle("影", isOn: bind(\.shadow))
                }
            }
            Section("出る時間") {
                LabeledContent("出す時刻") {
                    HStack {
                        TextField("", value: bind(\.start), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                        Text("秒（スライドショーの頭から）").foregroundStyle(.secondary)
                    }
                }
                Toggle("ずっと表示（出す時刻から最後まで）", isOn: Binding(
                    get: { (active?.duration ?? 5) <= 0 },
                    set: { on in
                        let ids = selectedIDs
                        for i in model.titles.indices where ids.contains(model.titles[i].id) { model.titles[i].duration = on ? 0 : 5 }
                    }))
                LabeledContent("表示する長さ") {
                    HStack {
                        TextField("", value: bind(\.duration), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                            .disabled((active?.duration ?? 5) <= 0)
                        Text("秒").foregroundStyle(.secondary)
                    }
                }
            }
            Section("エフェクト") {
                Picker("出方・消え方", selection: bind(\.effect)) {
                    ForEach(TitleEffect.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("動きの長さ") {
                    HStack {
                        TextField("", value: bind(\.effectDuration), format: .number).frame(width: 70).textFieldStyle(.roundedBorder)
                            .disabled((active?.effect ?? .fade) == .none)
                        Text("秒").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
    }

    /// 位置の微調整。− / + で 0.5 % ずつ（押し続けると連続）。数字でも入力できる。値は画面に対する割合（横は幅、縦は高さ）
    private func nudge(_ label: String, _ value: Binding<Double>) -> some View {
        let step = 0.005
        return HStack(spacing: 4) {
            Text(label)
            Button { value.wrappedValue = max(-0.5, ((value.wrappedValue - step) * 1000).rounded() / 1000) } label: {
                Image(systemName: "minus")
            }
            .buttonRepeatBehavior(.enabled)
            PercentField(value: value, range: -0.5...0.5)
            Button { value.wrappedValue = min(0.5, ((value.wrappedValue + step) * 1000).rounded() / 1000) } label: {
                Image(systemName: "plus")
            }
            .buttonRepeatBehavior(.enabled)
        }
        .controlSize(.small)
        .help(label == "横" ? "− で左へ、+ で右へ" : "− で上へ、+ で下へ")
    }
}
