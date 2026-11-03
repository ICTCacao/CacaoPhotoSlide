// 「タイムライン」のタブ: プレビュー、再生の操作、トラックを積んだタイムライン（T・V2 以上・V1・A）。
// DaVinci Resolve に学んだ作り。Mac 版の AudioTimelineView.swift の移植。
import { basename } from "../native.ts";
import { MusicClip } from "../model.ts";
import { clamp, clipLength, overlayOrder } from "../engine.ts";
import { button, contextMenu, fmt, h, mod, round1, showMenu, type MenuItem } from "../dom.ts";
import { registerDropTarget, type DragPayload } from "../drag.ts";
import { player } from "../player.ts";
import { openSheet } from "../sheets.ts";
import { store, type TrackKind, type TrackRef } from "../store.ts";
import { isAudioPath, isImagePath } from "../native.ts";

/** 音声のトラックごとの色（Mac 版と同じ並び: orange, teal, purple, green, pink, indigo, mint, brown） */
const AUDIO_COLORS = ["#ff9f0a", "#30b0c7", "#bf5af2", "#32d74b", "#ff375f", "#5e5ce6", "#63e6e2", "#a2845e"];
const audioColor = (track: number) => AUDIO_COLORS[Math.max(0, track) % AUDIO_COLORS.length];
const rgba = (hex: string, a: number) => { const n = parseInt(hex.slice(1), 16); return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`; };

// ───── 寸法（Mac 版と同じ）─────
const LABEL_W = 34, RULER = 18, BAND = 40, TITLE_LANE = 18, TITLE_STEP = 22, V2_LANE = 36, V2_STEP = 40, CLIP_H = 26, LANE_GAP = 6;
const LANE_STEP = CLIP_H + LANE_GAP;

interface Geo {
  w: number; total: number; tCount: number; vCount: number; aCount: number;
  tTop: number; vTop: number; bandTop: number; clipTop: number; height: number;
}

function geometry(w: number, total: number): Geo {
  const tCount = store.titleTrackCount, vCount = store.overlayTrackCount, aCount = store.trackCount;
  const tTop = RULER + 4;
  const vTop = tTop + tCount * TITLE_STEP + 4;
  const bandTop = vTop + vCount * V2_STEP + 4;
  const clipTop = bandTop + BAND + 6;
  return { w, total: Math.max(total, 0.001), tCount, vCount, aCount, tTop, vTop, bandTop, clipTop, height: clipTop + aCount * LANE_STEP + 4 };
}
const titleY = (g: Geo, track: number) => g.tTop + (g.tCount - 1 - track) * TITLE_STEP;
const overlayY = (g: Geo, track: number) => g.vTop + (g.vCount - 1 - track) * V2_STEP;
const laneY = (g: Geo, track: number) => g.clipTop + track * LANE_STEP;
const xOf = (g: Geo, t: number) => (t / g.total) * g.w;
const tOf = (g: Geo, x: number) => (clamp(x, 0, g.w) / g.w) * g.total;

let viewportW = 800;
let playheadEl: HTMLElement | null = null;
let timeEl: HTMLElement | null = null;
let lastGeo: Geo | null = null;
let contentEl: HTMLElement | null = null;
let scrollEl: HTMLElement | null = null;
let lastScrollLeft = 0, lastZoom = 1, lastEditorClip: string | null = null;     // 描き直しても、スクロールの位置と、見ていた所を保つ

export function renderTimeline(pane: HTMLElement) {
  const prevTop = (pane.querySelector(".tl-pane") as HTMLElement | null)?.scrollTop ?? 0;
  pane.replaceChildren();
  const root = h("div", { class: "tl-pane" });
  pane.append(root);

  // ───── プレビュー ─────
  const ph = clamp(store.previewHeight, 120, 900);
  const canvas = h("canvas", { width: 960, height: 540 }) as HTMLCanvasElement;
  const box = h("div", { class: "preview-box" }, canvas);
  if (!player.playing && store.photos.length && !store.scanning) {
    box.append(h("button", { class: "bigplay", title: "再生ヘッドの位置から、ここで流してみる（音声も鳴ります）", onClick: () => { player.play(store.playhead); store.emit(); } }, "▶"));
  } else if (!store.photos.length) box.append(h("div", { style: { position: "absolute", inset: "0", display: "flex", alignItems: "center", justifyContent: "center", color: "#aaa" } }, "「写真」のタブで写真を開いてください"));
  root.append(h("div", { class: "preview-wrap", style: { height: `${ph}px` } }, box));
  player.attach(canvas);
  player.maxPixel = 1600;
  player.loop = false;
  player.onTick = (t) => { updatePlayhead(t); };
  player.onEnd = () => store.emit();
  if (player.playing) player.draw(); else void player.drawStill(store.playhead);

  // 境目（ドラッグでプレビューの大きさを変える）
  const splitter = h("div", { class: "splitter", title: "上下にドラッグして、プレビューの大きさを変える" });
  splitter.addEventListener("pointerdown", (e) => {
    const sy = e.clientY, base = store.previewHeight;
    const mv = (ev: PointerEvent) => { store.previewHeight = clamp(base + ev.clientY - sy, 120, 900); (root.querySelector(".preview-wrap") as HTMLElement).style.height = `${store.previewHeight}px`; };
    const up = () => { window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up); store.persistView(); };
    window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
  });
  root.append(splitter);

  // ───── 再生の操作 ─────
  timeEl = h("span", { class: "time" }, fmt(player.playing ? player.time : store.playhead));
  root.append(h("div", { class: "transport" },
    button("⏮", () => { if (player.playing) player.seek(prevStart()); else store.stepPlayhead(-1); }, { icon: true, title: "前の写真", disabled: !store.photos.length }),
    player.playing
      ? button("⏸ 一時停止", () => { player.pause(); store.emit(); }, { title: "Space" })
      : button("▶ 再生", () => { player.play(store.playhead); store.emit(); }, { disabled: !store.photos.length || store.scanning, title: "Space" }),
    button("⏹", () => { player.pause(); store.emit(); }, { icon: true, disabled: !player.playing, title: "停止（今の位置に再生ヘッドが残ります）" }),
    button("⏭", () => { if (player.playing) player.seek(nextStart()); else store.stepPlayhead(1); }, { icon: true, title: "次の写真", disabled: !store.photos.length }),
    timeEl, h("span", { class: "dim" }, `/ ${fmt(store.totalDuration)}`),
    h("span", { style: { flex: "1" } }),
    h("span", { class: "dim" }, `${store.playCount} 枚`)));

  // ───── 見出し（拡大縮小・追加）─────
  const zoomSlider = h("input", { type: "range", min: 0, max: 4.5, step: 0.05, value: String(Math.log2(store.timelineZoom)), style: { width: "110px" } }) as HTMLInputElement;
  zoomSlider.addEventListener("input", () => { store.timelineZoom = Math.pow(2, parseFloat(zoomSlider.value)); store.emit(); });
  root.append(h("div", { class: "tl-head" },
    h("b", {}, "〰 タイムライン"),
    h("span", { class: "dim" }, `所要時間 ${fmt(store.totalDuration)}　（${store.playCount} 枚 × ${store.p.dwell} 秒${store.overrideCountInPlay() ? `（うち ${store.overrideCountInPlay()} 枚は個別設定）` : ""}）`),
    h("span", { class: "grow" }),
    button("−", () => { store.timelineZoom = Math.max(1, store.timelineZoom / 1.5); store.emit(); }, { small: true, title: "縮小" }),
    zoomSlider,
    button("＋", () => { store.timelineZoom = Math.min(24, store.timelineZoom * 1.5); store.emit(); }, { small: true, title: "拡大" }),
    button("全体", () => { store.timelineZoom = 1; store.emit(); }, { small: true, disabled: store.timelineZoom <= 1.01 }),
    button("＋ 追加 ▾", () => {}, { small: true })));
  const addBtn = root.querySelector(".tl-head .btn:last-child") as HTMLElement;
  addBtn.onclick = (e) => {
    const r = addBtn.getBoundingClientRect();
    showMenu(r.left, r.bottom + 4, [
      { label: "タイトル（再生ヘッドの位置）", onClick: () => addTitleHere(store.playhead) },
      { label: "単色画像…", onClick: () => openSheet("color", {}) },
      { separator: true },
      { label: "音声…", onClick: () => void store.chooseMusic() },
    ]);
    e.stopPropagation();
  };

  // ───── タイムライン本体 ─────
  const main = h("div", { class: "tl-main" });
  root.append(main);
  const labels = h("div", { class: "tl-labels" });
  const scroll = h("div", { class: "tl-scroll" });
  main.append(labels, scroll);
  scrollEl = scroll;
  viewportW = Math.max(300, root.clientWidth - LABEL_W - 4);
  const w = viewportW * store.timelineZoom;
  const tm = store.timing();
  const g = geometry(w, tm.total);
  lastGeo = g;
  labels.style.height = `${g.height}px`;
  scroll.style.height = `${g.height + (store.timelineZoom > 1.01 ? 12 : 0)}px`;
  const content = h("div", { class: "tl-content", style: { width: `${w}px`, height: `${g.height}px` } });
  contentEl = content;
  scroll.append(content);
  buildLabels(labels, g);
  buildContent(content, g, tm);
  playheadEl = h("div", { class: "playhead" });
  content.append(playheadEl);
  updatePlayhead(player.playing ? player.time : store.playhead);

  // ピンチ・Ctrl + ホイールで拡大縮小
  scroll.addEventListener("wheel", (e) => {
    if (!(e.ctrlKey || e.metaKey)) return;
    e.preventDefault();
    store.timelineZoom = clamp(store.timelineZoom * Math.exp(-e.deltaY * 0.01), 1, 24);
    store.emit();
  }, { passive: false });

  // 描き直しても、横のスクロールの位置を保つ。拡大の倍率を変えたときだけ、再生ヘッドが見える位置へ
  scroll.addEventListener("scroll", () => { lastScrollLeft = scroll.scrollLeft; });
  scroll.scrollLeft = lastScrollLeft;
  if (store.timelineZoom > 1.01 && Math.abs(store.timelineZoom - lastZoom) > 0.001) {
    const x = xOf(g, player.playing ? player.time : store.playhead);
    if (x < scroll.scrollLeft || x > scroll.scrollLeft + scroll.clientWidth) scroll.scrollLeft = Math.max(0, x - scroll.clientWidth / 2);
    lastScrollLeft = scroll.scrollLeft;
  }
  if (store.timelineZoom <= 1.01) { scroll.scrollLeft = 0; lastScrollLeft = 0; }
  lastZoom = store.timelineZoom;

  root.append(h("div", { class: "dim", style: { fontSize: "11px" } }, "クリップをクリックすると、置く位置・曲の範囲・音量・フェードを直せます"));
  const editor = buildClipEditor(root);
  // 縦のスクロールの位置を保つ。音声クリップを選んだときは、編集の欄が見えるところまで送る
  root.scrollTop = prevTop;
  if (editor && store.selClip !== lastEditorClip) editor.scrollIntoView({ block: "nearest" });
  lastEditorClip = editor ? store.selClip : null;
}

function prevStart() { const tm = store.timing(); const i = tm.index(player.time); return tm.starts[player.time > tm.starts[i] + 0.5 ? i : Math.max(0, i - 1)]; }
function nextStart() { const tm = store.timing(); return tm.starts[Math.min(tm.count - 1, tm.index(player.time) + 1)]; }

function updatePlayhead(t: number) {
  if (!playheadEl || !lastGeo) return;
  playheadEl.style.left = `${clamp(xOf(lastGeo, Math.min(t, lastGeo.total)), 0, lastGeo.w - 2) - 1}px`;
  if (timeEl) timeEl.textContent = fmt(t);
  // 流している間、拡大していれば追いかける
  if (player.playing && store.timelineZoom > 1.01 && scrollEl) {
    const x = xOf(lastGeo, t);
    if (x > scrollEl.scrollLeft + scrollEl.clientWidth - 40 || x < scrollEl.scrollLeft) scrollEl.scrollLeft = Math.max(0, x - 80);
  }
}

// ───── トラック名（左の列）─────
function trackRef(kind: TrackKind | "main", index: number): TrackRef { return { kind, index }; }
const trackLabel = (kind: TrackKind | "main", index: number) => (kind === "main" ? "V1" : kind === "title" ? `T${index + 1}` : kind === "overlay" ? `V${index + 2}` : `A${index + 1}`);

function buildLabels(labels: HTMLElement, g: Geo) {
  const add = (kind: TrackKind | "main", index: number, y: number, color: string) => {
    const off = kind === "audio" ? store.trackSetting(trackRef(kind, index)).muted : store.trackSetting(trackRef(kind, index)).hidden;
    const el = h("div", { class: `tl-label${off ? " off" : ""}`, style: { top: `${y}px`, color }, title: "ダブルクリックで、このトラックの設定（不透明度・音量など）" }, trackLabel(kind, index));
    el.addEventListener("dblclick", () => openSheet("track", { ref: trackRef(kind, index) }));
    contextMenu(el, () => trackMenu(kind, index));
    labels.append(el);
  };
  for (let j = 0; j < g.tCount; j++) add("title", j, titleY(g, j) + 3, "var(--cyan)");
  for (let j = 0; j < g.vCount; j++) add("overlay", j, overlayY(g, j) + 12, "var(--indigo)");
  add("main", 0, g.bandTop + BAND / 2 - 7, "var(--accent)");
  for (let j = 0; j < g.aCount; j++) add("audio", j, laneY(g, j) + 6, audioColor(j));
}

/** トラックの右クリックメニュー: 設定・非表示（ミュート）・削除（空のものだけ）・追加 */
export function trackMenu(kind: TrackKind | "main", index: number): MenuItem[] {
  const ref = trackRef(kind, index);
  const st = store.trackSetting(ref);
  const items: MenuItem[] = [
    { label: `${trackLabel(kind, index)} トラックの設定…`, onClick: () => openSheet("track", { ref }) },
    kind === "audio"
      ? { label: st.muted ? "ミュートを解除" : "ミュート", onClick: () => store.updateTrackSetting(ref, (s) => { s.muted = !s.muted; }) }
      : { label: st.hidden ? "表示する" : "非表示にする", onClick: () => store.updateTrackSetting(ref, (s) => { s.hidden = !s.hidden; }) },
    { separator: true },
  ];
  if (kind === "main") {
    items.push({ label: "V1 トラックを削除", disabled: true });
    items.push({ label: `V${store.overlayTrackCount + 2} トラックを追加`, onClick: () => store.addTrack("overlay") });
    items.push({ label: `T${store.titleTrackCount + 1} トラックを追加`, onClick: () => store.addTrack("title") });
    items.push({ label: `A${store.trackCount + 1} トラックを追加`, onClick: () => store.addTrack("audio") });
    return items;
  }
  items.push({ label: `${trackLabel(kind, index)} トラックを削除`, danger: true, disabled: !store.isTrackEmpty(kind, index), onClick: () => store.removeTrack(kind, index) });
  const next = kind === "title" ? store.titleTrackCount : kind === "overlay" ? store.overlayTrackCount : store.trackCount;
  items.push({ label: `${trackLabel(kind, next)} トラックを追加`, onClick: () => store.addTrack(kind) });
  return items;
}

function addTitleHere(t: number, track?: number) {
  const item = store.addTitle(t, track);
  openSheet("titles", { select: item.id });
}

// ───── 中身 ─────
function buildContent(c: HTMLElement, g: Geo, tm: ReturnType<typeof store.timing>) {
  const paths = store.playPaths();
  const bounds = tm.bounds();

  // 行の下地
  for (let j = 0; j < g.tCount; j++) c.append(h("div", { class: "tl-row", style: { top: `${titleY(g, j)}px`, height: `${TITLE_LANE}px` } }));
  for (let j = 0; j < g.vCount; j++) c.append(h("div", { class: "tl-row v", style: { top: `${overlayY(g, j)}px`, height: `${V2_LANE}px` } }));
  for (let j = 0; j < g.aCount; j++) c.append(h("div", { class: `tl-row a${store.p.clips.some((x) => x.track === j) ? "" : " empty"}`, style: { top: `${laneY(g, j)}px`, height: `${CLIP_H}px` } }));

  // ルーラー（ドラッグで再生ヘッドを動かす）
  const ruler = h("div", { class: "tl-ruler", title: "クリック・ドラッグで再生ヘッドを動かす（再生は ▶ ボタンか Space）" });
  const step = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1200, 1800, 3600].find((s) => xOf(g, s) >= 56) ?? 3600;
  for (let t = 0; t <= g.total + 0.001; t += step) ruler.append(h("div", { class: "tick", style: { left: `${xOf(g, t)}px` } }, fmt(t)));
  c.append(ruler);
  ruler.addEventListener("pointerdown", (e) => {
    const rect = c.getBoundingClientRect();
    const go = (ev: PointerEvent) => scrubTo(tOf(g, ev.clientX - rect.left));
    go(e);
    const mv = (ev: PointerEvent) => go(ev);
    const up = () => { window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
  });

  // V1（写真の帯）
  buildBand(c, g, tm, paths, bounds);
  // V2
  buildOverlays(c, g, bounds);
  // タイトル
  buildTitles(c, g);
  // 音声
  buildAudio(c, g);
  // 何もないところの操作（クリックで再生ヘッド、ドラッグで範囲選択、右クリック）
  attachBackground(c, g, tm, paths, bounds);
  // 空の案内
  if (!store.p.clips.length && g.aCount > 0) c.append(h("div", { class: "tl-hint", style: { top: `${laneY(g, 0) + 6}px` } }, "ここに音声ファイルをドロップ（置いた位置から鳴ります）"));
  if (!store.p.titles.length && g.tCount > 0) c.append(h("div", { class: "tl-hint", style: { top: `${titleY(g, 0) + 2}px` } }, "T1: 右クリックで、タイトルを追加"));
  if (g.vCount > 0 && !store.p.overlayClips.length) c.append(h("div", { class: "tl-hint", style: { top: `${overlayY(g, 0) + 10}px` } }, "V2: 「写真」タブの V2 ライブラリから、ここへドラッグ（写真ファイルを直接落としても置けます）"));
}

function scrubTo(t: number) {
  if (player.playing) { player.seek(t); store.playhead = t; updatePlayhead(t); return; }
  store.scrub(t);
}

// ───── V1（写真）─────
function buildBand(c: HTMLElement, g: Geo, tm: ReturnType<typeof store.timing>, paths: string[], bounds: number[]) {
  const cv = h("canvas", { class: "tl-v1" }) as HTMLCanvasElement;
  const w = Math.round(g.w);
  cv.width = Math.min(w, 16000); cv.height = BAND;
  cv.style.cssText = `top:${g.bandTop}px;width:${w}px;height:${BAND}px;`;
  c.append(cv);
  const ctx = cv.getContext("2d")!;
  const scale = cv.width / g.w;
  const tw = BAND * 1.4;
  // 区切りの下地（濃淡）
  for (let k = 0; k < paths.length && paths.length <= 600; k++) {
    ctx.fillStyle = k % 2 === 0 ? "rgba(10,132,255,.35)" : "rgba(10,132,255,.2)";
    ctx.fillRect(xOf(g, bounds[k]) * scale, 0, Math.max(0.5, xOf(g, bounds[k + 1] - bounds[k]) * scale), BAND);
  }
  let lastEnd = -1;
  for (let k = 0; k < paths.length; k++) {
    const x0 = xOf(g, bounds[k]), x1 = xOf(g, bounds[k + 1]);
    let width = 0;
    if (x1 - x0 >= tw) width = x1 - x0; else if (x0 >= lastEnd - 0.5 && g.w - x0 >= 8) width = Math.min(tw, g.w - x0); else continue;
    lastEnd = x0 + (x1 - x0 >= tw ? width : tw);
    const th = store.thumbs.get(paths[k]);
    store.thumbs.request(paths[k]);
    const dx = x0 * scale, dw = width * scale;
    ctx.fillStyle = "rgba(255,255,255,.12)"; ctx.fillRect(dx, 0, dw, BAND);
    if (th) {
      const r = Math.max(dw / th.width, BAND / th.height);
      ctx.save(); ctx.beginPath(); ctx.rect(dx, 0, dw, BAND); ctx.clip();
      ctx.drawImage(th, dx + (dw - th.width * r) / 2, (BAND - th.height * r) / 2, th.width * r, th.height * r);
      ctx.restore();
    }
    ctx.fillStyle = "rgba(0,0,0,.55)"; ctx.fillRect(dx, BAND - 13, 8 + String(k + 1).length * 6, 13);
    ctx.fillStyle = "#fff"; ctx.font = "600 9px sans-serif"; ctx.fillText(String(k + 1), dx + 3, BAND - 3);
    ctx.strokeStyle = "rgba(0,0,0,.35)"; ctx.lineWidth = 0.5; ctx.strokeRect(dx, 0.5, dw, BAND - 1);
  }
  // 選んでいる写真
  for (let k = 0; k < paths.length; k++) {
    if (!store.timelineSel.has(paths[k])) continue;
    c.append(h("div", { class: "selmark", style: { left: `${xOf(g, bounds[k])}px`, top: `${g.bandTop}px`, width: `${Math.max(3, xOf(g, bounds[k + 1]) - xOf(g, bounds[k]))}px`, height: `${BAND}px` } }));
  }
  // 各写真の右端のつまみ（表示時間を変える）
  if (paths.length <= 600) {
    for (let k = 0; k < paths.length; k++) {
      const x1 = xOf(g, bounds[k + 1]);
      if (xOf(g, bounds[k + 1] - bounds[k]) < 14) continue;
      const hd = h("div", { class: "handle", style: { left: `${x1 - 8}px`, top: `${g.bandTop}px`, height: `${BAND}px` }, title: `つまんで、この写真の表示時間を変える（${tm.dwells[k]} 秒）` });
      edgeDrag(hd, g, tm.dwells[k], (v) => { const d = Math.max(0.3, round1(v)); setPhotoDwell(paths[k], d); });
      c.append(hd);
    }
  }
}

function setPhotoDwell(path: string, dwell: number) {
  const cur = store.p.overrides[path];
  store.setOverride([path], { ...cur, dwell: Math.abs(dwell - store.p.dwell) < 0.001 ? undefined : dwell });
}

/** 端をつまんで、秒数を変える（動かし始めの 1 秒あたりの画素数で換算する） */
function edgeDrag(el: HTMLElement, g: Geo, base: number, apply: (v: number) => void) {
  el.addEventListener("pointerdown", (e) => {
    e.stopPropagation();
    const sx = e.clientX, pps = g.w / g.total;
    const mv = (ev: PointerEvent) => apply(base + (ev.clientX - sx) / pps);
    const up = () => { window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
  });
}

// ───── V2 ─────
function buildOverlays(c: HTMLElement, g: Geo, bounds: number[]) {
  const clips = overlayOrder(store.p.overlayClips);
  for (const clip of clips) {
    const s = clamp(clip.start, 0, g.total), e = Math.min(clip.start + clip.duration, g.total);
    const bw = Math.max(24, xOf(g, e - s));
    const x = Math.min(xOf(g, s), Math.max(0, g.w - bw));
    const sel = store.selOverlays.has(clip.id);
    const hidden = store.trackSetting(trackRef("overlay", clip.track)).hidden;
    const bar = h("div", { class: `bar ov${sel ? " sel" : ""}${hidden ? " dim" : ""}`, "data-id": clip.id, style: { left: `${x}px`, top: `${overlayY(g, Math.min(clip.track, g.vCount - 1))}px`, width: `${bw}px`, height: `${V2_LANE}px` },
      title: `${basename(clip.path)}　${fmt(clip.start)} 〜 ${fmt(clip.start + clip.duration)}　ドラッグで時刻、右端で長さ、ダブルクリックで設定` });
    // サムネイルを並べる
    const strip = h("div", { class: "strip" });
    const th = store.thumbs.get(clip.path);
    store.thumbs.request(clip.path);
    if (th) {
      const tw = Math.min(90, Math.max(24, (V2_LANE * th.width) / Math.max(1, th.height)));
      for (let i = 0; i < Math.min(60, Math.ceil(bw / tw)); i++) {
        const cv = h("canvas", { width: Math.round(tw), height: V2_LANE, style: { width: `${tw}px`, opacity: String(Math.max(0.35, clip.opacity)) } }) as HTMLCanvasElement;
        const cx = cv.getContext("2d")!;
        const r = Math.max(cv.width / th.width, cv.height / th.height);
        cx.drawImage(th, (cv.width - th.width * r) / 2, (cv.height - th.height * r) / 2, th.width * r, th.height * r);
        strip.append(cv);
      }
    }
    bar.append(strip, h("div", { class: "cap" }, h("span", { style: { overflow: "hidden", textOverflow: "ellipsis" } }, basename(clip.path)), h("span", {}, `${Math.round(clip.opacity * 100)}%`)));
    const hd = h("div", { class: "handle r" });
    edgeDrag(hd, g, clip.duration, (v) => store.updateOverlay(clip.id, (o) => { o.duration = Math.max(0.3, round1(v)); }));
    bar.append(hd);
    bar.addEventListener("pointerdown", (e) => overlayPointerDown(e, bar, clip.id, g, bounds));
    bar.addEventListener("dblclick", () => openSheet("overlay", { id: clip.id }));
    contextMenu(bar, () => overlayMenu(clip.id));
    c.append(bar);
  }
}

function overlayMenu(id: string): MenuItem[] {
  const clip = store.p.overlayClips.find((x) => x.id === id);
  if (!clip) return [];
  if (!store.selOverlays.has(id)) { store.selOverlays = new Set([id]); }
  const n = store.selOverlays.size;
  const ref = trackRef("overlay", clip.track);
  const st = store.trackSetting(ref);
  return [
    { label: `V${clip.track + 2} トラックの設定…`, onClick: () => openSheet("track", { ref }) },
    { label: st.hidden ? "表示する" : "非表示にする", onClick: () => store.updateTrackSetting(ref, (s) => { s.hidden = !s.hidden; }) },
    { separator: true },
    { label: `V${clip.track + 2} トラックを削除`, danger: true, disabled: !store.isTrackEmpty("overlay", clip.track), onClick: () => store.removeTrack("overlay", clip.track) },
    { label: `V${store.overlayTrackCount + 2} トラックを追加`, onClick: () => store.addTrack("overlay") },
    { label: `T${store.titleTrackCount + 1} トラックを追加`, onClick: () => store.addTrack("title") },
    { label: `A${store.trackCount + 1} トラックを追加`, onClick: () => store.addTrack("audio") },
    { separator: true },
    { label: n > 1 ? `選んだ ${n} 枚を外す` : "この写真を外す", onClick: () => store.removeSelectedOverlays() },
    { label: "表示時間・エフェクトを変える…", onClick: () => openSheet("overlay", { id }) },
    { label: "拡大して見る", onClick: () => openSheet("viewerImage", { path: clip.path }) },
    { separator: true },
    { label: n > 1 ? `選んだ ${n} 枚を複製` : "複製", onClick: () => store.duplicateSelectedOverlays() },
    ...(n > 1 ? [{ label: "前のクリップの終わりにつなげて並べる", onClick: () => store.packSelectedOverlays() }] : []),
    { label: "先頭へ移動", onClick: () => store.updateOverlay(id, (o) => { o.start = 0; }) },
    { separator: true },
    { label: "フォルダで表示", onClick: () => void import("../native.ts").then((m) => m.native.reveal(clip.path)) },
    { separator: true },
    { label: "ここに単色画像を追加…", onClick: () => openSheet("color", {}) },
    { label: "ここにタイトルを追加…", onClick: () => addTitleHere(store.playhead) },
  ];
}

/** V2 のクリップを押したとき: クリック（選択・再生ヘッド）と、ドラッグ（選んでいるものをまとめて動かす・吸着）*/
function overlayPointerDown(e: PointerEvent, bar: HTMLElement, id: string, g: Geo, bounds: number[]) {
  if (e.button !== 0 || (e.target as HTMLElement).classList.contains("handle")) return;
  e.stopPropagation();
  const sx = e.clientX, sy = e.clientY, pps = g.w / g.total;
  const rect = bar.getBoundingClientRect();
  const m = mod(e);
  const clip = store.p.overlayClips.find((x) => x.id === id)!;
  let origins: Map<string, { start: number; track: number }> | null = null;
  const mv = (ev: PointerEvent) => {
    if (!origins) {
      if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 3) return;
      if (!store.selOverlays.has(id)) store.selOverlays = new Set([id]);
      origins = new Map(store.p.overlayClips.filter((c) => store.selOverlays.has(c.id)).map((c) => [c.id, { start: c.start, track: c.track }]));
    }
    let delta = (ev.clientX - sx) / pps;
    const o = origins.get(id)!;
    // 吸着（6px 以内）: 0 秒・写真の区切り・選んでいない V2 クリップの始まりと終わり。つかんだクリップの始まりと終わりのどちらでも
    const marks = [...bounds, 0];
    for (const c of store.p.overlayClips) if (!origins.has(c.id)) marks.push(c.start, c.start + c.duration);
    const snap = 6 / pps;
    const startPos = o.start + delta, endPos = startPos + clip.duration;
    let best: { d: number; adj: number } | null = null;
    for (const mk of marks) for (const adj of [mk - startPos, mk - endPos]) if (Math.abs(adj) <= snap && (!best || Math.abs(adj) < best.d)) best = { d: Math.abs(adj), adj };
    delta = best ? delta + best.adj : Math.round(delta * 10) / 10;
    delta = Math.max(delta, -Math.min(...[...origins.values()].map((v) => v.start)));
    const dTrack = -Math.round((ev.clientY - sy) / V2_STEP);
    store.moveOverlays(origins, delta, dTrack, g.vCount - 1);
  };
  const up = (ev: PointerEvent) => {
    window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up);
    if (!origins) {
      store.selectOverlay(id, m);
      scrubTo(clip.start + ((ev.clientX - rect.left) / Math.max(1, rect.width)) * Math.min(clip.duration, g.total - clip.start));
    }
  };
  window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
}

// ───── タイトル ─────
function buildTitles(c: HTMLElement, g: Geo) {
  for (const item of store.p.titles) {
    const s = clamp(item.start, 0, g.total);
    const en = item.duration > 0 ? Math.min(item.start + item.duration, g.total) : g.total;
    const bw = Math.max(24, xOf(g, en - s));
    const x = Math.min(xOf(g, s), Math.max(0, g.w - bw));
    const sel = store.selTitles.has(item.id);
    const hidden = store.trackSetting(trackRef("title", item.track)).hidden;
    const bar = h("div", { class: `bar title${sel ? " sel" : ""}${hidden ? " dim" : ""}`, "data-id": item.id, style: { left: `${x}px`, top: `${titleY(g, Math.min(item.track, g.tCount - 1))}px`, width: `${bw}px`, height: `${TITLE_LANE}px` },
      title: `「${item.text}」　ドラッグで出す時刻、右端で長さ。ダブルクリックで編集` }, `あぁ ${item.text.split("\n")[0]}`);
    if (item.duration > 0) {
      const hd = h("div", { class: "handle r" });
      edgeDrag(hd, g, item.duration, (v) => store.updateTitle(item.id, (t) => { t.duration = Math.max(0.5, round1(v)); }));
      bar.append(hd);
    }
    bar.addEventListener("pointerdown", (e) => {
      if (e.button !== 0 || (e.target as HTMLElement).classList.contains("handle")) return;
      e.stopPropagation();
      const sx = e.clientX, sy = e.clientY, pps = g.w / g.total, base = item.start, track = item.track, rect = bar.getBoundingClientRect();
      let moved = false;
      const mv = (ev: PointerEvent) => {
        if (!moved && Math.hypot(ev.clientX - sx, ev.clientY - sy) < 3) return;
        moved = true;
        store.updateTitle(item.id, (t) => {
          t.start = Math.max(0, Math.round((base + (ev.clientX - sx) / pps) * 10) / 10);
          t.track = clamp(track - Math.round((ev.clientY - sy) / TITLE_STEP), 0, g.tCount - 1);   // 上へドラッグすると、番号の大きい、上のトラック
        });
      };
      const up = (ev: PointerEvent) => {
        window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up);
        if (!moved) { store.selTitles = new Set([item.id]); store.emit(); scrubTo(item.start + ((ev.clientX - rect.left) / Math.max(1, rect.width)) * (en - s)); }
      };
      window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
    });
    bar.addEventListener("dblclick", () => { store.selTitles = new Set([item.id]); openSheet("titles", { select: item.id }); });
    contextMenu(bar, () => [
      { label: "編集…", onClick: () => { store.selTitles = new Set([item.id]); openSheet("titles", { select: item.id }); } },
      { label: "複製", onClick: () => store.duplicateTitle(item.id) },
      { separator: true },
      { label: "削除", danger: true, onClick: () => store.removeTitles([item.id]) },
    ]);
    c.append(bar);
  }
}

// ───── 音声 ─────
function buildAudio(c: HTMLElement, g: Geo) {
  for (const clip of store.p.clips) {
    const len = clipLength(clip);
    const bw = Math.max(24, xOf(g, Math.max(0, Math.min(len, g.total - clip.start))));
    const x = Math.min(xOf(g, clip.start), Math.max(0, g.w - bw));
    const sel = store.selClip === clip.id;
    const muted = store.trackSetting(trackRef("audio", clip.track)).muted;
    const bar = h("div", { class: `bar audio${sel ? " sel" : ""}${muted ? " dim" : ""}`, style: { left: `${x}px`, top: `${laneY(g, clip.track)}px`, width: `${bw}px`, height: `${CLIP_H}px`, background: rgba(audioColor(clip.track), sel ? 0.85 : 0.55), borderColor: audioColor(clip.track) },
      title: `${clip.name}　${fmt(clip.start)} 〜 ${fmt(clip.start + len)}　左右で位置、上下でトラック、両端をつまむと頭・終わりを削れます` });
    const wave = store.audio.peaks(clip.path);
    if (wave) {
      const cv = h("canvas", { class: "wave", width: Math.min(2000, Math.round(bw)), height: CLIP_H }) as HTMLCanvasElement;
      const cx = cv.getContext("2d")!;
      cx.fillStyle = "#fff";
      const a = Math.floor((clip.inPoint / clip.duration) * wave.length), b = Math.ceil(((clip.inPoint + len) / clip.duration) * wave.length);
      for (let i = 0; i < cv.width; i++) {
        const v = wave[clamp(a + Math.floor((i / cv.width) * (b - a)), 0, wave.length - 1)];
        const hh = Math.max(1, v * CLIP_H);
        cx.fillRect(i, (CLIP_H - hh) / 2, 1, hh);
      }
      bar.append(cv);
    }
    bar.append(h("span", { class: "name" }, `♪ ${clip.name}`));
    const hl = h("div", { class: "handle l" }), hr = h("div", { class: "handle r" });
    trimDrag(hl, g, clip, true); trimDrag(hr, g, clip, false);
    bar.append(hl, hr);
    bar.addEventListener("pointerdown", (e) => audioPointerDown(e, bar, clip, g));
    contextMenu(bar, () => [
      { label: "削除", danger: true, onClick: () => store.removeClip(clip.id) },
    ]);
    c.append(bar);
  }
}

function trimDrag(el: HTMLElement, g: Geo, clip: MusicClip, head: boolean) {
  el.addEventListener("pointerdown", (e) => {
    e.stopPropagation();
    store.selClip = clip.id;
    const pps = g.w / g.total;
    let last = e.clientX;
    const mv = (ev: PointerEvent) => {
      const delta = (ev.clientX - last) / pps; last = ev.clientX;
      if (head) store.trimHead(clip.id, delta);
      else store.updateClip(clip.id, (x) => { x.outPoint = Math.min(x.outPoint ?? x.duration, x.duration) + delta; });
    };
    const up = () => { window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up); };
    window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
  });
}

function audioPointerDown(e: PointerEvent, bar: HTMLElement, clip: MusicClip, g: Geo) {
  if (e.button !== 0 || (e.target as HTMLElement).classList.contains("handle")) return;
  e.stopPropagation();
  const sx = e.clientX, sy = e.clientY, pps = g.w / g.total, base = clip.start, track = clip.track, rect = bar.getBoundingClientRect();
  let moved = false;
  const mv = (ev: PointerEvent) => {
    if (!moved && Math.hypot(ev.clientX - sx, ev.clientY - sy) < 3) return;
    if (!moved) store.selClip = clip.id;
    moved = true;
    const lane = clamp(track + Math.round((ev.clientY - sy) / LANE_STEP), 0, Math.max(0, g.aCount - 1));
    store.moveClip(clip.id, base + (ev.clientX - sx) / pps, 6 / pps, lane);
  };
  const up = (ev: PointerEvent) => {
    window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up);
    if (!moved) { store.selClip = clip.id; store.emit(); scrubTo(clip.start + ((ev.clientX - rect.left) / Math.max(1, rect.width)) * clipLength(clip)); }
  };
  window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
}

// ───── 何もないところ ─────
function attachBackground(c: HTMLElement, g: Geo, tm: ReturnType<typeof store.timing>, paths: string[], bounds: number[]) {
  const localY = (e: MouseEvent) => e.clientY - c.getBoundingClientRect().top;
  const localX = (e: MouseEvent) => e.clientX - c.getBoundingClientRect().left;
  const inBand = (y: number) => y >= g.bandTop && y < g.bandTop + BAND;

  // 右クリック: どの段かで出すメニューを変える
  c.addEventListener("contextmenu", (e) => {
    if ((e.target as HTMLElement).closest(".bar")) return;
    e.preventDefault();
    const x = localX(e), y = localY(e);
    const t = tOf(g, x);
    if (inBand(y)) {
      const k = tm.index(t);
      const items: MenuItem[] = [...trackMenu("main", 0), { separator: true }];
      if (paths[k]) {
        const group = store.timelineSel.has(paths[k]) ? store.photos.filter((p) => store.timelineSel.has(p)) : [paths[k]];
        items.push(
          { label: group.length >= 2 ? `選んだ ${group.length} 枚を外す` : "この写真を外す", onClick: () => { store.removePhotos(group); store.timelineSel.clear(); } },
          { label: group.length >= 2 ? `選んだ ${group.length} 枚の表示時間・エフェクトを変える…` : "表示時間・エフェクトを変える…", onClick: () => openSheet("override", { paths: group }) },
          { label: "拡大して見る", onClick: () => openSheet("viewer", { path: paths[k] }) },
          { separator: true },
          { label: "先頭へ移動", onClick: () => store.moveToEdge(group, true) },
          { label: "最後へ移動", onClick: () => store.moveToEdge(group, false) },
          { separator: true },
          { label: "フォルダで表示", onClick: () => void import("../native.ts").then((m) => m.native.reveal(paths[k])) },
          { separator: true },
          { label: "ここに単色画像を追加…", onClick: () => { store.scrub(t); openSheet("color", {}); } },
          { label: "ここにタイトルを追加…", onClick: () => addTitleHere(t) });
      }
      showMenu(e.clientX, e.clientY, items);
      return;
    }
    // T の行
    for (let j = 0; j < g.tCount; j++) {
      if (y >= titleY(g, j) && y < titleY(g, j) + TITLE_LANE) {
        showMenu(e.clientX, e.clientY, [
          { label: "ここにタイトルを追加…", onClick: () => addTitleHere(t, j) },
          { label: "再生ヘッドの位置にタイトルを追加…", onClick: () => addTitleHere(store.playhead, j) },
          { separator: true }, ...trackMenu("title", j)]);
        return;
      }
    }
    for (let j = 0; j < g.vCount; j++) {
      if (y >= overlayY(g, j) && y < overlayY(g, j) + V2_LANE) { showMenu(e.clientX, e.clientY, trackMenu("overlay", j)); return; }
    }
    for (let j = 0; j < g.aCount; j++) {
      if (y >= laneY(g, j) && y < laneY(g, j) + CLIP_H) { showMenu(e.clientX, e.clientY, trackMenu("audio", j)); return; }
    }
  });

  // V1 の帯: クリックでその写真を選んで表示、ドラッグで並べ替え
  c.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    const target = e.target as HTMLElement;
    if (target.closest(".bar") || target.closest(".handle") || target.closest(".tl-ruler")) return;
    const y0 = localY(e);
    if (inBand(y0)) { bandPointer(e, g, tm, paths, bounds, c); return; }
    marquee(e, g, c, paths, bounds);
  });
}

function bandPointer(e: PointerEvent, g: Geo, tm: ReturnType<typeof store.timing>, paths: string[], bounds: number[], c: HTMLElement) {
  const rect = c.getBoundingClientRect();
  const sx = e.clientX, sy = e.clientY, m = mod(e);
  const k0 = tm.index(tOf(g, sx - rect.left));
  let moved = false;
  let line: HTMLElement | null = null, ghost: HTMLElement | null = null;
  let k1 = k0;
  const mv = (ev: PointerEvent) => {
    if (player.playing) { scrubTo(tOf(g, ev.clientX - rect.left)); return; }       // 流している間は並べ替えず、スクラブだけ
    if (!moved && Math.hypot(ev.clientX - sx, ev.clientY - sy) < 4) return;
    moved = true;
    k1 = tm.index(tOf(g, ev.clientX - rect.left));
    if (!ghost) {
      ghost = h("div", { class: "selmark", style: { top: `${g.bandTop}px`, height: `${BAND}px` } });
      line = h("div", { class: "reorder-line", style: { top: `${g.bandTop - 4}px`, height: `${BAND + 8}px` } });
      c.append(ghost, line);
    }
    ghost.style.left = `${xOf(g, bounds[k0])}px`; ghost.style.width = `${Math.max(6, xOf(g, bounds[k0 + 1] - bounds[k0]))}px`;
    line!.style.left = `${Math.max(0, xOf(g, k1 > k0 ? bounds[k1 + 1] : bounds[k1]) - 1.5)}px`;
  };
  const up = (ev: PointerEvent) => {
    window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up);
    ghost?.remove(); line?.remove();
    if (moved && k0 !== k1) { store.moveTimelinePhoto(k0, k1); return; }
    if (!moved) { store.selectTimelinePhoto(tm.index(tOf(g, ev.clientX - rect.left)), m); scrubTo(tOf(g, ev.clientX - rect.left)); }
  };
  window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
  void paths;
}

/** 何もないところから斜めにドラッグ: 触れた V1・V2 の写真とタイトルを選ぶ（Ctrl / ⇧ なら、いまの選択に足す）。クリックだけなら、再生ヘッドを動かす */
function marquee(e: PointerEvent, g: Geo, c: HTMLElement, paths: string[], bounds: number[]) {
  const rect = c.getBoundingClientRect();
  const sx = e.clientX - rect.left, sy = e.clientY - rect.top;
  const add = e.shiftKey || e.metaKey || e.ctrlKey;
  const base = add ? { ov: new Set(store.selOverlays), ti: new Set(store.selTitles), ph: new Set(store.timelineSel) } : { ov: new Set<string>(), ti: new Set<string>(), ph: new Set<string>() };
  let box: HTMLElement | null = null;
  let moved = false;
  const mv = (ev: PointerEvent) => {
    const cx = ev.clientX - rect.left, cy = ev.clientY - rect.top;
    if (!moved && Math.hypot(cx - sx, cy - sy) < 4) return;
    moved = true;
    const r = { x: Math.min(sx, cx), y: Math.min(sy, cy), w: Math.abs(cx - sx), h: Math.abs(cy - sy) };
    if (!box) { box = h("div", { class: "marquee" }); c.append(box); }
    box.style.cssText = `left:${r.x}px;top:${r.y}px;width:${r.w}px;height:${r.h}px`;
    const hit = (x: number, y: number, w: number, hh: number) => r.x <= x + w && r.x + r.w >= x && r.y <= y + hh && r.y + r.h >= y;
    const ov = new Set(base.ov), ti = new Set(base.ti), ph = new Set(base.ph);
    if (r.y + r.h >= g.bandTop && r.y <= g.bandTop + BAND) {
      for (let k = 0; k < paths.length; k++) { const x0 = xOf(g, bounds[k]), x1 = xOf(g, bounds[k + 1]); if (r.x + r.w >= x0 && r.x <= Math.max(x1, x0 + 1)) ph.add(paths[k]); }
    }
    for (const cl of store.p.overlayClips) {
      const s = clamp(cl.start, 0, g.total), en = Math.min(cl.start + cl.duration, g.total), bw = Math.max(24, xOf(g, en - s));
      if (hit(Math.min(xOf(g, s), Math.max(0, g.w - bw)), overlayY(g, Math.min(cl.track, g.vCount - 1)), bw, V2_LANE)) ov.add(cl.id);
    }
    for (const t of store.p.titles) {
      const s = clamp(t.start, 0, g.total), en = t.duration > 0 ? Math.min(t.start + t.duration, g.total) : g.total, bw = Math.max(24, xOf(g, en - s));
      if (hit(Math.min(xOf(g, s), Math.max(0, g.w - bw)), titleY(g, Math.min(t.track, g.tCount - 1)), bw, TITLE_LANE)) ti.add(t.id);
    }
    store.timelineSel = ph; store.selOverlays = ov; store.selTitles = ti;
    store.emitSoon();
  };
  const up = (ev: PointerEvent) => {
    window.removeEventListener("pointermove", mv); window.removeEventListener("pointerup", up);
    box?.remove();
    if (!moved) {
      store.selClip = null; store.selOverlays = new Set(); store.selTitles = new Set(); store.timelineSel = new Set();
      scrubTo(tOf(g, ev.clientX - rect.left));
      store.emit();
    } else store.emit();
  };
  window.addEventListener("pointermove", mv); window.addEventListener("pointerup", up);
}

// ───── 外から運ばれたもの ─────
/** ファイルが落とされたとき。タイムラインの上なら、ここで受ける（V2 の段の写真・音声）。受けたら true */
export async function handleExternalDrop(paths: string[], x: number, y: number): Promise<boolean> {
  if (!contentEl || !lastGeo) return false;
  const r = contentEl.getBoundingClientRect();
  if (x < r.left || x > r.right || y < r.top || y > r.bottom) return false;
  const g = lastGeo;
  const lx = x - r.left, ly = y - r.top;
  const t = tOf(g, lx);
  const audio = paths.filter(isAudioPath);
  const images = paths.filter((p) => isImagePath(p) || !isAudioPath(p));
  if (g.vCount > 0 && ly >= g.vTop && ly < g.vTop + g.vCount * V2_STEP && images.length) { await store.importAndPlaceOverlays(images, t); return true; }
  if (audio.length) {
    const lane = clamp(Math.floor((ly - g.clipTop) / LANE_STEP), 0, Math.max(0, g.aCount - 1));
    for (const a of audio) await store.addClip(a, t, lane);
    return true;
  }
  return false;
}

/** V2 ライブラリからドラッグしてきた写真を、V2 の段に落とす */
registerDropTarget({
  get el() { return contentEl ?? document.body; },
  accept: (p: DragPayload, e: PointerEvent) => {
    if (p.kind !== "v2" || !contentEl || !lastGeo) return false;
    const r = contentEl.getBoundingClientRect();
    const ly = e.clientY - r.top;
    return lastGeo.vCount > 0 && ly >= lastGeo.vTop && ly < lastGeo.vTop + lastGeo.vCount * V2_STEP;
  },
  drop: (p: DragPayload, e: PointerEvent) => {
    if (!contentEl || !lastGeo) return;
    const r = contentEl.getBoundingClientRect();
    const ly = e.clientY - r.top;
    const track = clamp(lastGeo.vCount - 1 - Math.floor((ly - lastGeo.vTop) / V2_STEP), 0, lastGeo.vCount - 1);
    store.placeOverlays(p.paths, tOf(lastGeo, e.clientX - r.left), track);
  },
} as any);

// ───── 選んだ音声クリップの編集 ─────
function buildClipEditor(root: HTMLElement): HTMLElement | null {
  const clip = store.p.clips.find((c) => c.id === store.selClip);
  if (!clip) return null;
  const box = h("div", { style: { display: "flex", flexDirection: "column", gap: "6px", background: "var(--bg2)", borderRadius: "8px", padding: "8px 12px" } });
  const line = (...ch: (Node | string)[]) => h("div", { style: { display: "flex", gap: "10px", alignItems: "center", flexWrap: "wrap" } }, ...ch.map((c) => (typeof c === "string" ? h("span", {}, c) : c)));   // 文字は 1 つずつ別の要素にする（隣り合う文字がくっつかないように）
  const num = (v: number, f: (n: number) => void, step = 0.1, w = 64) => {
    const i = h("input", { type: "number", class: "num", value: String(round1(v)), step, style: { width: `${w}px` } }) as HTMLInputElement;
    i.addEventListener("change", () => { const n = parseFloat(i.value); if (Number.isFinite(n)) f(n); });
    i.addEventListener("keydown", (e) => e.stopPropagation());
    return i;
  };
  const len = clipLength(clip);
  const vol = h("input", { type: "range", min: 0, max: 1, step: 0.01, value: String(clip.volume), style: { width: "110px" } }) as HTMLInputElement;
  vol.addEventListener("input", () => store.updateClip(clip.id, (c) => { c.volume = parseFloat(vol.value); }));
  const trackSel = h("select", {}, Array.from({ length: Math.max(1, store.trackCount) }, (_, i) => h("option", { value: String(i), selected: i === clip.track }, `A${i + 1}`))) as HTMLSelectElement;
  trackSel.addEventListener("change", () => store.setClipTrack(clip.id, parseInt(trackSel.value)));
  box.append(
    line(h("b", {}, `♪ ${clip.name}`), h("span", { class: "dim" }, `曲の長さ ${fmt(clip.duration)}`),
      "置く位置", num(clip.start, (n) => store.moveClip(clip.id, n)), "秒",
      "音量", vol, `${Math.round(clip.volume * 100)}%`,
      "トラック", trackSel, button(store.audio.auditioning === clip.id ? "⏹ 試聴を止める" : "▶ 試聴", () => { store.audio.audition(clip, () => store.emit()); store.emit(); }, { small: true, title: "このクリップの範囲だけを聴く" }), h("span", { style: { flex: "1" } }), button("削除", () => store.removeClip(clip.id), { small: true, danger: true })),
    line(h("span", { class: "dim" }, "曲の範囲"), "開始位置", num(clip.inPoint, (n) => store.updateClip(clip.id, (c) => { c.inPoint = n; })), "〜",
      "終了位置", num(Math.min(clip.outPoint ?? clip.duration, clip.duration), (n) => store.updateClip(clip.id, (c) => { c.outPoint = n; })),
      h("span", { class: "dim" }, `（使う長さ ${fmt(len)}）`),
      "フェードイン", num(clip.fadeIn, (n) => store.updateClip(clip.id, (c) => { c.fadeIn = n; }), 0.5, 52),
      "アウト", num(clip.fadeOut, (n) => store.updateClip(clip.id, (c) => { c.fadeOut = n; }), 0.5, 52)));
  root.append(box);
  return box;
}
