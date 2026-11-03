// mp4 書き出し: 1 コマずつ描いて、ffmpeg に渡す。音声は先に混ぜて WAV にする。
import { native, joinPath } from "./native.ts";
import { drawFrame, type ImageSource } from "./render.ts";
import { decodeImage } from "./images.ts";
import { store } from "./store.ts";
import { EXPORT_SIZES } from "./model.ts";

export interface ExportJob { cancelled: boolean; progress: number; message: string; state: "running" | "done" | "failed" | "cancelled"; output?: string }

export async function exportMovie(output: string, job: ExportJob, onProgress: () => void): Promise<void> {
  const update = (message: string, progress = job.progress) => { job.message = message; job.progress = progress; onProgress(); };
  try {
    let ff = (await native.ffmpegStatus());
    if (!ff.path) {
      if (!ff.can_install) throw new Error("ffmpeg が見つかりません。Mac では brew install ffmpeg を実行してください。");
      update("ffmpeg を用意しています…（初回だけ）", 0);
      ff = await native.installFfmpeg();
      if (!ff.path) throw new Error("ffmpeg を用意できませんでした");
    }
    const size = EXPORT_SIZES.find((s) => s.id === store.p.exportSize) ?? EXPORT_SIZES[1];
    const W = size.w, H = size.h, fps = store.p.exportFps || 30;
    const scene = { ...store.scene(), exporting: true };
    const total = scene.timing.total;
    if (!scene.timing.count) throw new Error("写真がありません");
    const frames = Math.round(total * fps);
    const maxPixel = Math.round(Math.max(W, H) * 1.3);

    // 音声（先に混ぜる）
    update("音声を混ぜています…", 0);
    const wav = await store.audio.mixToWav(store.effectiveClips(), total);
    let audioPath: string | null = null;
    if (wav) {
      audioPath = joinPath(await native.tempDir(), `cacaophotoslide-audio-${Date.now()}.wav`);
      await native.writeBytes(audioPath, wav);
    }

    await native.exportBegin({ ffmpeg: ff.path, width: W, height: H, fps, audio: audioPath, output, crf: 18 });
    const cv = document.createElement("canvas");
    cv.width = W; cv.height = H;
    const ctx = cv.getContext("2d", { willReadFrequently: true })!;
    const cache = store.images;
    const overlayImgs = new Map<string, ImageBitmap>();
    for (const c of scene.overlays) {
      // V2 の写真は、キャッシュに入れず別に持つ（キャッシュが古いものを閉じるので、書き出しの間ずっと使うものは別に）
      if (!overlayImgs.has(c.path)) { try { overlayImgs.set(c.path, await decodeImage(c.path, maxPixel)); } catch { /* 読めない写真は飛ばす */ } }
    }
    const src: ImageSource = { v1: (i) => cache.get(scene.paths[i], maxPixel), overlay: (p) => overlayImgs.get(p) };

    try {
      for (let f = 0; f < frames; f++) {
        if (job.cancelled) { await native.exportCancel(); job.state = "cancelled"; update("中止しました"); return; }
        const t = f / fps;
        const k = scene.timing.index(t);
        for (const j of [k - 1, k, k + 1]) if (scene.paths[j]) await cache.request(scene.paths[j], maxPixel);
        drawFrame(ctx, W, H, t, scene, src);
        const data = ctx.getImageData(0, 0, W, H).data;
        await native.exportFrame(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
        if (f % 5 === 0) update(`書き出し中… ${f} / ${frames} コマ`, f / frames);
      }
      await native.exportEnd();
    } catch (e) {
      await native.exportCancel().catch(() => {});
      throw e;
    } finally {
      if (audioPath) void native.removePath(audioPath).catch(() => {});
    }
    for (const b of overlayImgs.values()) b.close();
    job.state = "done"; job.output = output;
    update("書き出しました", 1);
  } catch (e: any) {
    job.state = "failed";
    update(String(e?.message ?? e));
  }
}
