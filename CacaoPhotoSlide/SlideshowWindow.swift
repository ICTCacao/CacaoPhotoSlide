import AppKit
import SwiftUI

/// 画面全体を覆う黒い窓。メニューバー・Dock・カーソルを隠し、キーで操作する
final class SlideshowWindow: NSWindow, NSWindowDelegate {
    private var controller: SlideshowController!
    private var onClose: (() -> Void)?
    private var activity: NSObjectProtocol?
    private var keyMonitor: Any?

    private var fullScreen = true

    static func present(controller: SlideshowController, on screen: NSScreen, mode: DisplayMode, onClose: @escaping () -> Void) -> SlideshowWindow {
        let w: SlideshowWindow
        if mode == .fullScreen {
            // contentRect はグローバル座標で渡す（screen: 付きの初期化子はスクリーン相対になるので使わない）
            w = SlideshowWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.fullScreen = true
            w.hasShadow = false
            w.animationBehavior = .none
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        } else {
            // 普通の窓。大きさは自由（既定 960×540）、前回の位置を覚える
            let size = NSSize(width: 960, height: 540)
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
            w = SlideshowWindow(contentRect: NSRect(origin: origin, size: size),
                                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.fullScreen = false
            w.title = "スライドショー"
            w.contentAspectRatio = NSSize(width: 16, height: 9)
            w.minSize = NSSize(width: 320, height: 180)
            w.setFrameAutosaveName("SlideshowWindow")
            w.collectionBehavior = [.fullScreenPrimary]
        }
        w.controller = controller
        w.onClose = onClose
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.isOpaque = true
        w.contentView = NSHostingView(rootView: SlideshowView(controller: controller))
        w.delegate = w
        w.activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "スライドショー")
        if w.fullScreen {
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            NSCursor.hide()
            w.setFrame(screen.frame, display: false)
        }
        w.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak w] event in
            guard let w, event.window === w else { return event }
            return w.handle(event) ? nil : event
        }
        w.makeKeyAndOrderFront(nil)
        return w
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Space: 停止/再開、← →: 前へ/次へ、Esc / Q: 終了
    private func handle(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 49: controller.togglePause()
        case 123, 126, 116: controller.previousSlide()   // ← ↑ PageUp
        case 124, 125, 121: controller.next()            // → ↓ PageDown
        case 53, 12: close()                             // Esc, Q
        default: return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if fullScreen {
            NSCursor.unhide()
            NSApp.presentationOptions = []
        }
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        controller.stop()
        onClose?()
        onClose = nil
    }
}
