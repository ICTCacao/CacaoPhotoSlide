// 再生: 時刻を進めて、1 コマずつ描き、音を鳴らす。タイムラインのプレビューと、全画面のスライドショーが使う。
import { drawFrame, type ImageSource, type Scene } from "./render.ts";
import { store } from "./store.ts";

const PREVIEW_PX = 1600;

export class Player {
  playing = false;
  /** 流している時刻（秒）。止めているときは、その位置 */
  time = 0;
  private startWall = 0;
  private startTime = 0;
  private raf = 0;
  private scene: Scene | null = null;
  canvas: HTMLCanvasElement | null = null;
  maxPixel = PREVIEW_PX;
  /** 再生が終わったとき */
  onEnd: (() => void) | null = null;
  /** 毎コマ（時刻の表示などの更新用） */
  onTick: ((t: number) => void) | null = null;
  loop = false;

  attach(canvas: HTMLCanvasElement | null) { this.canvas = canvas; }

  /** 流すシーンを決めておく（全画面で、開始時に固める） */
  scene0(sc: Scene) { this.scene = sc; this.locked = true; }
  private locked = false;

  /** t 秒から流す */
  play(t = store.playhead) {
    if (!this.locked || !this.scene) this.scene = store.scene();
    const total = this.scene.timing.total;
    this.time = t >= total - 0.05 ? 0 : Math.max(0, t);
    this.startTime = this.time;
    this.startWall = performance.now();
    this.playing = true;
    store.audio.play(store.effectiveClips(), this.time, total);
    this.loopFrame();
  }

  pause() {
    if (!this.playing) return;
    this.playing = false;
    cancelAnimationFrame(this.raf);
    store.audio.stop();
    store.playhead = this.time;
    store.emit();
  }

  toggle() { if (this.playing) this.pause(); else this.play(store.playhead); }

  stop() { this.pause(); }

  /** 流している最中に、時刻を変える */
  seek(t: number) {
    if (!this.playing) return;
    this.time = Math.max(0, t);
    this.startTime = this.time;
    this.startWall = performance.now();
    store.audio.play(store.effectiveClips(), this.time, this.scene!.timing.total);
  }

  /** タイトル・V2・トラックの設定・音声が変わったとき、流しながら反映する */
  refreshLive() {
    if (!this.playing || this.locked) return;
    this.scene = store.scene();
    store.audio.play(store.effectiveClips(), this.time, this.scene.timing.total);
  }

  private loopFrame = () => {
    if (!this.playing || !this.scene) return;
    const now = performance.now();
    let t = this.startTime + (now - this.startWall) / 1000;
    const total = this.scene.timing.total;
    if (t >= total) {
      if (this.loop) { this.startTime = 0; this.startWall = now; t = 0; store.audio.play(store.effectiveClips(), 0, total); }
      else { this.time = total; this.draw(); this.playing = false; store.audio.stop(); store.playhead = 0; store.emit(); this.onEnd?.(); return; }
    }
    this.time = t;
    this.prefetch(t);
    this.draw();
    this.onTick?.(t);
    this.raf = requestAnimationFrame(this.loopFrame);
  };

  private prefetch(t: number) {
    const sc = this.scene!;
    const k = sc.timing.index(t);
    for (const d of [-1, 0, 1, 2]) {
      const j = this.loop ? (k + d + sc.paths.length) % sc.paths.length : k + d;
      if (sc.paths[j]) void store.images.request(sc.paths[j], this.maxPixel);
    }
    for (const c of sc.overlays) if (t > c.start - 3 && t < c.start + c.duration + 1) void store.images.request(c.path, this.maxPixel);
  }

  /** いまの時刻のコマを描く（止めているときの静止画も、これで描く） */
  draw(opts: { still?: boolean } = {}) {
    if (!this.canvas) return;
    const cv = this.canvas;
    const sc = this.scene ?? store.scene();
    const ctx = cv.getContext("2d")!;
    drawFrame(ctx, cv.width, cv.height, this.time, sc, this.srcFor(sc), { settled: opts.still, still: opts.still });
  }

  private srcFor(sc: Scene): ImageSource {
    return {
      v1: (i) => store.images.get(sc.paths[i], this.maxPixel),
      overlay: (p) => store.images.get(p, this.maxPixel),
    };
  }

  /** 止めているときの静止画（再生ヘッドの位置）。写真は読み込んでから描く */
  async drawStill(t: number) {
    if (!this.canvas || this.playing) return;
    const sc = store.scene();
    this.scene = sc;
    this.time = t;
    const k = sc.timing.index(t);
    if (sc.paths[k]) await store.images.request(sc.paths[k], this.maxPixel);
    for (const c of sc.overlays) if (t >= c.start && t <= c.start + c.duration) await store.images.request(c.path, this.maxPixel);
    if (!this.playing) this.draw({ still: true });
  }
}

export const player = new Player();
