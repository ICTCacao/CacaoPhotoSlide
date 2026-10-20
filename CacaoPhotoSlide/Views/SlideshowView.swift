import SwiftUI

/// 「今の時刻」と再生状態から毎フレーム描く。アニメーションは自分で計算する
struct SlideshowView: View {
    let controller: SlideshowController

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: controller.timelinePaused)) { ctx in
                let size = geo.size
                let date = ctx.date
                ZStack {
                    Color.black
                    if let cur = controller.current {
                        let t = TransitionMath.easeInOut(controller.transitionProgress(at: date))
                        if t < 1, let prev = controller.previous {
                            layer(prev, size: size, date: date, fx: outgoing(t, width: size.width))
                        }
                        layer(cur, size: size, date: date, fx: incoming(t, width: size.width))
                    }
                    hud
                }
                .frame(width: size.width, height: size.height)
                .clipped()
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 1 枚ぶんの描画

    private func layer(_ slide: Slide, size: CGSize, date: Date, fx: LayerFX) -> some View {
        let kenBurns = controller.settings.transition == .kenBurns
        let p = kenBurns ? controller.motionProgress(slide, at: date) : 0
        let s = kenBurns ? slide.motion.scale(p) : 1
        let o = kenBurns ? slide.motion.offset(p) : .zero
        return Image(decorative: slide.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: controller.settings.fit == .fill ? .fill : .fit)
            .frame(width: size.width, height: size.height)
            .scaleEffect(s)
            .offset(x: o.x * size.width, y: o.y * size.height)
            .scaleEffect(fx.scale)
            .offset(x: fx.dx)
            .opacity(fx.opacity)
    }

    private func incoming(_ t: Double, width: CGFloat) -> LayerFX {
        TransitionMath.incoming(controller.settings.transition, t: t, width: width)
    }

    private func outgoing(_ t: Double, width: CGFloat) -> LayerFX {
        TransitionMath.outgoing(controller.settings.transition, t: t, width: width)
    }

    // MARK: 一時停止と枚数の表示

    @ViewBuilder private var hud: some View {
        if controller.hudVisible, let cur = controller.current {
            VStack {
                Spacer()
                HStack(spacing: 14) {
                    if controller.isPaused {
                        Label("一時停止", systemImage: "pause.fill")
                            .fontWeight(.semibold)
                    }
                    Text("\(cur.index + 1) / \(controller.count)")
                        .monospacedDigit()
                    Text(cur.url.lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.title3)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 44)
            }
            .frame(maxWidth: 900)
            .transition(.opacity)
        }
    }
}
