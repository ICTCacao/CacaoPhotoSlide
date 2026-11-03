// 1 コマを描く。画面（プレビュー・全画面）と mp4 書き出しが、同じ関数を使う。Mac 版の SlideshowView / FrameRenderer / TitleRenderer の移植。
import type { FitMode, OverlayClip, TitleItem, Transition } from "./model.ts";
import {
  KenBurns, SlideTiming, anchorH, anchorV, clamp, easeInOut, endFadeAlpha, incoming, kbOffset, kbScale, kenBurnsFor,
  outgoing, overlayOrder, overlayState, titleState,
} from "./engine.ts";

export interface Scene {
  paths: string[];                 // 流す写真（順番どおり）
  timing: SlideTiming;
  seed: number;                    // Ken Burns の動きの種
  v1Opacity: number;
  overlays: OverlayClip[];         // トラックの設定を反映済み
  titles: TitleItem[];             // 同上
  transition: Transition;          // 設定のタブの値（V2 の既定）
  fit: FitMode;
  endFade: number;
  loop?: boolean;
  exporting?: boolean;             // 書き出し: 「なし」でも、最後は切り替えの長さぶん黒へ落とす（Mac 版と同じ）
}

export interface ImageSource {
  v1(index: number): ImageBitmap | undefined;
  overlay(path: string): ImageBitmap | undefined;
}

export function motionFor(scene: Scene, index: number): KenBurns { return kenBurnsFor((scene.seed + Math.imul(index + 1, 2654435761)) >>> 0); }
export function overlayMotion(scene: Scene, clip: OverlayClip): KenBurns {
  let h = 0; for (let i = 0; i < clip.id.length; i++) h = (Math.imul(h, 31) + clip.id.charCodeAt(i)) >>> 0;
  return kenBurnsFor((scene.seed ^ h) >>> 0);
}

const SANS = `"Yu Gothic UI","Yu Gothic","Hiragino Sans","Meiryo",system-ui,sans-serif`;
export function titleFont(item: TitleItem, fs: number): string {
  const fam = item.fontName ? `"${item.fontName.replace(/"/g, "")}",${SANS}` : SANS;
  return `${item.bold ? "bold " : ""}${fs}px ${fam}`;
}

export function drawFrame(ctx: CanvasRenderingContext2D, W: number, H: number, t: number, scene: Scene, imgs: ImageSource, opts: { settled?: boolean; still?: boolean } = {}) {
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.globalAlpha = 1;
  ctx.shadowColor = "transparent"; ctx.shadowBlur = 0;
  ctx.fillStyle = "#000";
  ctx.fillRect(0, 0, W, H);
  ctx.imageSmoothingEnabled = true;
  ctx.imageSmoothingQuality = "high";
  const tm = scene.timing;
  const n = tm.count;

  // V1（写真）。トラックの設定の濃さは、黒に対する濃さ
  if (n > 0) {
    const k = tm.index(t);
    const start = tm.starts[k];
    const tr = tm.trs[k];
    const tt = tr > 0 ? clamp((t - start) / tr, 0, 1) : 1;
    const eased = easeInOut(tt);
    if (opts.still) {
      // 流していないときの静止画: 動きも切り替えも付けない
      const img = imgs.v1(k);
      if (img) drawLayer(ctx, W, H, img, tm.fits[k], null, 0, { opacity: 1, scale: 1, dx: 0 });
    } else if (eased < 1 && k > 0) {
      const prev = imgs.v1(k - 1);
      if (prev) {
        const p = clamp((t - tm.starts[k - 1]) / tm.motionLength(k - 1), 0, 1);
        drawLayer(ctx, W, H, prev, tm.fits[k - 1], tm.transitions[k - 1] === "kenBurns" ? motionFor(scene, k - 1) : null, p, outgoing(tm.transitions[k], eased, W));
      }
    }
    const cur = opts.still ? undefined : imgs.v1(k);
    if (cur) {
      const p = clamp((t - start) / tm.motionLength(k), 0, 1);
      drawLayer(ctx, W, H, cur, tm.fits[k], tm.transitions[k] === "kenBurns" ? motionFor(scene, k) : null, p, incoming(tm.transitions[k], eased, W));
    }
  }
  if (scene.v1Opacity < 1) {
    ctx.globalAlpha = 1 - Math.max(0, scene.v1Opacity);
    ctx.fillStyle = "#000";
    ctx.fillRect(0, 0, W, H);
    ctx.globalAlpha = 1;
  }

  // V2（重ねる写真）
  for (const clip of overlayOrder(scene.overlays)) {
    const st = overlayState(clip, t, scene.transition, scene.fit, overlayMotion(scene, clip), opts.settled);
    if (!st || st.opacity <= 0.001) continue;
    const img = imgs.overlay(clip.path);
    if (!img) continue;
    const r = coverScale(W, H, img.width, img.height, st.fill);
    ctx.save();
    ctx.globalAlpha = clamp(st.opacity, 0, 1);
    ctx.translate(W / 2 + st.dx * W, H / 2 + st.dy * H);
    ctx.scale(st.scale, st.scale);
    ctx.drawImage(img, (-img.width * r) / 2, (-img.height * r) / 2, img.width * r, img.height * r);
    ctx.restore();
  }

  // タイトル
  drawTitles(ctx, W, H, scene.titles, t, opts.settled);

  // 最後の写真の終わりの黒
  if (n > 0) {
    const k = tm.index(t);
    if (k === n - 1) {
      const lastTotal = tm.dwells[n - 1] + tm.trs[n - 1];
      const fade = scene.exporting
        ? Math.min(lastTotal, scene.endFade > 0 ? scene.endFade : tm.trs[n - 1])
        : (scene.endFade > 0 && !scene.loop ? Math.min(lastTotal, scene.endFade) : 0);
      const a = endFadeAlpha(t - tm.starts[n - 1], lastTotal, fade);
      if (a > 0) {
        ctx.globalAlpha = a;
        ctx.fillStyle = "#000";
        ctx.fillRect(0, 0, W, H);
        ctx.globalAlpha = 1;
      }
    }
  }
}

