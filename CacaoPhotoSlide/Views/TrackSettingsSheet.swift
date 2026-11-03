import SwiftUI

/// トラック 1 本ぶんの設定。T・V1・V2 以上は透過率と表示、A は音量とミュート。トラックにあるクリップすべてに効く
struct TrackSettingsSheet: View {
    let ref: TrackRef
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var isAudio: Bool { ref.kind == .audio }

    private var title: String {
        switch ref.kind {
        case nil: return "V1 トラック（スライドショーの写真）"
        case .title?: return "\(ref.name) トラック（タイトル）"
        case .overlay?: return "\(ref.name) トラック（重ねる写真）"
        case .audio?: return "\(ref.name) トラック（音声）"
        }
    }

    private var count: Int {
        switch ref.kind {
        case nil: return model.playCount
        case .title?: return model.titles.filter { $0.track == ref.index }.count
        case .overlay?: return model.overlayClips.filter { $0.track == ref.index }.count
        case .audio?: return model.clips.filter { $0.track == ref.index }.count
        }
    }

    private func bind<T>(_ key: WritableKeyPath<TrackSettings, T>) -> Binding<T> {
        Binding(get: { model.trackSetting(ref)[keyPath: key] },
                set: { v in model.updateTrackSetting(ref) { $0[keyPath: key] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(ref.kind == nil ? "\(count) 枚の写真" : "\(count) 個のクリップ").font(.callout).foregroundStyle(.secondary)
            Form {
                if isAudio {
                    Toggle("ミュート（このトラックの音を出さない）", isOn: bind(\.muted))
                    LabeledContent("音量") {
                        HStack {
                            Slider(value: bind(\.volume), in: 0...1).disabled(model.trackSetting(ref).muted)
                            PercentField(value: bind(\.volume), range: 0...1).disabled(model.trackSetting(ref).muted)
                        }
                    }
                } else {
                    Toggle("非表示にする（画面にも mp4 にも出さない）", isOn: bind(\.hidden))
                    LabeledContent("不透明度") {
                        HStack {
                            Slider(value: bind(\.opacity), in: 0...1).disabled(model.trackSetting(ref).hidden)
                            PercentField(value: bind(\.opacity), range: 0...1).disabled(model.trackSetting(ref).hidden)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Text(isAudio ? "クリップごとの音量に、このトラックの音量を掛けます。"
                         : "クリップごとの透明度に、このトラックの不透明度を掛けます。V1 は、写真の層ぜんたいの濃さです（下は黒）。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("既定に戻す") { model.trackSettings[ref.key] = nil }
                    .disabled(model.trackSetting(ref).isDefault)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 460)
    }
}
