// 時間の計算と、エフェクトの式。画面（プレビュー・全画面）と mp4 書き出しの両方が、同じ関数を使う。
// Mac 版の Settings.swift（SlideTiming）・TransitionMath.swift・Overlay.swift・Titles.swift の移植。
import type { FitMode, MusicClip, OverlayClip, PhotoOverride, ProjectFile, TitleAnchor, TitleItem, TrackSettings, Transition } from "./model.ts";
import { defaultTrackSettings } from "./model.ts";

export const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export function easeInOut(t: number): number {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}

// ───── 乱数（同じ種なら同じ動き。プレビューと書き出しで Ken Burns が揃う）─────
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function hashString(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}

export interface KenBurns { startScale: number; endScale: number; startOffset: [number, number]; endOffset: [number, number] }

export function kenBurnsFor(seed: number): KenBurns {
  const r = mulberry32(seed);
  const zoomIn = r() < 0.5;
  const near = 1.0 + r() * 0.06;
  const far = 1.14 + r() * 0.12;
  const [s0, s1] = zoomIn ? [near, far] : [far, near];
  const angle = r() * Math.PI * 2;
  const dir: [number, number] = [Math.cos(angle), Math.sin(angle)];
  const pt = (scale: number, sign: number): [number, number] => {
    const m = ((scale - 1) / 2) * 0.9;
    return [dir[0] * m * sign, dir[1] * m * sign];
  };
  return { startScale: s0, endScale: s1, startOffset: pt(s0, -1), endOffset: pt(s1, 1) };
}

export const kbScale = (m: KenBurns, p: number) => m.startScale + (m.endScale - m.startScale) * p;
export const kbOffset = (m: KenBurns, p: number): [number, number] => [
  m.startOffset[0] + (m.endOffset[0] - m.startOffset[0]) * p,
  m.startOffset[1] + (m.endOffset[1] - m.startOffset[1]) * p,
];

// ───── 切り替えの式 ─────
export interface LayerFX { opacity: number; scale: number; dx: number }
const fx = (o: Partial<LayerFX> = {}): LayerFX => ({ opacity: 1, scale: 1, dx: 0, ...o });

export function incoming(tr: Transition, t: number, width: number): LayerFX {
  switch (tr) {
    case "kenBurns": case "crossfade": return fx({ opacity: t });
    case "push": return fx({ dx: (1 - t) * width });
    case "zoom": return fx({ opacity: t, scale: 0.82 + 0.18 * t });
    case "none": return fx();
  }
}

export function outgoing(tr: Transition, t: number, width: number): LayerFX {
  switch (tr) {
    case "kenBurns": case "crossfade": return fx();
    case "push": return fx({ dx: -t * width });
    case "zoom": return fx({ opacity: 1 - t, scale: 1 + 0.15 * t });
    case "none": return fx();
  }
}

/** 最後の写真の終わりの黒（0 → 1） */
export function endFadeAlpha(elapsed: number, total: number, fade: number): number {
  if (fade <= 0) return 0;
  return clamp(1 - (total - elapsed) / fade, 0, 1);
}

// ───── 写真ごとの長さ・開始時刻 ─────
export interface TimingSettings { dwell: number; transition: Transition; transitionDuration: number; fit: FitMode }

export class SlideTiming {
  dwells: number[] = [];
  transitions: Transition[] = [];
  fits: FitMode[] = [];
  trs: number[] = [];
  starts: number[] = [];
  total = 0;

  constructor(paths: string[], s: TimingSettings, overrides: Record<string, PhotoOverride>) {
    for (const p of paths) {
      const o = overrides[p];
      this.dwells.push(Math.max(0.1, o?.dwell ?? s.dwell));
      this.transitions.push(o?.transition ?? s.transition);
      this.fits.push(o?.fit ?? s.fit);
    }
    for (let i = 0; i < this.dwells.length; i++) {
      this.trs.push(this.transitions[i] === "none" ? 0 : Math.min(s.transitionDuration, this.dwells[i], i > 0 ? this.dwells[i - 1] : this.dwells[i]));
    }
    let t = 0;
    for (const d of this.dwells) { this.starts.push(t); t += d; }
    this.total = t + (this.trs.length ? this.trs[this.trs.length - 1] : 0);
  }

  get count() { return this.dwells.length; }

  /** その時刻に出ている写真の番号 */
  index(time: number): number {
    if (!this.starts.length) return 0;
    let lo = 0, hi = this.starts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (this.starts[mid] <= time) lo = mid; else hi = mid - 1;
    }
    return lo;
  }

  /** 写真の区切り（count + 1 個。最後は最後の写真の表示が終わる時刻） */
  bounds(): number[] {
    const n = this.count;
    return [...this.starts, n ? this.starts[n - 1] + this.dwells[n - 1] : 0];
  }

  /** Ken Burns の動きの長さ。次の写真に切り替わり終わるまで */
  motionLength(i: number): number {
    return this.dwells[i] + (i + 1 < this.count ? this.trs[i + 1] : this.trs[i]);
  }
}

// ───── V2（重ねる写真）─────
export interface OverlayState { opacity: number; scale: number; dx: number; dy: number; fill: boolean }

/** クリップを手前に重ねる順（下のトラックから）に並べる */
export function overlayOrder(clips: OverlayClip[]): OverlayClip[] {
  return [...clips].sort((a, b) => (a.track === b.track ? a.start - b.start : a.track - b.track));
}

