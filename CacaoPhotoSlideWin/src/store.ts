// アプリの状態と、その操作（Mac 版の AppModel.swift の移植）。画面は、ここの状態を読んで描き、操作はここの関数を呼ぶ。
import {
  type FitMode, type MusicClip, type OverlayClip, type PhotoOrder, type PhotoOverride, type ProjectFile, type TabName, type TitleItem,
  type TrackSettings, type Transition, defaultProject, defaultTrackSettings, newMusic, newOverlay, newTitle, normalizeProject, trackKey, uuid,
} from "./model.ts";
import {
  SlideTiming, clamp, clipEnd, clipLength, effectiveClips, effectiveOverlays, effectiveTitles, mulberry32, timingSettings, v1Opacity,
} from "./engine.ts";
import type { Scene } from "./render.ts";
import { AudioBank } from "./audio.ts";
import { ImageCache, Thumbs } from "./images.ts";
import { basename, dirname, isAbsolute, isAudioPath, isDocumentPath, isImagePath, joinPath, naturalCompare, native, stem } from "./native.ts";
import { readProject, resolveProject, writeProject } from "./project.ts";

export type LibraryMode = "v1" | "v2";
export type TrackKind = "title" | "overlay" | "audio";
export interface TrackRef { kind: TrackKind | "main"; index: number }

const LS = {
  lastDoc: "cps.lastDocument", lastSources: "cps.lastSources", previewHeight: "cps.previewHeight", defaults: "cps.defaults",
};

export class Store {
  p: ProjectFile = defaultProject();
  photos: string[] = [];
  removed = new Set<string>();                  // 外した写真（流さず、書類にもコピーしない）
  selection = new Set<string>();                // 「写真」のタブの選択（2 枚以上なら、その写真だけを流す）
  private selAnchor: string | null = null;
  documentPath: string | null = null;
  scanning = false;
  message = "";
  seed = Math.floor(Math.random() * 2 ** 31);

  tab: TabName = "photos";
  libraryMode: LibraryMode = "v1";
  playhead = 0;
  timelineZoom = 1;
  previewHeight = 300;

  // タイムラインの選択
  timelineSel = new Set<string>();              // V1 の写真
  private timelineAnchor: number | null = null;
  selOverlays = new Set<string>();              // V2 のクリップ
  private overlayAnchor: string | null = null;
  selTitles = new Set<string>();
  selClip: string | null = null;                // 選んでいる音声クリップ
  overlaySel = new Set<string>();               // V2 ライブラリで選んでいる写真

  // 開いている画面
  sheet: { kind: "titles" | "overlay" | "override" | "track" | "color" | "export" | "viewer" | "viewerImage" | "settings"; arg?: any } | null = null;

  readonly thumbs = new Thumbs();
  readonly images = new ImageCache(16);
  readonly audio = new AudioBank();

  private listeners = new Set<() => void>();
  private pending = false;
  /** 再生中に、タイトル・V2・音声を変えたとき（プレイヤーが受け取って、その場で反映する） */
  onLiveChange: (() => void) | null = null;

  constructor() {
    this.thumbs.onLoad = () => this.emit();
    this.previewHeight = Number(localStorage.getItem(LS.previewHeight)) || 300;
  }

