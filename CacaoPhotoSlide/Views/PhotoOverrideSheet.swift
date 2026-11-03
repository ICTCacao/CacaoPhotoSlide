import SwiftUI

/// 選んだ写真だけ、表示時間とエフェクト（切り替え）を変える。変えない項目は全体の設定のまま
struct PhotoOverrideSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var indices: [Int] = []
    @State private var useDwell = false
    @State private var dwell: Double = 5
    @State private var useTransition = false
    @State private var transition: Transition = .crossfade

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
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
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Text("オフの項目は、設定のタブの値（表示時間 \(ContentView.seconds(model.dwell))、\(model.transition.label)）に従います。エフェクトは、その写真が出てくるときの切り替えです。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("個別設定を外す") {
                    model.setOverride(indices, dwell: nil, transition: nil)
                    dismiss()
                }
                .disabled(!hasAny)
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("適用") {
                    model.setOverride(indices, dwell: useDwell ? max(0.3, dwell) : nil,
                                      transition: useTransition ? transition : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear(perform: load)
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
        let first = indices.first.flatMap { model.photos.indices.contains($0) ? model.overrides[model.photos[$0].path] : nil }
        useDwell = first?.dwell != nil
        dwell = first?.dwell ?? model.dwell
        useTransition = first?.transition != nil
        transition = first?.transition ?? (model.transition == .none ? .crossfade : model.transition)
    }
}
