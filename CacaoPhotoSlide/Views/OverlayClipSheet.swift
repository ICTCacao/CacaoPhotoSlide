import SwiftUI

/// V2 のクリップ 1 つの設定（透明度・大きさ・位置・フェード・開始と長さ）
struct OverlayClipSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?

    private var clip: OverlayClip? { model.editingOverlay.flatMap { id in model.overlayClips.first { $0.id == id } } }

    var body: some View {
        if let clip {
            content(clip)
        } else {
            Text("このクリップはありません").padding(40).onAppear { dismiss() }
        }
    }

    /// 選んでいる V2 クリップが複数なら、変更は選んだすべてに効く（group が false の項目は、開いている 1 件だけ）
    private func bind<T>(_ clip: OverlayClip, _ key: WritableKeyPath<OverlayClip, T>, group: Bool = true) -> Binding<T> {
        let id = clip.id
        return Binding(
            get: { model.overlayClips.first { $0.id == id }?[keyPath: key] ?? clip[keyPath: key] },
            set: { v in
                let ids = group && model.selectedOverlays.contains(id) ? model.selectedOverlays : [id]
                for target in ids { model.updateOverlay(target) { $0[keyPath: key] = v } }
            })
    }

    /// 値を持つ項目（nil なら設定のタブの値に従う）。選んでいるすべてに効く
    private func setBinding<T>(_ clip: OverlayClip, _ key: WritableKeyPath<OverlayClip, T?>, fallback: T) -> Binding<T> {
        let id = clip.id
        return Binding(
            get: { model.overlayClips.first { $0.id == id }?[keyPath: key] ?? fallback },
            set: { v in
                let ids = model.selectedOverlays.contains(id) ? model.selectedOverlays : [id]
                for target in ids { model.updateOverlay(target) { $0[keyPath: key] = v } }
            })
    }

    /// 「変える」のオン・オフ。オンにすると on の値、オフにすると nil（設定のタブの値に従う）
    private func optionalToggle<T>(_ clip: OverlayClip, _ key: WritableKeyPath<OverlayClip, T?>, on value: T) -> Binding<Bool> {
        let id = clip.id
        return Binding(
            get: { model.overlayClips.first { $0.id == id }?[keyPath: key] != nil },
            set: { isOn in
                let ids = model.selectedOverlays.contains(id) ? model.selectedOverlays : [id]
                for target in ids { model.updateOverlay(target) { $0[keyPath: key] = isOn ? value : nil } }
            })
    }

    private func content(_ clip: OverlayClip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(URL(fileURLWithPath: clip.path).lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
            if model.selectedOverlays.count > 1, model.selectedOverlays.contains(clip.id) {
                Text("\(model.selectedOverlays.count) 件を選択中。変更は選んだすべてに効きます（開始の時刻だけは、この 1 件）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // 見え方: V1 の代わりに黒を敷いて、透明度と大きさ・位置を見せる
            ZStack {
                Color(white: 0.25)
                if let image {
                    GeometryReader { geo in
                        Image(decorative: image, scale: 1)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .scaleEffect(clip.scale)
                            .offset(x: clip.offsetX * geo.size.width, y: clip.offsetY * geo.size.height)
                            .opacity(clip.opacity)
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4)))

            Form {
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: bind(clip, \.opacity), in: 0...1)
                        PercentField(value: bind(clip, \.opacity), range: 0...1)
                    }
                }
                LabeledContent("大きさ") {
                    HStack {
                        Slider(value: bind(clip, \.scale), in: 0.1...2)
                        PercentField(value: bind(clip, \.scale), range: 0.05...4)
                    }
                }
                LabeledContent("位置の微調整") {
                    HStack(spacing: 14) {
                        nudge("横", bind(clip, \.offsetX))
                        nudge("縦", bind(clip, \.offsetY))
                        Button("元に戻す") {
                            let ids = model.selectedOverlays.contains(clip.id) ? model.selectedOverlays : [clip.id]
                            for t in ids { model.updateOverlay(t) { $0.offsetX = 0; $0.offsetY = 0; $0.scale = 1 } }
                        }
                            .controlSize(.small)
                    }
                }
                LabeledContent {
                    Picker("", selection: setBinding(clip, \.transition, fallback: model.transition == .none ? .crossfade : model.transition)) {
                        ForEach(Transition.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().disabled(clip.transition == nil)
                } label: {
                    Toggle("エフェクトを変える", isOn: optionalToggle(clip, \.transition, on: model.transition == .none ? .crossfade : model.transition))
                }
                LabeledContent {
                    Picker("", selection: setBinding(clip, \.fit, fallback: model.fit)) {
                        ForEach(FitMode.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 220).disabled(clip.fit == nil)
                } label: {
                    Toggle("表示の仕方を変える", isOn: optionalToggle(clip, \.fit, on: model.fit))
                }
                LabeledContent("開始と長さ") {
                    HStack {
                        TextField("", value: bind(clip, \.start, group: false), format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                        Text("秒 から")
                        TextField("", value: bind(clip, \.duration), format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                        Text("秒間")
                    }
                }
                LabeledContent("切り替えの長さ") {
                    HStack {
                        Text("イン").fixedSize()
                        TextField("", value: bind(clip, \.fadeIn), format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                        Text("秒").fixedSize()
                        Text("　アウト").fixedSize()
                        TextField("", value: bind(clip, \.fadeOut), format: .number).frame(width: 52).textFieldStyle(.roundedBorder)
                        Text("秒").fixedSize()
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Button(role: .destructive) {
                    model.removeOverlayClip(clip.id)
                    dismiss()
                } label: { Label("このクリップを消す", systemImage: "trash") }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640)
        .task(id: clip.path) {
            let url = URL(fileURLWithPath: clip.path)
            image = await Task.detached(priority: .userInitiated) { ImageLoader.decode(url, maxPixel: 900) }.value
        }
    }

    /// − / + で 0.5 % ずつ（押し続けると連続）
    private func nudge(_ label: String, _ value: Binding<Double>) -> some View {
        let step = 0.005
        return HStack(spacing: 4) {
            Text(label)
            Button { value.wrappedValue = max(-0.5, ((value.wrappedValue - step) * 1000).rounded() / 1000) } label: { Image(systemName: "minus") }
                .buttonRepeatBehavior(.enabled)
            PercentField(value: value, range: -0.5...0.5)
            Button { value.wrappedValue = min(0.5, ((value.wrappedValue + step) * 1000).rounded() / 1000) } label: { Image(systemName: "plus") }
                .buttonRepeatBehavior(.enabled)
        }
        .controlSize(.small)
    }
}