  // ───── 変更の通知 ─────
  subscribe(fn: () => void) { this.listeners.add(fn); return () => this.listeners.delete(fn); }
  emit() {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => { this.pending = false; for (const f of this.listeners) f(); });
  }
  private live() { this.onLiveChange?.(); this.emit(); }
  emitSoon() { this.emit(); }

  // ───── 流す写真・時間 ─────
  get documentTitle() { return this.documentPath ? stem(this.documentPath) : "名称未設定"; }

  /** 流す写真（選んだ写真だけ、または全部。順番がランダムなら、種で決めた並び） */
  playPaths(): string[] {
    let list = this.selection.size >= 2 ? this.photos.filter((p) => this.selection.has(p)) : this.photos;
    if (this.p.order === "random") list = shuffled(list, this.seed);
    return list;
  }

  timing(): SlideTiming { return new SlideTiming(this.playPaths(), timingSettings(this.p), this.p.overrides); }
  get totalDuration() { return this.timing().total; }
  get playCount() { return this.playPaths().length; }

  scene(): Scene {
    const paths = this.playPaths();
    return {
      paths, timing: new SlideTiming(paths, timingSettings(this.p), this.p.overrides), seed: this.seed,
      v1Opacity: v1Opacity(this.p.trackSettings), overlays: effectiveOverlays(this.p.overlayClips, this.p.trackSettings),
      titles: effectiveTitles(this.p.titles, this.p.trackSettings), transition: this.p.transition, fit: this.p.fit,
      endFade: this.p.endFade, loop: this.p.loop,
    };
  }

  effectiveClips(): MusicClip[] { return effectiveClips(this.p.clips, this.p.trackSettings); }

  overrideCountInPlay(): number { return this.playPaths().filter((u) => { const o = this.p.overrides[u]; return o && (o.dwell !== undefined || o.transition || o.fit); }).length; }

  // ───── 写真を開く ─────
  async load(paths: string[]) {
    const doc = paths.find(isDocumentPath);
    if (doc) { await this.openDocument(doc); return; }
    const audio = paths.filter(isAudioPath);
    for (const a of audio) await this.addClip(a, null);
    const list = paths.filter((p) => !isAudioPath(p)).sort(naturalCompare);
    if (!list.length) return;
    await this.setSources(list);
  }

  private async setSources(list: string[]) {
    this.p.sources = list;
    this.removed.clear();
    this.p.overrides = {};
    localStorage.setItem(LS.lastSources, JSON.stringify(list));
    await this.rescan();
  }

  async restoreLast() {
    if (this.p.sources.length) return;
    const doc = localStorage.getItem(LS.lastDoc);
    if (doc && await native.pathExists(doc)) { await this.openDocument(doc); return; }
    try {
      const s: string[] = JSON.parse(localStorage.getItem(LS.lastSources) ?? "[]");
      const ok: string[] = [];
      for (const x of s) if (await native.pathExists(x)) ok.push(x);
      if (ok.length) await this.setSources(ok);
    } catch { /* なし */ }
  }

  private pendingSelection: string[] = [];

  async rescan() {
    this.thumbsForget();
    this.selection.clear(); this.selAnchor = null; this.timelineSel.clear();
    if (!this.p.sources.length) { this.photos = []; this.emit(); return; }
    this.scanning = true; this.message = ""; this.emit();
    const found = [...new Set(await native.listImages(this.p.sources, this.p.recursive))].filter((x) => !this.removed.has(x));
    let list = found.sort(naturalCompare);
    if (this.p.order === "date") {
      const dates = await native.photoDates(list);
      const map = new Map(list.map((p, i) => [p, dates[i]]));
      list.sort((a, b) => (map.get(a)! === map.get(b)! ? naturalCompare(a, b) : map.get(a)! - map.get(b)!));
    } else if (this.p.order === "manual") {
      const rank = new Map(this.p.manualOrder.map((p, i) => [p, i]));
      list.sort((a, b) => { const ra = rank.get(a) ?? Infinity, rb = rank.get(b) ?? Infinity; return ra === rb ? naturalCompare(a, b) : ra - rb; });
    }
    this.photos = list;
    this.scanning = false;
    this.message = list.length ? "" : "写真が見つかりませんでした";
    if (this.pendingSelection.length) {
      const want = new Set(this.pendingSelection);
      for (const p of list) if (want.has(p)) this.selection.add(p);
      this.pendingSelection = [];
    }
    this.emit();
  }

  private thumbsForget() { /* サムネイルは写真のパスで持っているので、そのまま使い回す */ }

  async openPanel() {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const sel = await open({ multiple: true, directory: true, title: "写真のフォルダを選んでください" });
    if (!sel) return;
    await this.load(Array.isArray(sel) ? sel : [sel]);
  }

  async openFilesPanel() {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const sel = await open({ multiple: true, title: "写真（または音声）を選んでください", filters: [{ name: "写真・音声", extensions: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "tif", "tiff", "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"] }] });
    if (!sel) return;
    await this.load(Array.isArray(sel) ? sel : [sel]);
  }

  // ───── 設定（全体）─────
  setOrder(o: PhotoOrder) {
    const old = this.p.order;
    if (o === old) return;
    this.p.order = o;
    if (o === "manual") { this.p.manualOrder = [...this.photos]; this.emit(); } else void this.rescan();
  }
  setRecursive(v: boolean) { if (v !== this.p.recursive) { this.p.recursive = v; void this.rescan(); } }
  set<K extends keyof ProjectFile>(key: K, v: ProjectFile[K]) { this.p[key] = v; this.live(); }

  // ───── 写真を外す ─────
  removePhotos(paths: string[]) {
    const set = new Set(paths);
    if (!set.size) return;
    for (const p of set) this.removed.add(p);
    this.photos = this.photos.filter((p) => !set.has(p));
    this.selection.clear(); this.selAnchor = null;
    for (const p of set) this.timelineSel.delete(p);
    this.emit();
  }
  get removedCount() { return this.removed.size; }
  restoreRemoved() { if (!this.removed.size) return; this.removed.clear(); void this.rescan(); }

  // ───── 「写真」のタブの選択 ─────
  click(path: string, mod: { meta: boolean; shift: boolean }) {
    if (mod.meta) {
      if (this.selection.has(path)) this.selection.delete(path); else this.selection.add(path);
      this.selAnchor = path;
    } else if (mod.shift && this.selAnchor) {
      const a = this.photos.indexOf(this.selAnchor), b = this.photos.indexOf(path);
      if (a >= 0 && b >= 0) for (let i = Math.min(a, b); i <= Math.max(a, b); i++) this.selection.add(this.photos[i]);
    } else {
      this.selection = new Set([path]); this.selAnchor = path;
    }
    this.emit();
  }
  selectAll() { this.selection = new Set(this.photos); this.emit(); }
  clearSelection() { this.selection.clear(); this.selAnchor = null; this.emit(); }

  get selectionLabel(): string | null {
    if (this.selection.size >= 2) return `選んだ ${this.selection.size} 枚だけを流します`;
    const p = [...this.selection][0];
    if (!p) return null;
    return `開始: ${this.photos.indexOf(p) + 1} 枚目  ${basename(p)}`;
  }

  // ───── 並べ替え ─────
  /** moved の写真を、残りの写真の at 番目に差し込む。順番は「手動」になる */
  private reorder(moved: string[], at: number) {
    const set = new Set(moved.filter((p) => this.photos.includes(p)));
    if (!set.size) return;
    const items = this.photos.filter((p) => set.has(p));
    const rest = this.photos.filter((p) => !set.has(p));
    rest.splice(clamp(at, 0, rest.length), 0, ...items);
    if (rest.length === this.photos.length && rest.every((p, i) => p === this.photos[i])) return;
    this.photos = rest;
    this.p.order = "manual";
    this.p.manualOrder = [...this.photos];
    this.emit();
  }

  /** target の写真の位置へ。前へ動かすなら手前、後ろへ動かすなら後ろに入る */
  movePhotos(paths: string[], target: string) {
    const idx = paths.map((p) => this.photos.indexOf(p)).filter((i) => i >= 0).sort((a, b) => a - b);
    const t = this.photos.indexOf(target);
    if (!idx.length || t < 0 || idx.includes(t)) return;
    let at = t - idx.filter((i) => i < t).length;
    if (idx[0] < t) at += 1;
    this.reorder(idx.map((i) => this.photos[i]), at);
  }

  moveToEdge(paths: string[], front: boolean) { this.reorder(paths, front ? 0 : Number.MAX_SAFE_INTEGER); }

  moveSelection(delta: number) {
    const idx = this.photos.map((p, i) => (this.selection.has(p) ? i : -1)).filter((i) => i >= 0);
    if (!idx.length) return;
    const target = delta < 0 ? idx[0] - 1 : idx[idx.length - 1] + 1;
    if (this.photos[target]) this.movePhotos(idx.map((i) => this.photos[i]), this.photos[target]);
  }

  // ───── 写真ごとの設定 ─────
  setOverride(paths: string[], v: PhotoOverride) {
    const empty = v.dwell === undefined && !v.transition && !v.fit;
    for (const p of paths) { if (empty) delete this.p.overrides[p]; else this.p.overrides[p] = { ...v }; }
    this.live();
  }

  // ───── タイムラインの V1 の写真の選択・移動 ─────
  selectTimelinePhoto(k: number, mod: { meta: boolean; shift: boolean }) {
    const urls = this.playPaths();
    if (!urls[k]) return;
    if (mod.meta) {
      if (this.timelineSel.has(urls[k])) this.timelineSel.delete(urls[k]); else this.timelineSel.add(urls[k]);
      this.timelineAnchor = k;
    } else if (mod.shift && this.timelineAnchor !== null) {
      for (let i = Math.min(this.timelineAnchor, k); i <= Math.max(this.timelineAnchor, k); i++) this.timelineSel.add(urls[i]);
    } else {
      this.timelineSel = new Set([urls[k]]); this.timelineAnchor = k;
    }
    this.emit();
  }

  moveTimelinePhoto(from: number, to: number) {
    const urls = this.playPaths();
    if (!urls[from] || !urls[to] || from === to) return;
    const url = urls[from];
    if (this.timelineSel.size >= 2 && this.timelineSel.has(url)) {
      const group = this.photos.filter((p) => this.timelineSel.has(p));
      if (group.includes(urls[to])) return;
      this.movePhotos(group, urls[to]);
    } else this.movePhotos([url], urls[to]);
    const nk = this.playPaths().indexOf(url);
    if (nk >= 0) this.playhead = this.timing().starts[nk];
    this.emit();
  }

  // ───── 再生ヘッド ─────
  scrub(t: number) { this.playhead = clamp(t, 0, this.totalDuration); this.emit(); }
  stepPlayhead(delta: number) {
    const tm = this.timing();
    if (!tm.count) return;
    const i = tm.index(this.playhead);
    let target = i + delta;
    if (delta < 0 && this.playhead > tm.starts[i] + 0.05) target = i;
    this.playhead = tm.starts[clamp(target, 0, tm.count - 1)];
    this.emit();
  }

  // ───── 音声クリップ（A）─────
  get audioTrackCount() { return Math.max(0, this.p.audioTracks ?? 1, Math.max(-1, ...this.p.clips.map((c) => c.track)) + 1); }

  async addClip(path: string, start: number | null, track = 0) {
    const buf = await this.audio.load(path);
    const d = buf?.duration ?? 0;
    if (d < 0.1) return;
    const s = start ?? Math.max(0, ...this.p.clips.map(clipEnd));
    const clip = newMusic(basename(path), path, Math.max(0, s), d, Math.max(0, track));
    this.p.clips.push(clip);
    this.selClip = clip.id;
    if (start === null) this.resolveClipOverlaps();
    this.live();
  }

  resolveClipOverlaps() {
    const placed: MusicClip[] = [];
    for (const c of [...this.p.clips].sort((a, b) => a.start - b.start)) {
      let lane = c.track;
      while (placed.some((q) => q.track === lane && q.start < clipEnd(c) && c.start < clipEnd(q))) lane++;
      c.track = lane;
      placed.push(c);
    }
  }

  setClipTrack(id: string, lane: number) {
    const c = this.p.clips.find((x) => x.id === id);
    if (c) c.track = clamp(lane, 0, Math.max(0, this.audioTrackCount - 1));
    this.live();
  }

  moveClip(id: string, start: number, snap?: number, track?: number) {
    const c = this.p.clips.find((x) => x.id === id);
    if (!c) return;
    let s = Math.max(0, start);
    if (snap !== undefined) {
      const marks = this.timing().starts;
      let best = Infinity, near = s;
      for (const m of marks) if (Math.abs(m - s) < best) { best = Math.abs(m - s); near = m; }
      if (best <= snap) s = near;
      if (Math.abs(s) <= snap) s = 0;
    }
    c.start = s;
    if (track !== undefined) c.track = Math.max(0, track);
    this.live();
  }

  updateClip(id: string, change: (c: MusicClip) => void) {
    const c = this.p.clips.find((x) => x.id === id);
    if (!c) return;
    change(c);
    c.inPoint = clamp(c.inPoint, 0, Math.max(0, c.duration - 0.1));
    if (c.outPoint !== undefined) {
      c.outPoint = clamp(c.outPoint, c.inPoint + 0.1, c.duration);
      if (c.outPoint >= c.duration - 0.001) c.outPoint = undefined;
    }
    const len = clipLength(c);
    c.fadeIn = clamp(c.fadeIn, 0, len);
    c.fadeOut = clamp(c.fadeOut, 0, len);
    c.volume = clamp(c.volume, 0, 1);
    this.live();
  }

  trimHead(id: string, delta: number) {
    const c = this.p.clips.find((x) => x.id === id);
    if (!c) return;
    const effOut = Math.min(c.outPoint ?? c.duration, c.duration);
    const newIn = clamp(c.inPoint + delta, 0, effOut - 0.1);
    const applied = newIn - c.inPoint;
    const start = c.start;
    this.updateClip(id, (x) => { x.inPoint = newIn; x.start = Math.max(0, start + applied); });
  }

  removeClip(id: string) {
    this.p.clips = this.p.clips.filter((c) => c.id !== id);
    if (this.selClip === id) this.selClip = null;
    this.live();
  }

  async chooseMusic() {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const sel = await open({ multiple: true, title: "タイムラインに置く音声ファイルを選んでください", filters: [{ name: "音声", extensions: ["mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg"] }] });
    if (!sel) return;
    for (const f of Array.isArray(sel) ? sel : [sel]) await this.addClip(f, null);
  }

  // ───── トラックの数・設定 ─────
  get titleTrackCount() { return Math.max(0, this.p.titleTracks ?? 1, Math.max(-1, ...this.p.titles.map((t) => t.track)) + 1); }
  get overlayTrackCount() { return Math.max(0, this.p.overlayTracks ?? 0, Math.max(-1, ...this.p.overlayClips.map((c) => c.track)) + 1); }
  get trackCount() { return this.audioTrackCount; }

  addTrack(kind: TrackKind) {
    if (kind === "title") this.p.titleTracks = this.titleTrackCount + 1;
    else if (kind === "overlay") this.p.overlayTracks = this.overlayTrackCount + 1;
    else this.p.audioTracks = this.trackCount + 1;
    this.live();
  }

  isTrackEmpty(kind: TrackKind, index: number): boolean {
    if (kind === "title") return !this.p.titles.some((t) => t.track === index);
    if (kind === "overlay") return !this.p.overlayClips.some((c) => c.track === index);
    return !this.p.clips.some((c) => c.track === index);
  }

  /** 空のトラックを消す（上のトラックは 1 つ下がる）。V1 は消せない */
  removeTrack(kind: TrackKind, index: number) {
    if (!this.isTrackEmpty(kind, index)) return;
    const shift = (n: number, items: { track: number }[], key: "titleTracks" | "overlayTracks" | "audioTracks") => {
      if (n <= 0) return;
      for (const it of items) if (it.track > index) it.track -= 1;
      this.shiftTrackSettings(kind, index, n - 1);
      this.p[key] = n - 1;
    };
    if (kind === "title") shift(this.titleTrackCount, this.p.titles, "titleTracks");
    else if (kind === "overlay") shift(this.overlayTrackCount, this.p.overlayClips, "overlayTracks");
    else shift(this.trackCount, this.p.clips, "audioTracks");
    this.live();
  }

  private shiftTrackSettings(kind: TrackKind, removed: number, count: number) {
    const s = this.p.trackSettings;
    if (!s) return;
    for (let i = removed; i < count; i++) {
      const from = trackKey(kind, i + 1), to = trackKey(kind, i);
      if (s[from]) s[to] = s[from]; else delete s[to];
      delete s[from];
    }
  }

  trackSetting(ref: TrackRef): TrackSettings { return this.p.trackSettings?.[trackKey(ref.kind, ref.index)] ?? defaultTrackSettings(); }

  updateTrackSetting(ref: TrackRef, change: (s: TrackSettings) => void) {
    const s = { ...this.trackSetting(ref) };
    change(s);
    s.opacity = clamp(s.opacity, 0, 1);
    s.volume = clamp(s.volume, 0, 1);
    this.p.trackSettings ??= {};
    const key = trackKey(ref.kind, ref.index);
    if (s.opacity === 1 && !s.hidden && s.volume === 1 && !s.muted) delete this.p.trackSettings[key]; else this.p.trackSettings[key] = s;
    this.live();
  }

  // ───── タイトル ─────
  private freeTitleTrack(start: number, end: number): number {
    const e = end > start ? end : 1e9;
    for (let t = 0; t < this.titleTrackCount; t++) {
      const busy = this.p.titles.some((x) => x.track === t && x.start < e && start < (x.duration > 0 ? x.start + x.duration : 1e9));
      if (!busy) return t;
    }
    return this.titleTrackCount;
  }

  addTitle(at: number, track?: number): TitleItem {
    const item = newTitle({ start: Math.round(at * 10) / 10 });
    if (this.p.titles.length) { item.anchor = "top"; item.size = 0.05; }
    item.track = track !== undefined ? clamp(track, 0, Math.max(0, this.titleTrackCount - 1)) : this.freeTitleTrack(item.start, item.start + item.duration);
    this.p.titles.push(item);
    this.selTitles = new Set([item.id]);
    this.live();
    return item;
  }

  updateTitle(id: string, change: (t: TitleItem) => void) {
    const t = this.p.titles.find((x) => x.id === id);
    if (t) { change(t); this.live(); }
  }

  removeTitles(ids: Iterable<string>) {
    const set = new Set(ids);
    this.p.titles = this.p.titles.filter((t) => !set.has(t.id));
    this.selTitles = new Set([...this.selTitles].filter((i) => !set.has(i)));
    this.live();
  }

  duplicateTitle(id: string) {
    const src = this.p.titles.find((t) => t.id === id);
    if (!src) return;
    const copy: TitleItem = { ...src, id: uuid(), start: src.duration > 0 ? src.start + src.duration : src.start + 1 };
    this.p.titles.push(copy);
    this.selTitles = new Set([copy.id]);
    this.live();
  }

  // ───── V2（重ねる写真）─────
  get overlayPaths() { return this.p.overlayLibrary; }

  async addOverlayPhotos(paths: string[]): Promise<string[]> {
    const found = await native.listImages(paths, true);
    const added: string[] = [];
    for (const f of found.sort(naturalCompare)) if (!this.p.overlayLibrary.includes(f)) { this.p.overlayLibrary.push(f); added.push(f); }
    this.emit();
    return added;
  }

  async openOverlayPanel() {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const sel = await open({ multiple: true, title: "V2（重ねる写真）のライブラリに入れる写真を選んでください", filters: [{ name: "写真", extensions: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "tif", "tiff"] }] });
    if (!sel) return;
    await this.addOverlayPhotos(Array.isArray(sel) ? sel : [sel]);
  }

  removeOverlayLibrary(paths: Iterable<string>) {
    const set = new Set(paths);
    this.p.overlayLibrary = this.p.overlayLibrary.filter((p) => !set.has(p));
    const gone = new Set(this.p.overlayClips.filter((c) => set.has(c.path)).map((c) => c.id));
    this.p.overlayClips = this.p.overlayClips.filter((c) => !set.has(c.path));
    for (const p of set) this.overlaySel.delete(p);
    for (const g of gone) this.selOverlays.delete(g);
    this.live();
  }

  private freeOverlayTrack(start: number, end: number): number {
    for (let t = 0; t < this.overlayTrackCount; t++) {
      if (!this.p.overlayClips.some((c) => c.track === t && c.start < end && start < c.start + c.duration)) return t;
    }
    return this.overlayTrackCount;
  }

  /** ライブラリの写真を V2 に置く（複数なら続けて並べる） */
  placeOverlays(paths: string[], at: number, track?: number) {
    let t = Math.max(0, at);
    const ids = new Set<string>();
    for (const path of paths) {
      if (!this.p.overlayLibrary.includes(path)) continue;
      const c = newOverlay(path, t, this.p.dwell);
      c.track = track ?? this.freeOverlayTrack(c.start, c.start + c.duration);
      this.p.overlayClips.push(c);
      ids.add(c.id);
      t += c.duration;
    }
    if (ids.size) this.selOverlays = ids;
    this.live();
  }

  async importAndPlaceOverlays(paths: string[], at: number) {
    const found = (await native.listImages(paths, true)).sort(naturalCompare);
    for (const f of found) if (!this.p.overlayLibrary.includes(f)) this.p.overlayLibrary.push(f);
    this.placeOverlays(found, at);
  }

  updateOverlay(id: string, change: (c: OverlayClip) => void) {
    const c = this.p.overlayClips.find((x) => x.id === id);
    if (!c) return;
    change(c);
    c.start = Math.max(0, c.start);
    c.duration = Math.max(0.3, c.duration);
    c.opacity = clamp(c.opacity, 0, 1);
    c.scale = clamp(c.scale, 0.05, 4);
    this.live();
  }

  removeSelectedOverlays() {
    const ids = this.selOverlays;
    this.p.overlayClips = this.p.overlayClips.filter((c) => !ids.has(c.id));
    this.selOverlays = new Set();
    this.live();
  }

  duplicateSelectedOverlays() {
    const added = new Set<string>();
    for (const c of this.p.overlayClips.filter((x) => this.selOverlays.has(x.id)).sort((a, b) => a.start - b.start)) {
      const copy: OverlayClip = { ...c, id: uuid(), start: c.start + c.duration };
      copy.track = this.freeOverlayTrack(copy.start, copy.start + copy.duration);
      this.p.overlayClips.push(copy);
      added.add(copy.id);
    }
    if (added.size) this.selOverlays = added;
    this.live();
  }

  selectOverlay(id: string, mod: { meta: boolean; shift: boolean }) {
    const order = [...this.p.overlayClips].sort((a, b) => a.start - b.start).map((c) => c.id);
    if (mod.meta) {
      if (this.selOverlays.has(id)) this.selOverlays.delete(id); else this.selOverlays.add(id);
      this.overlayAnchor = id;
    } else if (mod.shift && this.overlayAnchor) {
      const a = order.indexOf(this.overlayAnchor), b = order.indexOf(id);
      if (a >= 0 && b >= 0) for (let i = Math.min(a, b); i <= Math.max(a, b); i++) this.selOverlays.add(order[i]);
    } else { this.selOverlays = new Set([id]); this.overlayAnchor = id; }
    this.emit();
  }

  /** 選んだ V2 クリップをまとめて動かす */
  moveOverlays(origins: Map<string, { start: number; track: number }>, delta: number, deltaTrack: number, maxTrack: number) {
    for (const c of this.p.overlayClips) {
      const o = origins.get(c.id);
      if (!o) continue;
      c.start = Math.max(0, o.start + delta);
      c.track = clamp(o.track + deltaTrack, 0, Math.max(0, maxTrack));
    }
    this.live();
  }

  packSelectedOverlays() {
    const sel = this.p.overlayClips.filter((c) => this.selOverlays.has(c.id)).sort((a, b) => a.start - b.start);
    if (sel.length < 2) return;
    let t = sel[0].start + sel[0].duration;
    for (const c of sel.slice(1)) { c.start = t; t = c.start + c.duration; }
    this.live();
  }

  /** 時間の重なる項目を、別のトラックへ振り分ける（古い書類や、重ねて置いたとき） */
  resolveTrackOverlaps() {
    const run = <T extends { track: number }>(items: T[], span: (x: T) => [number, number]) => {
      const placed: { track: number; s: number; e: number }[] = [];
      for (const it of [...items].sort((a, b) => span(a)[0] - span(b)[0])) {
        const [s, e] = span(it);
        let t = Math.max(0, it.track);
        while (placed.some((q) => q.track === t && q.s < e && s < q.e)) t++;
        it.track = t;
        placed.push({ track: t, s, e });
      }
    };
    run(this.p.titles, (x) => [x.start, x.duration > 0 ? x.start + x.duration : 1e9]);
    run(this.p.overlayClips, (x) => [x.start, x.start + x.duration]);
  }

  // ───── 単色画像 ─────
  async addColorCard(color: string, dwell: number) {
    const dir = joinPath(await native.appDataDir(), "ColorCards");
    await native.ensureDir(dir);
    const path = joinPath(dir, `単色-${color.replace("#", "").toUpperCase()}-${uuid().slice(0, 6)}.png`);
    const cv = document.createElement("canvas");
    cv.width = 1920; cv.height = 1080;
    const c = cv.getContext("2d")!;
    c.fillStyle = color; c.fillRect(0, 0, 1920, 1080);
    const blob: Blob = await new Promise((res) => cv.toBlob((b) => res(b!), "image/png"));
    await native.writeBytes(path, new Uint8Array(await blob.arrayBuffer()));
    // 入れる位置（再生ヘッドの写真の後ろ。写真の頭にあるなら手前）
    const urls = this.playPaths();
    let at = this.photos.length;
    if (urls.length) {
      const tm = this.timing();
      const k = tm.index(this.playhead);
      const base = this.photos.indexOf(urls[k]);
      if (base >= 0) at = this.playhead <= tm.starts[k] + 0.05 ? base : base + 1;
    }
    this.selection.clear(); this.selAnchor = null;
    this.photos.splice(clamp(at, 0, this.photos.length), 0, path);
    this.p.sources.push(path);
    localStorage.setItem(LS.lastSources, JSON.stringify(this.p.sources));
    this.p.order = "manual";
    this.p.manualOrder = [...this.photos];
    if (Math.abs(dwell - this.p.dwell) > 0.001) this.p.overrides[path] = { dwell };
    this.live();
  }

  // ───── 書類 ─────
  newDocument() {
    this.documentPath = null;
    localStorage.removeItem(LS.lastDoc);
    this.p = defaultProject();
    this.removed.clear();
    this.photos = [];
    this.selection.clear(); this.timelineSel.clear(); this.selOverlays.clear(); this.selTitles.clear(); this.overlaySel.clear();
    this.playhead = 0;
    this.message = "";
    this.live();
  }

  async openDocument(docDir: string) {
    let dir = docDir;
    if (basename(dir) === "project.json") dir = dirname(dir);
    try {
      const raw = await readProject(dir);
      const f = resolveProject(raw, dir);
      this.documentPath = dir;
      localStorage.setItem(LS.lastDoc, dir);
      const keepOrder = f.order;
      this.p = { ...f };
      this.p.order = keepOrder;
      this.removed = new Set(f.excluded);
      const packaged = joinPath(dir, "photos");
      if (f.includesPhotos && await native.pathExists(packaged)) this.p.sources = [packaged];
      else {
        const ok: string[] = [];
        for (const s of f.sources) if (await native.pathExists(s)) ok.push(s);
        this.p.sources = ok;
        this.message = f.sources.length && !ok.length ? "写真のフォルダが見つかりません" : "";
      }
      this.pendingSelection = f.selection;
      this.resolveTrackOverlaps();
      if (f.view) {
        this.tab = f.view.tab; this.timelineZoom = clamp(f.view.timelineZoom, 1, 24);
        this.previewHeight = clamp(f.view.previewHeight, 120, 900); this.playhead = Math.max(0, f.view.playhead);
      }
      this.selClip = null; this.selOverlays.clear(); this.selTitles.clear(); this.overlaySel.clear();
      await this.rescan();
      void this.loadAudio();
    } catch (e) {
      this.message = `書類を開けませんでした: ${e}`;
      this.emit();
    }
  }

  async loadAudio() {
    for (const c of this.p.clips) await this.audio.load(c.path);
    this.emit();
  }

  /** 今の状態を書類の形に（パスは絶対パス） */
  toFile(): ProjectFile {
    const f: ProjectFile = JSON.parse(JSON.stringify(this.p));
    f.selection = this.photos.filter((p) => this.selection.has(p));
    f.excluded = [...this.removed];
    f.titleTracks = this.titleTrackCount;
    f.overlayTracks = this.overlayTrackCount;
    f.audioTracks = this.trackCount;
    f.manualOrder = this.p.order === "manual" ? [...this.photos] : [];
    f.view = { tab: this.tab, timelineZoom: this.timelineZoom, previewHeight: this.previewHeight, playhead: this.playhead };
    return normalizeProject(f);
  }

  get documentHasPhotos() {
    if (!this.documentPath) return false;
    const photosDir = joinPath(this.documentPath, "photos").replace(/\\/g, "/");
    return this.p.sources.some((s) => s.replace(/\\/g, "/") === photosDir);
  }

  saving: string | null = null;

  async saveDocument() {
    if (this.documentPath) await this.write(this.documentPath, this.documentHasPhotos);
    else await this.saveDocumentAs();
  }

  async saveDocumentAs() {
    const { save } = await import("@tauri-apps/plugin-dialog");
    const base = this.documentPath ? basename(this.documentPath) : `${this.p.sources[0] ? stem(this.p.sources[0]) : "スライドショー"}.cpsd`;
    const dest = await save({ title: "スライドショーの書類（.cpsd）として保存します", defaultPath: base, filters: [{ name: "CacaoPhotoSlide 書類", extensions: ["cpsd"] }] });
    if (!dest) return;
    const includePhotos = window.confirm(`写真も書類の中にコピーしますか？（${this.photos.length} 枚。外した写真は入れません）\n\n［OK］コピーする（別の PC に持っていっても開けます）\n［キャンセル］コピーしない（元のフォルダを参照します）`);
    await this.write(dest.endsWith(".cpsd") ? dest : `${dest}.cpsd`, includePhotos);
  }

  private async write(dir: string, includePhotos: boolean) {
    if (this.saving) return;
    this.saving = includePhotos ? "保存中…" : null;
    this.emit();
    try {
      const file = this.toFile();
      const saved = await writeProject(dir, file, {
        includePhotos, photos: [...this.photos],
        progress: (i, n) => { if (i % 10 === 0) { this.saving = `保存中… 写真 ${i} / ${n}`; this.emit(); } },
      });
      this.documentPath = dir;
      localStorage.setItem(LS.lastDoc, dir);
      // 保存後は、書類の中の相対パスで持つ（音声・V2 の写真）
      const r = resolveProject(saved, dir);
      this.p.clips = this.p.clips.map((c) => { const n = r.clips.find((x) => x.id === c.id); return n ? { ...c, path: n.path } : c; });
      if (includePhotos) {
        this.p.overlayLibrary = r.overlayLibrary;
        this.p.overlayClips = r.overlayClips;
        const packaged = joinPath(dir, "photos");
        if (!this.documentHasPhotos) {
          this.pendingSelection = r.selection;
          this.removed.clear();
          this.p.overrides = r.overrides;
          this.p.manualOrder = r.manualOrder;
          this.p.sources = [packaged];
          await this.rescan();
        }
      }
    } catch (e) {
      window.alert(`保存できませんでした\n${e}`);
    } finally {
      this.saving = null;
      this.emit();
    }
  }

  async openDocumentPanel() {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const sel = await open({ directory: true, multiple: false, title: "書類（.cpsd のフォルダ）を選んでください" });
    if (sel && typeof sel === "string") await this.openDocument(sel);
  }

  persistView() { localStorage.setItem(LS.previewHeight, String(this.previewHeight)); }
}

/** 種で決める、同じ並びになるシャッフル */
export function shuffled<T>(list: T[], seed: number): T[] {
  const r = mulberry32(seed);
  const a = [...list];
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(r() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

export const store = new Store();
// 画面から使う型の再エクスポート
export type { FitMode, Transition };
export { isAbsolute, isImagePath };
