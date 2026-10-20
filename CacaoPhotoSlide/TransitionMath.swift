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

/// Core Graphics で 1 コマ描く（mp4 書き出し用。画面の SlideshowView と同じ並び順・同じ式）
struct FrameLayer {
    let image: CGImage
    let motion: KenBurnsMotion
    let motionProgress: Double
    let fx: LayerFX
}

enum FrameRenderer {
    static func draw(_ layers: [FrameLayer], in ctx: CGContext, size: CGSize, transition: Transition, fit: FitMode) {
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.interpolationQuality = .high
        for l in layers {
            let kenBurns = transition == .kenBurns
            let s = kenBurns ? l.motion.scale(l.motionProgress) : 1
            let o = kenBurns ? l.motion.offset(l.motionProgress) : .zero
            let iw = CGFloat(l.image.width), ih = CGFloat(l.image.height)
            let r = fit == .fill ? max(size.width / iw, size.height / ih) : min(size.width / iw, size.height / ih)
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
    }
}
