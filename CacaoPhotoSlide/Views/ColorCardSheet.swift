import SwiftUI

/// 単色の画像（黒・白など）をタイムラインに足す。再生ヘッドの位置に入る。上にタイトルを重ねて、扉やエンディングに使える
struct ColorCardSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var color: Color = .black
    @State private var dwell: Double = 5

    private static let swatches: [(String, Color)] = [
        ("黒", .black), ("白", .white), ("灰", Color(white: 0.5)),
        ("紺", Color(red: 0.05, green: 0.1, blue: 0.3)), ("赤", Color(red: 0.7, green: 0.1, blue: 0.1)),
        ("緑", Color(red: 0.1, green: 0.5, blue: 0.2)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("単色画像を足す").font(.headline)
            ZStack {
                Rectangle().fill(color)
                TitleOverlay(items: model.titles, time: nil)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4)))
            HStack(spacing: 8) {
                ColorPicker("色", selection: $color, supportsOpacity: false)
                ForEach(Self.swatches, id: \.0) { name, c in
                    Button { color = c } label: {
                        Circle().fill(c).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.secondary.opacity(0.6)))
                    }
                    .buttonStyle(.plain).help(name)
                }
                Spacer()
            }
            HStack {
                Text("表示時間")
                TextField("", value: $dwell, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                Stepper("", value: $dwell, in: 0.3...300, step: 0.5).labelsHidden()
                Text("秒").foregroundStyle(.secondary)
                Spacer()
            }
            Text("再生ヘッドの位置（\(ExportSheet.clock(model.playhead))）に入ります。順番は「手動」になります。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("追加") {
                    model.addColorCard(NSColor(color), dwell: max(0.3, dwell))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440)
        .onAppear { dwell = model.dwell }
    }
}