export function overlayState(clip: OverlayClip, t: number, transition: Transition, fit: FitMode, motion: KenBurns | undefined, settled = false): OverlayState | null {
  const end = clip.start + clip.duration;
  if (t < clip.start || t > end) return null;
  const tr = clip.transition ?? transition;
  const s: OverlayState = { opacity: clip.opacity, scale: clip.scale, dx: clip.offsetX, dy: clip.offsetY, fill: (clip.fit ?? fit) === "fill" };
  if (settled) return s;
  const fi = tr === "none" ? 0 : Math.min(clip.fadeIn, clip.duration / 2);
  const fo = tr === "none" ? 0 : Math.min(clip.fadeOut, clip.duration / 2);
  const pin = fi > 0 ? clamp((t - clip.start) / fi, 0, 1) : 1;
  const pout = fo > 0 ? clamp((end - t) / fo, 0, 1) : 1;
  const ei = easeInOut(pin), eo = easeInOut(pout);
  const inFX = incoming(tr, ei, 1);
  const outFX = outgoing(tr, 1 - eo, 1);
  s.opacity *= inFX.opacity * outFX.opacity;
  if (tr === "kenBurns" || tr === "crossfade") s.opacity *= eo;
  s.scale *= inFX.scale * outFX.scale;
  s.dx += inFX.dx + outFX.dx;
  if (tr === "kenBurns" && motion) {
    const p = clip.duration > 0 ? clamp((t - clip.start) / clip.duration, 0, 1) : 0;
    s.scale *= kbScale(motion, p);
    const o = kbOffset(motion, p);
    s.dx += o[0];
    s.dy += o[1];
  }
  return s;
}

// ───── タイトル ─────
export interface TitleState { opacity: number; dx: number; dy: number; scale: number; reveal: number }

export function titleState(item: TitleItem, t: number | null, settled = false): TitleState | null {
  const base = rawTitleState(item, t, settled);
  if (!base) return null;
  base.opacity *= item.opacity;
  return base;
}

function rawTitleState(item: TitleItem, t: number | null, settled: boolean): TitleState | null {
  const st: TitleState = { opacity: 1, dx: 0, dy: 0, scale: 1, reveal: 1 };
  if (t === null) return st;
  if (t < item.start) return null;
  const timed = item.duration > 0;
  const end = item.start + item.duration;
  if (timed && t > end) return null;
  if (settled) return st;
  const f = Math.max(0.05, timed ? Math.min(item.effectDuration, item.duration / 2) : item.effectDuration);
  const pin = clamp((t - item.start) / f, 0, 1);
  const pout = timed ? clamp((end - t) / f, 0, 1) : 1;
  const p = Math.min(easeInOut(pin), easeInOut(pout));
  const d = 0.15;
  switch (item.effect) {
    case "none": break;
    case "fade": st.opacity = p; break;
    case "slideUp": st.opacity = p; st.dy = (1 - p) * d; break;
    case "slideDown": st.opacity = p; st.dy = -(1 - p) * d; break;
    case "slideLeft": st.opacity = p; st.dx = -(1 - p) * d; break;
    case "slideRight": st.opacity = p; st.dx = (1 - p) * d; break;
    case "zoom": st.opacity = p; st.scale = 0.6 + 0.4 * p; break;
    case "typewriter": st.reveal = pin; st.opacity = easeInOut(pout); break;
  }
  return st;
}

export function anchorH(a: TitleAnchor): -1 | 0 | 1 {
  return a === "topLeft" || a === "left" || a === "bottomLeft" ? -1 : a === "top" || a === "center" || a === "bottom" ? 0 : 1;
}
export function anchorV(a: TitleAnchor): -1 | 0 | 1 {
  return a === "topLeft" || a === "top" || a === "topRight" ? -1 : a === "left" || a === "center" || a === "right" ? 0 : 1;
}

// ───── トラックの設定を反映したもの（再生・書き出しに使う）─────
type Settings = Record<string, TrackSettings> | undefined;
const ts = (m: Settings, key: string): TrackSettings => m?.[key] ?? defaultTrackSettings();

export function v1Opacity(m: Settings): number { const s = ts(m, "V1"); return s.hidden ? 0 : s.opacity; }

export function effectiveClips(clips: MusicClip[], m: Settings): MusicClip[] {
  const out: MusicClip[] = [];
  for (const c of clips) {
    const s = ts(m, `A${c.track}`);
    if (s.muted) continue;
    out.push({ ...c, volume: c.volume * s.volume });
  }
  return out;
}

export function effectiveTitles(titles: TitleItem[], m: Settings): TitleItem[] {
  const out: TitleItem[] = [];
  for (const t of titles) {
    const s = ts(m, `T${t.track}`);
    if (s.hidden) continue;
    out.push({ ...t, opacity: t.opacity * s.opacity });
  }
  return out;
}

export function effectiveOverlays(clips: OverlayClip[], m: Settings): OverlayClip[] {
  const out: OverlayClip[] = [];
  for (const c of clips) {
    const s = ts(m, `O${c.track}`);
    if (s.hidden) continue;
    out.push({ ...c, opacity: c.opacity * s.opacity });
  }
  return out;
}

/** 音声クリップの、タイムライン上の長さ（使う範囲） */
export function clipLength(c: MusicClip): number {
  const out = Math.min(c.outPoint ?? c.duration, c.duration);
  return Math.max(0, out - c.inPoint);
}
export const clipEnd = (c: MusicClip) => c.start + clipLength(c);

export function overlayEnd(c: OverlayClip) { return c.start + c.duration; }

/** 書類の中身から、流す写真の並びの設定を取り出す */
export function timingSettings(p: ProjectFile): TimingSettings {
  return { dwell: p.dwell, transition: p.transition, transitionDuration: p.transitionDuration, fit: p.fit };
}
