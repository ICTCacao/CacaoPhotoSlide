// 書類（.cpsd）の読み書き。中身は Mac 版と同じ（フォルダに project.json と audio/ photos/ overlays/）。
import { native, basename, dirname, isAbsolute, joinPath, stem, extname } from "./native.ts";
import { normalizeProject, type ProjectFile } from "./model.ts";

export const PROJECT_JSON = "project.json";

export async function readProject(docDir: string): Promise<ProjectFile> {
  const text = await native.readText(joinPath(docDir, PROJECT_JSON));
  return normalizeProject(JSON.parse(text));
}

const abs = (docDir: string, p: string) => (isAbsolute(p) ? p : joinPath(docDir, p));

/** 書類の中の相対パスを、絶対パスにする */
export function resolveProject(f: ProjectFile, docDir: string): ProjectFile {
  const r = (p: string) => abs(docDir, p);
  const o: ProjectFile = JSON.parse(JSON.stringify(f));
  o.selection = f.selection.map(r);
  o.manualOrder = f.manualOrder.map(r);
  o.overlayLibrary = f.overlayLibrary.map(r);
  o.overlayClips = f.overlayClips.map((c) => ({ ...c, path: r(c.path) }));
  o.clips = f.clips.map((c) => ({ ...c, path: c.path ? r(c.path) : c.path }));
  o.overrides = Object.fromEntries(Object.entries(f.overrides).map(([k, v]) => [r(k), v]));
  o.excluded = f.excluded.map(r);
  return o;
}

const pad4 = (n: number) => String(n).padStart(4, "0");

export interface SaveOptions {
  /** 写真（V1）も書類の中にコピーする */
  includePhotos: boolean;
  /** 開いている写真（今の順番。外した写真を含まない） */
  photos: string[];
  progress?: (i: number, n: number) => void;
}

/** 書類を書く。音声は audio/ にコピーして相対パスにする。写真を入れるなら photos/（連番）と overlays/ にコピーする。
 *  file は絶対パスで持っているもの。戻り値は、書いたとおり（相対パス）の ProjectFile */
export async function writeProject(docDir: string, file: ProjectFile, opt: SaveOptions): Promise<ProjectFile> {
  await native.ensureDir(docDir);
  const out: ProjectFile = JSON.parse(JSON.stringify(file));
  const insideDoc = (p: string, sub: string) => dirname(p).replace(/\\/g, "/") === joinPath(docDir, sub).replace(/\\/g, "/");

  if (opt.includePhotos) {
    const photosDir = joinPath(docDir, "photos");
    await native.ensureDir(photosDir);
    const map = new Map<string, string>();
    const keep = new Set<string>();
    for (let i = 0; i < opt.photos.length; i++) {
      opt.progress?.(i, opt.photos.length);
      const src = opt.photos[i];
      const name = insideDoc(src, "photos") ? basename(src) : `${pad4(i + 1)}_${basename(src)}`;
      if (!insideDoc(src, "photos")) await native.copyFile(src, joinPath(photosDir, name));
      map.set(src, `photos/${name}`);
      keep.add(name);
    }
    for (const e of await native.listDir(photosDir)) if (!keep.has(e.name)) await native.removePath(joinPath(photosDir, e.name));
    out.includesPhotos = true;
    out.selection = file.selection.map((p) => map.get(p)).filter((x): x is string => !!x);
    out.overrides = Object.fromEntries(Object.entries(file.overrides).map(([k, v]) => [map.get(k), v]).filter(([k]) => !!k) as [string, any][]);
    if (file.order === "manual") out.manualOrder = opt.photos.map((p) => map.get(p)!).filter(Boolean);
    out.excluded = [];

    // V2 の写真
    const ovDir = joinPath(docDir, "overlays");
    await native.ensureDir(ovDir);
    const omap = new Map<string, string>();
    const okeep = new Set<string>();
    for (let i = 0; i < file.overlayLibrary.length; i++) {
      const src = file.overlayLibrary[i];
      const name = insideDoc(src, "overlays") ? basename(src) : `${pad4(i + 1)}_${basename(src)}`;
      if (!insideDoc(src, "overlays")) await native.copyFile(src, joinPath(ovDir, name));
      omap.set(src, `overlays/${name}`);
      okeep.add(name);
    }
    for (const e of await native.listDir(ovDir)) if (!okeep.has(e.name)) await native.removePath(joinPath(ovDir, e.name));
    out.overlayLibrary = file.overlayLibrary.map((p) => omap.get(p)).filter((x): x is string => !!x);
    out.overlayClips = file.overlayClips.map((c) => ({ ...c, path: omap.get(c.path) ?? c.path }));
  } else {
    out.includesPhotos = false;
    await native.removePath(joinPath(docDir, "photos")).catch(() => {});
  }

  // 音声は、いつも audio/ にコピー（同名で別のファイルなら番号を付ける）
  const audioDir = joinPath(docDir, "audio");
  await native.ensureDir(audioDir);
  const used = new Set<string>();
  const taken = new Map<string, string>();               // コピー元 → audio/ の中の名前
  for (const c of out.clips) {
    const src = c.path;
    let name = taken.get(src);
    if (!name) {
      if (insideDoc(src, "audio")) name = basename(src);
      else {
        name = basename(src);
        let n = 2;
        while (used.has(name)) { name = `${stem(src)}-${n}.${extname(src)}`; n++; }
        await native.copyFile(src, joinPath(audioDir, name));
      }
      taken.set(src, name);
    }
    used.add(name);
    c.path = `audio/${name}`;
  }
  for (const e of await native.listDir(audioDir)) if (!used.has(e.name)) await native.removePath(joinPath(audioDir, e.name));

  out.sources = file.sources;
  await native.writeText(joinPath(docDir, PROJECT_JSON), JSON.stringify(out, null, 1));
  return out;
}