function coverScale(W: number, H: number, iw: number, ih: number, fill: boolean): number {
  return fill ? Math.max(W / iw, H / ih) : Math.min(W / iw, H / ih);
}

function drawLayer(ctx: CanvasRenderingContext2D, W: number, H: number, img: ImageBitmap, fit: FitMode, kb: KenBurns | null, p: number,
                   fx: { opacity: number; scale: number; dx: number }) {
  const r = coverScale(W, H, img.width, img.height, fit === "fill");
  const fw = img.width * r, fh = img.height * r;
  ctx.save();
  ctx.globalAlpha = clamp(fx.opacity, 0, 1);
  // 内側から: Ken Burns の拡大 → Ken Burns のずらし → 効果の拡大 → 効果のずらし（Swift 版と同じ順）
  ctx.translate(W / 2 + fx.dx, H / 2);
  ctx.scale(fx.scale, fx.scale);
  if (kb) {
    const o = kbOffset(kb, p);
    ctx.translate(o[0] * W, o[1] * H);
    const s = kbScale(kb, p);
    ctx.scale(s, s);
  }
  ctx.drawImage(img, -fw / 2, -fh / 2, fw, fh);
  ctx.restore();
}

export function drawTitles(ctx: CanvasRenderingContext2D, W: number, H: number, titles: TitleItem[], t: number | null, settled?: boolean) {
  for (const item of titles) {
    if (!item.text) continue;
    const st = titleState(item, t, settled);
    if (!st || st.opacity <= 0.001) continue;
    const fs = item.size * H;
    const m = H * 0.04;
    const box = { x: m, y: m, w: W - 2 * m, h: H - 2 * m };
    ctx.font = titleFont(item, fs);
    const lines = item.text.split("\n");
    const lh = fs * 1.2;
    const widths = lines.map((l) => ctx.measureText(l).width);
    const blockW = Math.min(box.w, Math.max(1, ...widths));
    const blockH = lines.length * lh;
    const ah = anchorH(item.anchor), av = anchorV(item.anchor);
    const x = ah < 0 ? box.x : ah === 0 ? box.x + (box.w - blockW) / 2 : box.x + box.w - blockW;
    const y = av < 0 ? box.y : av === 0 ? box.y + (box.h - blockH) / 2 : box.y + box.h - blockH;
    ctx.save();
    ctx.translate(x + blockW / 2 + st.dx * H + item.offsetX * W, y + blockH / 2 + st.dy * H + item.offsetY * H);
    ctx.scale(st.scale, st.scale);
    ctx.globalAlpha = clamp(st.opacity, 0, 1);
    ctx.font = titleFont(item, fs);
    ctx.fillStyle = item.color || "#FFFFFF";
    ctx.textBaseline = "top";
    ctx.textAlign = "left";
    if (item.shadow) {
      ctx.shadowColor = "rgba(0,0,0,0.65)";
      ctx.shadowBlur = fs * 0.12;
      ctx.shadowOffsetX = 0;
      ctx.shadowOffsetY = fs * 0.03;
    }
    let visible = Math.floor(lines.reduce((s, l) => s + l.length, 0) * st.reveal);   // タイプライター: 見せる文字数（行の位置は、全文で決める）
    lines.forEach((line, i) => {
      const lw = widths[i];
      const lx = ah < 0 ? -blockW / 2 : ah === 0 ? -lw / 2 : blockW / 2 - lw;
      const shown = st.reveal >= 1 ? line : line.slice(0, Math.max(0, visible));
      visible -= line.length;
      if (shown) ctx.fillText(shown, lx, -blockH / 2 + i * lh + (lh - fs) / 2);
    });
    ctx.restore();
  }
}
