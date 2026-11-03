// 写真の読み込み。大きい写真は、使う大きさに縮めて持つ（前後数枚だけキャッシュ）。サムネイルは別に、小さく持つ。
import { convertFileSrc } from "@tauri-apps/api/core";

export const assetUrl = (path: string) => convertFileSrc(path);

async function fetchBlob(path: string): Promise<Blob> {
  const res = await fetch(assetUrl(path));
  if (!res.ok) throw new Error(`${path}: ${res.status}`);
  return res.blob();
}

/** 長辺 maxPixel 以下に縮めて読む（小さい写真は拡大しない）。EXIF の向きは、ブラウザが反映する */
export async function decodeImage(path: string, maxPixel: number): Promise<ImageBitmap> {
  const blob = await fetchBlob(path);
  const full = await createImageBitmap(blob);
  const long = Math.max(full.width, full.height);
  if (long <= maxPixel) return full;
  const r = maxPixel / long;
  const w = Math.max(1, Math.round(full.width * r)), h = Math.max(1, Math.round(full.height * r));
  const cv = document.createElement("canvas");
  cv.width = w; cv.height = h;
  const c = cv.getContext("2d")!;
  c.imageSmoothingQuality = "high";
  c.drawImage(full, 0, 0, w, h);
  full.close();
  return createImageBitmap(cv);
}

/** 近くの写真だけ持つキャッシュ（古いものから捨てる） */
export class ImageCache {
  private map = new Map<string, { bmp: ImageBitmap; px: number }>();
  private loading = new Map<string, Promise<ImageBitmap | undefined>>();
  constructor(private capacity = 8) {}

  get(path: string, px: number): ImageBitmap | undefined {
    const e = this.map.get(path);
    if (!e || e.px < px * 0.9) return undefined;
    this.map.delete(path);       // 使った順に並べ直す
    this.map.set(path, e);
    return e.bmp;
  }

  /** 読み込みを始める（読み終わったら返す。失敗したら undefined） */
  request(path: string, px: number): Promise<ImageBitmap | undefined> {
    const have = this.get(path, px);
    if (have) return Promise.resolve(have);
    const key = `${path}@${px}`;
    let p = this.loading.get(key);
    if (!p) {
      p = decodeImage(path, px).then((bmp) => {
        const old = this.map.get(path);
        if (old) old.bmp.close();
        this.map.set(path, { bmp, px });
        while (this.map.size > this.capacity) {
          const k = this.map.keys().next().value as string;
          this.map.get(k)?.bmp.close();
          this.map.delete(k);
        }
        return bmp;
      }).catch(() => undefined).finally(() => this.loading.delete(key));
      this.loading.set(key, p);
    }
    return p;
  }

  clear() { for (const e of this.map.values()) e.bmp.close(); this.map.clear(); }
}

/** サムネイル（一覧・タイムライン用）。読み終わったら onLoad を呼ぶ */
export class Thumbs {
  private map = new Map<string, ImageBitmap>();
  private pending = new Set<string>();
  private queue: string[] = [];
  private running = 0;
  onLoad: (() => void) | null = null;

  get(path: string): ImageBitmap | undefined { return this.map.get(path); }

  request(path: string) {
    if (this.map.has(path) || this.pending.has(path)) return;
    this.pending.add(path);
    this.queue.push(path);
    this.pump();
  }

  private pump() {
    while (this.running < 4 && this.queue.length) {
      const path = this.queue.shift()!;
      this.running++;
      decodeImage(path, 192).then((b) => { this.map.set(path, b); this.onLoad?.(); })
        .catch(() => {})
        .finally(() => { this.running--; this.pending.delete(path); this.pump(); });
    }
  }

  drop(path: string) { this.map.get(path)?.close(); this.map.delete(path); }
}
