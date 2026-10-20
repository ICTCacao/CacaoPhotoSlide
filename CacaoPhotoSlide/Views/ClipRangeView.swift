import SwiftUI

/// 曲全体の波形の上で、開始位置・終了位置（縦のつまみ）とフェードイン／アウト（上の丸いつまみ）をドラッグで決める
struct ClipRangeView: View {
    @Environment(AppModel.self) private var model
    let clip: MusicClip

    private enum Handle { case inPoint, outPoint, fadeIn, fadeOut }
    @State private var dragging: Handle?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let d = max(clip.duration, 0.001)
            let xi = CGFloat(clip.inPoint / d) * w
            let xo = CGFloat(clip.effectiveOut / d) * w
            let xfi = CGFloat((clip.inPoint + clip.fadeIn) / d) * w
            let xfo = CGFloat((clip.effectiveOut - clip.fadeOut) / d) * w
            let color = TrackColors.color(clip.track)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
                Canvas { ctx, size in
                    // 波形（範囲の中はオレンジ、外はグレー）
                    if let peaks = model.waveforms[clip.path], !peaks.isEmpty {
                        let n = peaks.count
                        let bw = size.width / CGFloat(n)
                        for i in 0..<n {
                            let x = CGFloat(i) * bw
                            let bh = max(1, CGFloat(peaks[i]) * (size.height - 18))
                            let inside = x >= xi && x <= xo
                            ctx.fill(Path(CGRect(x: x, y: size.height - bh, width: max(1, bw - 0.5), height: bh)),
                                     with: .color(inside ? color.opacity(0.8) : Color.secondary.opacity(0.35)))
                        }
                    } else {
                        ctx.fill(Path(CGRect(x: 0, y: size.height - 2, width: size.width, height: 2)), with: .color(.secondary.opacity(0.3)))
                    }
                    // 使う範囲
                    ctx.fill(Path(CGRect(x: xi, y: 0, width: max(0, xo - xi), height: size.height)), with: .color(color.opacity(0.12)))
                    // 音量の形（フェードイン・アウト）
                    var line = Path()
                    line.move(to: CGPoint(x: xi, y: size.height))
                    line.addLine(to: CGPoint(x: xfi, y: 10))
                    line.addLine(to: CGPoint(x: xfo, y: 10))
                    line.addLine(to: CGPoint(x: xo, y: size.height))
                    ctx.stroke(line, with: .color(color), lineWidth: 1.5)
                }
                // 開始・終了のつまみ
                verticalHandle(x: xi, h: h, label: Self.clock(clip.inPoint), leading: true, color: color)
                verticalHandle(x: xo, h: h, label: Self.clock(clip.effectiveOut), leading: false, color: color)
                // フェードのつまみ
                knob(x: xfi, active: dragging == .fadeIn, color: color)
                knob(x: xfo, active: dragging == .fadeOut, color: color)
                // 試聴中の再生位置
                if model.auditionID == clip.id {
                    TimelineView(.animation) { _ in
                        let t = model.auditionTime ?? clip.inPoint
                        Rectangle().fill(Color.red).frame(width: 2, height: h)
                            .offset(x: CGFloat(t / d) * w - 1)
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragging == nil {
                            dragging = nearest(to: v.startLocation, xi: xi, xo: xo, xfi: xfi, xfo: xfo)
                        }
                        guard let handle = dragging else { return }
                        let t = Double(min(max(0, v.location.x), w) / w) * d
                        let id = clip.id
                        switch handle {
                        case .inPoint: model.updateClip(id) { $0.inPoint = t }
                        case .outPoint: model.updateClip(id) { $0.outPoint = t }
                        case .fadeIn: model.updateClip(id) { $0.fadeIn = max(0, t - $0.inPoint) }
                        case .fadeOut: model.updateClip(id) { $0.fadeOut = max(0, $0.effectiveOut - t) }
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
            .onAppear { model.requestWaveform(for: clip) }
            .onChange(of: clip.path) { _, _ in model.requestWaveform(for: clip) }
        }
        .frame(height: 56)
        .help("縦のつまみ: 曲の開始位置・終了位置　上の丸: フェードイン／アウトの長さ")
    }

    private func verticalHandle(x: CGFloat, h: CGFloat, label: String, leading: Bool, color: Color) -> some View {
        ZStack(alignment: leading ? .topLeading : .topTrailing) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 5, height: h)
            Text(label)
                .font(.system(size: 9)).monospacedDigit()
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.white)
                .fixedSize()
                .offset(x: leading ? 7 : -7, y: 16)
        }
        .frame(width: 5, height: h, alignment: leading ? .leading : .trailing)
        .offset(x: x - 2.5)
    }

    private func knob(x: CGFloat, active: Bool, color: Color) -> some View {
        Circle()
            .fill(active ? Color.primary : color)
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            .frame(width: 11, height: 11)
            .offset(x: x - 5.5, y: 4.5)
    }

    /// 押した場所に近いつまみ。上のほう（y < 18）は丸いつまみ、それ以外は縦のつまみ
    private func nearest(to p: CGPoint, xi: CGFloat, xo: CGFloat, xfi: CGFloat, xfo: CGFloat) -> Handle? {
        if p.y < 18 {
            let di = abs(p.x - xfi), dO = abs(p.x - xfo)
            if min(di, dO) <= 12 { return di <= dO ? .fadeIn : .fadeOut }
        }
        let di = abs(p.x - xi), dO = abs(p.x - xo)
        if min(di, dO) <= 18 { return di <= dO ? .inPoint : .outPoint }
        return nil
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        return String(format: "%d:%04.1f", m, s - Double(m * 60))
    }
}
