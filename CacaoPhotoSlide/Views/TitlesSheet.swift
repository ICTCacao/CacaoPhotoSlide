import SwiftUI

/// タイトルなど、画面に重ねる文字を並べる
struct TitlesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var anchorID: UUID?      // ⇧で範囲を選ぶときの起点

    /// プレビューに出す（選んでいる）タイトル。何も選んでいなければ先頭
    private var selectedIDs: Set<UUID> {
        let valid = model.selectedTitleIDs.intersection(Set(model.titles.map(\.id)))
        if !valid.isEmpty { return valid }
        return model.titles.first.map { [$0.id] } ?? []
    }

    /// 行を押したとき。そのまま: その 1 件。⇧: 起点からの範囲を足す。⌘: 足す／外す
    private func selectRow(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        let ids = model.titles.map(\.id)
        if flags.contains(.shift), let a = anchorID, let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: id) {
            model.selectedTitleIDs = selectedIDs.union(ids[min(i, j)...max(i, j)])
        } else if flags.contains(.command) {
            var s = selectedIDs
            if s.contains(id) { s.remove(id) } else { s.insert(id) }
            model.selectedTitleIDs = s
            anchorID = id
        } else if selectedIDs.contains(id) {
            // すでに選んでいる行の中を触った（値の調整など）ときは、選択をそのまま保つ
            anchorID = id
        } else {
            model.selectedTitleIDs = [id]
            anchorID = id
        }
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            preview
                .padding([.top, .horizontal], 16)
            ScrollView {
                VStack(spacing: 10) {
                    if model.titles.isEmpty {
                        Text("「追加」で文字を足します。位置・大きさ・色・出す時刻を決められます")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach($model.titles) { $item in
                        row($item)
                    }
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button {
                    var item = TitleItem()
                    // 2 つ目からは、重ならないように上に置く
                    if !model.titles.isEmpty { item.anchor = .top; item.size = 0.05 }
                    model.titles.append(item)
                    model.selectedTitleIDs = [item.id]
                } label: { Label("追加", systemImage: "plus") }
                Text("時刻はスライドショーの頭からの秒。⇧・⌘で行を複数選ぶと、プレビューに全部出ます")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 700)
    }

    /// 位置の見当がつくように、最初の写真の上に全部を重ねて見せる
    private var preview: some View {
        ZStack {
            Color.black
            if let first = model.photos.first, let cg = model.thumbnails[first] {
                Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
            // 選んでいるタイトルだけを見せる（⇧・⌘で複数。動きは、タイムラインのプレビューや再生で見られる）
            TitleOverlay(items: model.titles.filter { selectedIDs.contains($0.id) }, time: nil)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4)))
    }

    /// 位置の微調整。− / + で 0.5 % ずつ（押し続けると連続）。値は画面に対する割合（横は幅、縦は高さ）
    private func nudge(_ label: String, _ value: Binding<Double>) -> some View {
        let step = 0.005
        return HStack(spacing: 4) {
            Text(label)
            Button { value.wrappedValue = max(-0.5, ((value.wrappedValue - step) * 1000).rounded() / 1000) } label: {
                Image(systemName: "minus")
            }
            .buttonRepeatBehavior(.enabled)
            Text(String(format: "%+.1f %%", value.wrappedValue * 100))
                .monospacedDigit().frame(width: 62)
            Button { value.wrappedValue = min(0.5, ((value.wrappedValue + step) * 1000).rounded() / 1000) } label: {
                Image(systemName: "plus")
            }
            .buttonRepeatBehavior(.enabled)
        }
        .controlSize(.small)
        .help(label == "横" ? "− で左へ、+ で右へ" : "− で上へ、+ で下へ")
    }

    private func row(_ item: Binding<TitleItem>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                TextField("文字（改行できます）", text: item.text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    model.titles.removeAll { $0.id == item.wrappedValue.id }
                } label: { Image(systemName: "trash") }
                    .help("この文字を消す")
            }
            HStack(spacing: 14) {
                Picker("位置", selection: item.anchor) {
                    ForEach(TitleAnchor.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 130)
                ColorPicker("色", selection: Binding(get: { item.wrappedValue.swiftUIColor },
                                                   set: { item.wrappedValue.swiftUIColor = $0 }))
                Toggle("太字", isOn: item.bold)
                Toggle("影", isOn: item.shadow)
                Spacer()
            }
            HStack(spacing: 14) {
                Text("大きさ")
                Slider(value: item.size, in: 0.02...0.2)
                    .frame(width: 140)
                Text("出す時刻")
                TextField("", value: item.start, format: .number)
                    .frame(width: 52).textFieldStyle(.roundedBorder)
                Text("秒　から")
                TextField("", value: item.duration, format: .number)
                    .frame(width: 52).textFieldStyle(.roundedBorder)
                    .disabled(item.wrappedValue.duration <= 0)
                Text("秒間")
                Toggle("ずっと表示", isOn: Binding(
                    get: { item.wrappedValue.duration <= 0 },
                    set: { item.wrappedValue.duration = $0 ? 0 : 5 }))
                Spacer()
            }
            HStack(spacing: 14) {
                Text("微調整")
                nudge("横", item.offsetX)
                nudge("縦", item.offsetY)
                Button("元に戻す") { item.wrappedValue.offsetX = 0; item.wrappedValue.offsetY = 0 }
                    .controlSize(.small)
                    .disabled(item.wrappedValue.offsetX == 0 && item.wrappedValue.offsetY == 0)
                Spacer()
            }
            HStack(spacing: 14) {
                Picker("エフェクト", selection: item.effect) {
                    ForEach(TitleEffect.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 270)
                Text("長さ")
                TextField("", value: item.effectDuration, format: .number)
                    .frame(width: 52).textFieldStyle(.roundedBorder)
                    .disabled(item.wrappedValue.effect == .none)
                Text("秒")
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.accentColor, lineWidth: selectedIDs.contains(item.wrappedValue.id) ? 2 : 0))
        .simultaneousGesture(TapGesture().onEnded { selectRow(item.wrappedValue.id) })
    }
}
