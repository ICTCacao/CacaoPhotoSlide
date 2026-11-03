// Rust 側の命令の呼び出し口。
import { invoke } from "@tauri-apps/api/core";

export const native = {
  listImages: (paths: string[], recursive: boolean) => invoke<string[]>("list_images", { paths, recursive }),
  photoDates: (paths: string[]) => invoke<number[]>("photo_dates", { paths }),
  readText: (path: string) => invoke<string>("read_text", { path }),
  writeText: (path: string, text: string) => invoke<void>("write_text", { path, text }),
  writeBytes: (path: string, bytes: Uint8Array) => invoke<void>("write_bytes", bytes, { headers: { "x-path": encodeURIComponent(path) } }),
  pathExists: (path: string) => invoke<boolean>("path_exists", { path }),
  isDir: (path: string) => invoke<boolean>("is_dir", { path }),
  ensureDir: (path: string) => invoke<void>("ensure_dir", { path }),
  copyFile: (src: string, dst: string) => invoke<void>("copy_file", { src, dst }),
  removePath: (path: string) => invoke<void>("remove_path", { path }),
  listDir: (path: string) => invoke<{ name: string; is_dir: boolean }[]>("list_dir", { path }),
  tempDir: () => invoke<string>("temp_dir"),
  documentsDir: () => invoke<string>("documents_dir"),
  appDataDir: () => invoke<string>("app_data_dir"),
  getEnv: (name: string) => invoke<string | null>("get_env", { name }),
  reveal: (path: string) => invoke<void>("reveal", { path }),
  ffmpegStatus: () => invoke<{ path: string | null; can_install: boolean }>("ffmpeg_status"),
  installFfmpeg: () => invoke<{ path: string | null; can_install: boolean }>("install_ffmpeg"),
  exportBegin: (a: { ffmpeg: string; width: number; height: number; fps: number; audio: string | null; output: string; crf: number }) =>
    invoke<void>("export_begin", a),
  exportFrame: (bytes: Uint8Array) => invoke<void>("export_frame", bytes),
  exportEnd: () => invoke<void>("export_end"),
  exportCancel: () => invoke<void>("export_cancel"),
};

// ───── パス ─────
export const sep = (p: string) => (p.includes("\\") && !p.includes("/") ? "\\" : "/");
export const basename = (p: string) => p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? p;
export const dirname = (p: string) => { const t = p.replace(/[\\/]+$/, ""); const i = Math.max(t.lastIndexOf("/"), t.lastIndexOf("\\")); return i < 0 ? "" : t.slice(0, i); };
export const joinPath = (a: string, ...rest: string[]) => [a.replace(/[\\/]+$/, ""), ...rest].join(sep(a));
export const isAbsolute = (p: string) => /^([\\/]|[A-Za-z]:[\\/])/.test(p);
export const extname = (p: string) => { const b = basename(p); const i = b.lastIndexOf("."); return i <= 0 ? "" : b.slice(i + 1).toLowerCase(); };
export const stem = (p: string) => { const b = basename(p); const i = b.lastIndexOf("."); return i <= 0 ? b : b.slice(0, i); };
export const AUDIO_EXT = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma", "mp4", "caf"];
export const isAudioPath = (p: string) => AUDIO_EXT.includes(extname(p));
export const isImagePath = (p: string) => ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "tif", "tiff"].includes(extname(p));
export const isDocumentPath = (p: string) => extname(p) === "cpsd";
export const naturalCompare = (a: string, b: string) => a.localeCompare(b, "ja", { numeric: true, sensitivity: "base" });
