import SwiftUI
import AppKit

/// mp4 書き出しの設定と進み具合
struct ExportSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("mp4 に書き出す", systemImage: "film")
                .font(.title2.bold())
            if let job = model.exportJob {
                progress(job)
            } else {
                options(Bindable(model))
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func options(_ model: Bindable<AppModel>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("サイズ（16:9）", selection: model.exportSize) {
                ForEach(ExportSize.allCases) { Text($0.label).tag($0) }
            }
            Picker("フレームレート", selection: model.exportFps) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(self.model.exportCount) 枚 × \(ContentView.seconds(self.model.dwell)) ＝ 約 \(Self.clock(self.model.exportDuration))")
                Text("切り替え・順番・選んだ写真・表示のしかたは、今の設定のまま。")
                    .foregroundStyle(.secondary)
                if self.model.clips.isEmpty {
                    Text("音は入りません（タイムラインに音声を置くと入ります）").foregroundStyle(.secondary)
                } else {
                    Label("音声 \(self.model.clips.count) 本をタイムラインの位置で入れます（終わりはフェードアウト）", systemImage: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            HStack {
                Spacer()
                Button("キャンセル") { self.model.showExport = false }
                    .keyboardShortcut(.cancelAction)
                Button("書き出す…") { self.model.exportMovie() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private func progress(_ job: ExportJob) -> some View {
        switch job.state {
        case .running:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: job.progress)
                HStack {
                    Text("\(Int(job.progress * 100)) %　残り 約 \(Self.clock(model.exportDuration * (1 - job.progress) * Self.speedFactor(job)))")
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Button("中止") { job.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        case .done(let url):
            VStack(alignment: .leading, spacing: 10) {
                Label("書き出しました", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                HStack {
                    Spacer()
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button("閉じる") { model.finishExport() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                HStack {
                    Spacer()
                    Button("閉じる") { model.finishExport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        case .cancelled:
            VStack(alignment: .leading, spacing: 10) {
                Text("中止しました")
                HStack {
                    Spacer()
                    Button("閉じる") { model.finishExport() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    /// 残り時間の見積もりは、動画の長さに対する処理の速さがわからないので、進み具合からざっくり
    private static func speedFactor(_ job: ExportJob) -> Double { 1 }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) 秒" }
        let m = s / 60, r = s % 60
        if m < 60 { return r == 0 ? "\(m) 分" : "\(m) 分 \(r) 秒" }
        return "\(m / 60) 時間 \(m % 60) 分"
    }
}
