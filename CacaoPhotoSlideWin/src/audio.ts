// 音声: 再生（WebAudio）と、書き出し用の混ぜ合わせ（OfflineAudioContext）。フェードと音量は同じ式。
import type { MusicClip } from "./model.ts";
import { clipEnd, clipLength } from "./engine.ts";
import { assetUrl } from "./images.ts";

export class AudioBank {
  ctx: AudioContext | null = null;
  private buffers = new Map<string, AudioBuffer>();
  private loading = new Map<string, Promise<AudioBuffer | undefined>>();
  private peaksCache = new Map<string, number[]>();

  private context(): AudioContext {
    if (!this.ctx) this.ctx = new AudioContext();
    return this.ctx;
  }

  get(path: string): AudioBuffer | undefined { return this.buffers.get(path); }

  async load(path: string): Promise<AudioBuffer | undefined> {
    const have = this.buffers.get(path);
    if (have) return have;
    let p = this.loading.get(path);
    if (!p) {
      p = (async () => {
        try {
          const res = await fetch(assetUrl(path));
          const data = await res.arrayBuffer();
          const buf = await this.context().decodeAudioData(data);
          this.buffers.set(path, buf);
          return buf;
        } catch { return undefined; } finally { this.loading.delete(path); }
      })();
      this.loading.set(path, p);
    }
    return p;
  }

  /** 波形（ピークを bins 個）。0〜1 */
  peaks(path: string, bins = 800): number[] | undefined {
    const c = this.peaksCache.get(path);
    if (c) return c;
    const b = this.buffers.get(path);
    if (!b) return undefined;
    const ch = [b.getChannelData(0), b.numberOfChannels > 1 ? b.getChannelData(1) : b.getChannelData(0)];
    const per = Math.max(1, Math.floor(b.length / bins));
    const out: number[] = [];
    for (let i = 0; i < bins; i++) {
      let m = 0;
      const from = i * per, to = Math.min(b.length, from + per);
      for (let j = from; j < to; j += Math.max(1, Math.floor(per / 64))) m = Math.max(m, Math.abs(ch[0][j]), Math.abs(ch[1][j]));
      out.push(m);
    }
    this.peaksCache.set(path, out);
    return out;
  }

  // ───── 再生 ─────
  private sources: AudioScheduled[] = [];

  /** タイムラインの from 秒から鳴らす（再生ヘッドを動かしたら、もう一度呼ぶ） */
  play(clips: MusicClip[], from: number, total: number) {
    this.stop();
    const ctx = this.context();
    if (ctx.state === "suspended") void ctx.resume();
    this.sources = scheduleClips(ctx, ctx.destination, (p) => this.buffers.get(p), clips, from, total, ctx.currentTime + 0.05);
  }

  /** クリップの範囲だけを鳴らす（試聴）。もう一度呼ぶと止まる。鳴らしているクリップの id を返す */
  auditioning: string | null = null;
  audition(c: MusicClip, onEnd?: () => void) {
    if (this.auditioning === c.id) { this.stop(); this.auditioning = null; onEnd?.(); return; }
    const ctx = this.context();
    if (ctx.state === "suspended") void ctx.resume();
    this.stop();
    const copy: MusicClip = { ...c, start: 0 };
    const len = clipLength(copy);
    this.sources = scheduleClips(ctx, ctx.destination, (p) => this.buffers.get(p), [copy], 0, len + 100, ctx.currentTime + 0.05);
    this.auditioning = c.id;
    const first = this.sources[0]?.src;
    if (first) first.onended = () => { if (this.auditioning === c.id) { this.auditioning = null; onEnd?.(); } };
  }

  stop() {
    for (const s of this.sources) { try { s.src.stop(); } catch { /* 止まっている */ } s.src.disconnect(); s.gain.disconnect(); }
    this.sources = [];
    this.auditioning = null;
  }

