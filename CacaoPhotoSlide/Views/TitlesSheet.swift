import SwiftUI

/// タイトルなど、画面に重ねる文字を並べる
struct TitlesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

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
                } label: { Label("追加", systemImage: "plus") }
                Text("時刻はスライドショーの頭からの秒。「ずっと表示」は、出す時刻から最後まで")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 640)
    }

    /// 位置の見当がつくように、最初の写真の上に全部を重ねて見せる
    private var preview: some View {
        ZStack {
            Color.black
            if let first = model.photos.first, let cg = model.thumbnails[first] {
                Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
            TitleOverlay(items: model.titles, time: nil)
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxHeight: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4)))
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
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
