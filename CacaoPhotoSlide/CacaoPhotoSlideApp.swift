import SwiftUI
import AppKit

enum AppInfo {
    static let name = "CacaoPhotoSlide"
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

/// ウインドウを閉じたらアプリも終了する。Dock やFinder から渡されたフォルダを受け取る
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    static var pending: [URL] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.isExporting else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "mp4 の書き出しの途中です"
        alert.informativeText = "中止して終了しますか？（途中のファイルは残りません）"
        alert.addButton(withTitle: "中止して終了")
        alert.addButton(withTitle: "キャンセル")
        if alert.runModal() == .alertFirstButtonReturn {
            model.exportJob?.cancel()
            return .terminateNow
        }
        return .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model = Self.model {
            Task { @MainActor in model.load(urls) }
        } else {
            Self.pending.append(contentsOf: urls)
        }
    }
}

@main
struct CacaoPhotoSlideApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 560)
                .onAppear {
                    AppDelegate.model = model
                    if AppDelegate.pending.isEmpty {
                        model.restoreLast()
                    } else {
                        model.load(AppDelegate.pending)
                        AppDelegate.pending = []
                    }
                }
        }
        .defaultSize(width: 860, height: 960)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("\(AppInfo.name) について") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: AppInfo.version,
                        .version: "",
                        .credits: NSAttributedString(string: "写真のフォルダをドロップして、全画面のスライドショーにする。\n音声をタイムラインに置き、mp4 にも書き出せる。\nSpace で停止/再開、← → で前後、Esc で終了。"),
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("新規") { model.newDocument() }
                    .keyboardShortcut("n")
                Button("開く…") { model.openPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("保存") { model.saveDocument() }
                    .keyboardShortcut("s")
                    .disabled(model.sources.isEmpty && model.clips.isEmpty)
                Button("別名で保存…") { model.saveDocumentAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.sources.isEmpty && model.clips.isEmpty)
                Divider()
                Button("写真のフォルダを Finder で表示") { model.revealSources() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.sources.isEmpty)
            }
            CommandMenu("スライドショー") {
                Button("開始") { model.startSlideshow() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.photos.isEmpty || model.isShowing)
                Button("mp4 に書き出す…") { model.showExport = true }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.photos.isEmpty || model.isShowing)
                Divider()
                Button("すべての写真を選択") { model.selectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.photos.isEmpty)
                Button("選択を解除") { model.clearSelection() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.selection.isEmpty)
                Divider()
                Button("選んだ写真を外す") { model.removeSelectedPhotos() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selection.isEmpty)
                Button("外した写真を戻す") { model.restoreRemovedPhotos() }
                    .disabled(model.removedCount == 0)
            }
        }
    }
}