  // ───── 書き出し用 ─────
  /** 全体を 1 本の WAV（16bit・44.1kHz・ステレオ）に混ぜる。音声がなければ null */
  async mixToWav(clips: MusicClip[], total: number): Promise<Uint8Array | null> {
    const usable = clips.filter((c) => c.start < total && clipLength(c) > 0.05);
    if (!usable.length) return null;
    for (const c of usable) await this.load(c.path);
    const rate = 44100;
    const off = new OfflineAudioContext(2, Math.max(1, Math.ceil(total * rate)), rate);
    scheduleClips(off, off.destination, (p) => this.buffers.get(p), usable, 0, total, 0);
    const rendered = await off.startRendering();
    return encodeWav(rendered);
  }
}

interface AudioScheduled { src: AudioBufferSourceNode; gain: GainNode }

/** クリップの、タイムライン上の時刻 t での音量（フェードを含む）。動画の終わりで切れるクリップは、最後の 3 秒でフェードアウト */
export function clipGain(c: MusicClip, t: number, total: number): number {
  const len = clipLength(c);
  const end = c.start + len;
  if (t < c.start || t > end) return 0;
  const fi = Math.min(c.fadeIn, len / 2);
  const cut = end >= total - 1e-6;
  const fo = Math.min(cut ? 3 : c.fadeOut, len / 2);
  let g = c.volume;
  if (fi > 0) g *= Math.min(1, (t - c.start) / fi);
  if (fo > 0) g *= Math.min(1, (end - t) / fo);
  return Math.max(0, g);
}

function scheduleClips(ctx: BaseAudioContext, dest: AudioNode, bufferOf: (p: string) => AudioBuffer | undefined,
                       clips: MusicClip[], from: number, total: number, base: number): AudioScheduled[] {
  const out: AudioScheduled[] = [];
  for (const c of clips) {
    const buf = bufferOf(c.path);
    const len = clipLength(c);
    const end = c.start + len;
    if (!buf || len <= 0.01 || end <= from) continue;
    const inside = Math.max(from, c.start);                 // 鳴らし始めるタイムライン上の時刻
    const when = base + (inside - from);
    const offset = c.inPoint + (inside - c.start);
    const dur = end - inside;
    const src = ctx.createBufferSource();
    src.buffer = buf;
    const gain = ctx.createGain();
    const g = gain.gain;
    g.setValueAtTime(clipGain(c, inside, total), when);
    const len2 = len;
    const fi = Math.min(c.fadeIn, len2 / 2);
    const cut = end >= total - 1e-6;
    const fo = Math.min(cut ? 3 : c.fadeOut, len2 / 2);
    const pts: number[] = [];
    if (fi > 0) pts.push(c.start + fi);
    if (fo > 0) pts.push(end - fo);
    pts.push(end);
    for (const pt of pts) if (pt > inside) g.linearRampToValueAtTime(clipGain(c, pt, total), base + (pt - from));
    src.connect(gain).connect(dest);
    src.start(when, offset, dur);
    out.push({ src, gain });
  }
  return out;
}

function encodeWav(buf: AudioBuffer): Uint8Array {
  const n = buf.length, ch = 2;
  const bytes = new Uint8Array(44 + n * ch * 2);
  const v = new DataView(bytes.buffer);
  const wr = (o: number, s: string) => { for (let i = 0; i < s.length; i++) v.setUint8(o + i, s.charCodeAt(i)); };
  wr(0, "RIFF"); v.setUint32(4, 36 + n * ch * 2, true); wr(8, "WAVE"); wr(12, "fmt ");
  v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, ch, true);
  v.setUint32(24, buf.sampleRate, true); v.setUint32(28, buf.sampleRate * ch * 2, true); v.setUint16(32, ch * 2, true); v.setUint16(34, 16, true);
  wr(36, "data"); v.setUint32(40, n * ch * 2, true);
  const l = buf.getChannelData(0), r = buf.numberOfChannels > 1 ? buf.getChannelData(1) : l;
  let o = 44;
  for (let i = 0; i < n; i++) {
    for (const s of [l[i], r[i]]) { v.setInt16(o, Math.max(-1, Math.min(1, s)) * 0x7fff, true); o += 2; }
  }
  return bytes;
}

export { clipEnd };
