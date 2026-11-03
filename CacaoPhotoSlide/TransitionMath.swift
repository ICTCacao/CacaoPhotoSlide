import CoreGraphics

/// 1 枚ぶんに掛ける効果（画面でも mp4 でも同じ計算を使う）
struct LayerFX {
    var opacity: Double = 1
    var scale: CGFloat = 1
    var dx: CGFloat = 0
}

enum TransitionMath {
    static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// 入ってくる写真。t は 0→1（イージング済み）
    static func incoming(_ transition: Transition, t: Double, width: CGFloat) -> LayerFX {
        switch transition {
        case .kenBurns, .crossfade: return LayerFX(opacity: t)
        case .push: return LayerFX(dx: (1 - t) * width)
        case .zoom: return LayerFX(opacity: t, scale: 0.82 + 0.18 * t)
        case .none: return LayerFX()
        }
    }

    /// 出ていく写真
    static func outgoing(_ transition: Transition, t: Double, width: CGFloat) -> LayerFX {
        switch transition {
        case .kenBurns, .crossfade: return LayerFX()
        case .push: return LayerFX(dx: -t * width)
        case .zoom: return LayerFX(opacity: 1 - t, scale: 1 + 0.15 * t)
        case .none: return LayerFX()
        }
    }
}

extension TransitionMath {
    /// 最後の写真の終わりの黒（0 → 1）。elapsed は最後の写真を出してからの秒、total はその写真が終わるまでの秒、fade は黒に向かう秒数
    static func endFadeAlpha(elapsed: Double, total: Double, fade: Double) -> Double {
        guard fade > 0 else { return 0 }
        return min(1, max(0, 1 - (total - elapsed) / fade))
    }
}

/// Core Graphics で 1 コマ描く（mp4 書き出し用。画面の SlideshowView と同じ並び順・同じ式）
struct FrameLayer {
    let image: CGImage
    let motion: KenBurnsMotion
    let motionProgress: Double
    let fx: LayerFX
    let kenBurns: Bool          // この写真の切り替えが Ken Burns か
    let fit: FitMode            // この写真の収め方
}

enum FrameRenderer {
    static func draw(_ layers: [FrameLayer], in ctx: CGContext, size: CGSize,
                     v1Opacity: Double = 1, overlays: [OverlayLayer] = [], titles: [TitleItem] = [], time: Double = 0, blackout: Double = 0) {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        for l in layers {
            let kenBurns = l.kenBurns
            let s = kenBurns ? l.motion.scale(l.motionProgress) : 1
            let o = kenBurns ? l.motion.offset(l.motionProgress) : .zero
            let iw = CGFloat(l.image.width), ih = CGFloat(l.image.height)
            let r = l.fit == .fill ? max(size.width / iw, size.height / ih) : min(size.width / iw, size.height / ih)
            let fw = iw * r, fh = ih * r
            ctx.saveGState()
            ctx.setAlpha(l.fx.opacity)
            // SwiftUI の modifier の順（内側から）: Ken Burns の拡大 → Ken Burns のずらし → 効果の拡大 → 効果のずらし
            ctx.translateBy(x: size.width / 2 + l.fx.dx, y: size.height / 2)
            ctx.scaleBy(x: l.fx.scale, y: l.fx.scale)
            ctx.translateBy(x: o.x * size.width, y: -o.y * size.height)   // CG は y が上向き
            ctx.scaleBy(x: s, y: s)
            ctx.draw(l.image, in: CGRect(x: -fw / 2, y: -fh / 2, width: fw, height: fh))
            ctx.restoreGState()
        }
        // V1 トラックの透過率（黒に対する濃さ）
        if v1Opacity < 1 {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1 - max(0, v1Opacity)))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        // V2（重ねる写真）: V1 の上、タイトルの下
        for o in overlays {
            let iw = CGFloat(o.image.width), ih = CGFloat(o.image.height)
            let r = o.state.fill ? max(size.width / iw, size.height / ih) : min(size.width / iw, size.height / ih)
            let fw = iw * r, fh = ih * r
            ctx.saveGState()
            ctx.setAlpha(o.state.opacity)
            ctx.translateBy(x: size.width / 2 + CGFloat(o.state.dx) * size.width, y: size.height / 2 - CGFloat(o.state.dy) * size.height)
            ctx.scaleBy(x: CGFloat(o.state.scale), y: CGFloat(o.state.scale))
            ctx.draw(o.image, in: CGRect(x: -fw / 2, y: -fh / 2, width: fw, height: fh))
            ctx.restoreGState()
        }
        TitleRenderer.draw(titles, at: time, in: ctx, size: size)
        if blackout > 0 {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: blackout))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}
