// 編集の画面（シート）: タイトル、V2 のクリップ、写真ごとの設定、トラックの設定、単色画像、mp4 書き出し、拡大表示。
import { ANCHORS, EXPORT_SIZES, FITS, TITLE_EFFECTS, TRANSITIONS, type FitMode, type OverlayClip, type TitleItem, type Transition } from "./model.ts";
import { drawFrame, drawTitles, type Scene } from "./render.ts";
import { SlideTiming, clamp, overlayState } from "./engine.ts";
import { button, checkbox, fmt, h, numField, pctField, round1, row, select, slider, type Child } from "./dom.ts";
import { decodeImage } from "./images.ts";
import { listFonts } from "./fonts.ts";
import { basename, native } from "./native.ts";
import { exportMovie, type ExportJob } from "./exporter.ts";
import { store, type TrackRef } from "./store.ts";

export type SheetKind = "titles" | "overlay" | "override" | "track" | "color" | "export" | "viewer" | "viewerImage";

export function openSheet(kind: SheetKind, arg: any = {}) { store.sheet = { kind, arg }; store.emit(); }
export function closeSheet() { store.sheet = null; store.emit(); }

let rendered: object | null = null;

export function renderSheet(root: HTMLElement) {
  if (store.sheet === rendered) return;
  rendered = store.sheet;
  root.replaceChildren();
  const s = store.sheet;
  if (!s) return;
  const el = ({ titles: titlesSheet, overlay: overlaySheet, override: overrideSheet, track: trackSheet, color: colorSheet, export: exportSheet, viewer: viewerSheet, viewerImage: viewerImageSheet } as Record<string, (arg: any) => HTMLElement | null>)[s.kind](s.arg);
  if (!el) { store.sheet = null; rendered = null; return; }
  const ov = h("div", { class: "overlay" }, el);
  ov.addEventListener("pointerdown", (e) => { if (e.target === ov && s.kind !== "export") closeSheet(); });
  root.append(ov);
}

function sheet(title: string, width: number, body: Child[], foot: Child[], opts: { height?: number } = {}) {
  return h("div", { class: "sheet", style: { width: `${width}px`, height: opts.height ? `${opts.height}px` : "auto" } },
    title ? h("h2", {}, title) : null, h("div", { class: "body" }, ...body), h("div", { class: "foot" }, ...foot));
}

/** 16:9 の小さなプレビュー */
function miniCanvas(width: number): { box: HTMLElement; canvas: HTMLCanvasElement } {
  const canvas = h("canvas", { width: 640, height: 360 }) as HTMLCanvasElement;
  return { box: h("div", { class: "preview-mini", style: { width: `${width}px` } }, canvas), canvas };
}

const emptyScene = (): Scene => ({
  paths: [], timing: new SlideTiming([], { dwell: 5, transition: "none", transitionDuration: 0, fit: "fit" }, {}), seed: 0, v1Opacity: 1,
  overlays: [], titles: [], transition: "kenBurns", fit: "fit", endFade: 0,
});

// ───────────────────── タイトル（左に一覧、右で調整）─────────────────────
function titlesSheet(arg: { select?: string }): HTMLElement {
  const sel = (): string[] => {
    const valid = [...store.selTitles].filter((id) => store.p.titles.some((t) => t.id === id));
    return valid.length ? valid : store.p.titles.slice(0, 1).map((t) => t.id);
  };
  if (arg.select) store.selTitles = new Set([arg.select]);
  const active = () => store.p.titles.find((t) => sel().includes(t.id));
  const all = () => store.p.titles.filter((t) => sel().includes(t.id));

  const list = h("div", { class: "list" });
  const right = h("div", { class: "right" });
  const { box: pbox, canvas: pcv } = miniCanvas(420);
  pbox.style.margin = "12px auto 0";
  const editor = h("div", { style: { padding: "6px 16px 12px", overflow: "auto", flex: "1" } });
  right.append(pbox, editor);
  let anchorId: string | null = null;

  const drawPreview = () => {
    const ctx = pcv.getContext("2d")!;
    const first = store.photos[0];
    drawFrame(ctx, pcv.width, pcv.height, 0, emptyScene(), { v1: () => undefined, overlay: () => undefined });
    const th = first ? store.thumbs.get(first) : undefined;
    if (th) { ctx.globalAlpha = 0.5; const r = Math.max(pcv.width / th.width, pcv.height / th.height); ctx.drawImage(th, (pcv.width - th.width * r) / 2, (pcv.height - th.height * r) / 2, th.width * r, th.height * r); ctx.globalAlpha = 1; }
    drawTitles(ctx, pcv.width, pcv.height, all(), null);
  };

  const renderList = () => {
    list.replaceChildren();
    const ids = sel();
    store.p.titles.forEach((t) => {
      const it = h("div", { class: `litem${ids.includes(t.id) ? " sel" : ""}` },
        h("span", { class: "tag" }, `T${t.track + 1}`),
        h("div", { style: { minWidth: "0" } },
          h("div", { style: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } }, t.text.split("\n")[0] || "（空）"),
          h("div", { class: "t2" }, `${fmt(t.start)} 〜 ${t.duration > 0 ? fmt(t.start + t.duration) : "最後まで"}`)));
      it.addEventListener("pointerdown", (e) => {
        if (e.shiftKey && anchorId) {
          const a = store.p.titles.findIndex((x) => x.id === anchorId), b = store.p.titles.findIndex((x) => x.id === t.id);
          const s = new Set(store.selTitles); for (let i = Math.min(a, b); i <= Math.max(a, b); i++) s.add(store.p.titles[i].id); store.selTitles = s;
        } else if (e.metaKey || e.ctrlKey) {
          const s = new Set(sel()); if (s.has(t.id)) s.delete(t.id); else s.add(t.id); store.selTitles = s; anchorId = t.id;
        } else { store.selTitles = new Set([t.id]); anchorId = t.id; }
        renderList(); buildEditor(); drawPreview(); store.emit();
      });
      list.append(it);
    });
  };

  const apply = (fn: (t: TitleItem) => void) => { for (const t of all()) store.updateTitle(t.id, fn); renderList(); drawPreview(); };

  const buildEditor = async () => {
    editor.replaceChildren();
    const a = active();
    if (!a) { editor.append(h("div", { class: "dim", style: { padding: "30px", textAlign: "center" } }, "左の「追加」でタイトルを追加します")); return; }
    const n = all().length;
    if (n > 1) editor.append(h("div", { class: "dim", style: { margin: "6px 0" } }, `${n} 件を選択中（文字は、先頭の 1 件だけ編集）`));
    const text = h("textarea", { rows: 2, value: a.text, style: { marginTop: "4px" } }) as HTMLTextAreaElement;
    text.addEventListener("input", () => { store.updateTitle(a.id, (t) => { t.text = text.value; }); renderList(); drawPreview(); });
    text.addEventListener("keydown", (e) => e.stopPropagation());
    editor.append(h("div", { class: "section" }, "文字（改行できます）"), text);

    editor.append(h("div", { class: "section" }, "位置"));
    editor.append(
      row("トラック", select(Array.from({ length: Math.max(1, store.titleTrackCount) }, (_, i) => ({ id: String(i), label: `T${i + 1}` })), String(a.track), (v) => apply((t) => { t.track = parseInt(v); }))),
      row("位置", select(ANCHORS, a.anchor, (v) => apply((t) => { t.anchor = v; }))),
      row("微調整", nudgeField("横", a.offsetX, (v) => apply((t) => { t.offsetX = v; })), nudgeField("縦", a.offsetY, (v) => apply((t) => { t.offsetY = v; })),
        button("元に戻す", () => { apply((t) => { t.offsetX = 0; t.offsetY = 0; }); void buildEditor(); }, { small: true })));

    editor.append(h("div", { class: "section" }, "見た目"));
    const color = h("input", { type: "color", value: a.color || "#FFFFFF" }) as HTMLInputElement;
    color.addEventListener("input", () => apply((t) => { t.color = color.value.toUpperCase(); }));
    const fonts = await listFonts();
    const fontSel = h("select", {}, [
      h("option", { value: "", selected: !a.fontName }, "標準"),
      ...fonts.recommended.map((f) => h("option", { value: f, selected: f === a.fontName }, f)),
      h("option", { disabled: true }, "──────────"),
      ...fonts.all.filter((f) => !fonts.recommended.includes(f)).map((f) => h("option", { value: f, selected: f === a.fontName }, f)),
    ]) as HTMLSelectElement;
    fontSel.addEventListener("change", () => apply((t) => { t.fontName = fontSel.value; }));
    editor.append(
      row("色", color),
      row("フォント", fontSel),
      row("大きさ", slider(a.size, 0.02, 0.2, 0.002, (v) => apply((t) => { t.size = v; })), pctField(a.size, (v) => { apply((t) => { t.size = v; }); void buildEditor(); }, [0.01, 0.5])),
      row("", checkbox("太字", a.bold, (v) => apply((t) => { t.bold = v; })), checkbox("影", a.shadow, (v) => apply((t) => { t.shadow = v; }))));

    editor.append(h("div", { class: "section" }, "出る時間"));
    const dur = numField(a.duration, (v) => apply((t) => { t.duration = Math.max(0.5, v); }), { disabled: a.duration <= 0 });
    editor.append(
      row("出す時刻", numField(a.start, (v) => apply((t) => { t.start = Math.max(0, v); })), h("span", { class: "dim" }, "秒（スライドショーの頭から）")),
      row("", checkbox("ずっと表示（出す時刻から最後まで）", a.duration <= 0, (v) => { apply((t) => { t.duration = v ? 0 : 5; }); void buildEditor(); })),
      row("表示する長さ", dur, h("span", { class: "dim" }, "秒")));

    editor.append(h("div", { class: "section" }, "エフェクト"));
    editor.append(
      row("出方・消え方", select(TITLE_EFFECTS, a.effect, (v) => apply((t) => { t.effect = v; }))),
      row("動きの長さ", numField(a.effectDuration, (v) => apply((t) => { t.effectDuration = Math.max(0.05, v); }), { disabled: a.effect === "none" }), h("span", { class: "dim" }, "秒")));
  };

  const tools = h("div", { class: "tools" },
    button("＋ 追加", () => { const it = store.addTitle(store.playhead); store.selTitles = new Set([it.id]); renderList(); void buildEditor(); drawPreview(); }, { small: true }),
    button("複製", () => { const a = active(); if (a) { store.duplicateTitle(a.id); renderList(); void buildEditor(); drawPreview(); } }, { small: true, title: "選んだタイトルを複製" }),
    button("削除", () => { store.removeTitles(sel()); store.selTitles = new Set(); renderList(); void buildEditor(); drawPreview(); }, { small: true, danger: true }),
    h("span", { style: { flex: "1" } }), h("span", { class: "dim" }, `${store.p.titles.length} 件`));
  const left = h("div", { class: "left" }, list, tools);
  renderList(); void buildEditor(); drawPreview();
  setTimeout(drawPreview, 300);
  const root = h("div", { class: "sheet", style: { width: "900px", height: "680px" } },
    h("div", { class: "split" }, left, right),
    h("div", { class: "foot" }, h("span", { class: "dim", style: { fontSize: "11px" } }, "一覧は Shift・Ctrl クリックで複数選択。右の変更は、選んだすべてに効きます（文字だけは先頭の 1 件）"), h("span", { class: "spacer" }), button("閉じる", closeSheet, { primary: true })));
  return root;
}

/** 位置の微調整: − / + で 0.5 % ずつ（押し続けると連続）。数字でも入力できる */
function nudgeField(label: string, value: number, onChange: (v: number) => void): HTMLElement {
  let v = value;
  const wrap = h("span", { class: "pct", style: { gap: "4px" } });
  const draw = () => {
    wrap.replaceChildren(h("span", { class: "dim" }, label),
      repeatButton("−", () => { v = Math.max(-0.5, Math.round((v - 0.005) * 1000) / 1000); onChange(v); draw(); }),
      pctField(v, (n) => { v = n; onChange(v); draw(); }, [-0.5, 0.5]),
      repeatButton("＋", () => { v = Math.min(0.5, Math.round((v + 0.005) * 1000) / 1000); onChange(v); draw(); }));
  };
  draw();
  return wrap;
}

function repeatButton(label: string, fn: () => void): HTMLElement {
  const b = button(label, () => {}, { small: true, icon: true });
  let timer = 0, delay = 0;
  const fire = () => { fn(); timer = window.setTimeout(fire, delay = Math.max(40, delay * 0.85)); };
  b.onclick = null;
  b.addEventListener("pointerdown", () => { delay = 350; fire(); const stop = () => { clearTimeout(timer); window.removeEventListener("pointerup", stop); }; window.addEventListener("pointerup", stop); });
  return b;
}

// ───────────────────── V2 のクリップ ─────────────────────
function overlaySheet(arg: { id?: string }): HTMLElement | null {
  const clip0 = store.p.overlayClips.find((c) => c.id === arg.id);
  if (!clip0) return null;
  const id = clip0.id;
  const get = () => store.p.overlayClips.find((c) => c.id === id)!;
  const targets = () => (store.selOverlays.has(id) ? [...store.selOverlays] : [id]);
  const apply = (fn: (c: OverlayClip) => void, group = true) => { for (const t of group ? targets() : [id]) store.updateOverlay(t, fn); draw(); };

  const { box, canvas } = miniCanvas(440);
  box.style.alignSelf = "flex-start";
  let img: ImageBitmap | null = null;
  const draw = () => {
    const c = get();
    const ctx = canvas.getContext("2d")!;
    ctx.fillStyle = "#404040"; ctx.fillRect(0, 0, canvas.width, canvas.height);
    if (!img) return;
    const st = overlayState({ ...c }, c.start + c.duration / 2, store.p.transition, store.p.fit, undefined, true)!;
    const r = st.fill ? Math.max(canvas.width / img.width, canvas.height / img.height) : Math.min(canvas.width / img.width, canvas.height / img.height);
    ctx.save(); ctx.globalAlpha = st.opacity; ctx.translate(canvas.width / 2 + st.dx * canvas.width, canvas.height / 2 + st.dy * canvas.height); ctx.scale(st.scale, st.scale);
    ctx.drawImage(img, (-img.width * r) / 2, (-img.height * r) / 2, img.width * r, img.height * r); ctx.restore();
  };
  decodeImage(clip0.path, 900).then((b) => { img = b; draw(); }).catch(() => {});

  const body = h("div", {});
  const build = () => {
    body.replaceChildren();
    const c = get();
    const n = targets().length;
    if (n > 1) body.append(h("div", { class: "dim", style: { marginBottom: "6px" } }, `${n} 件を選択中。変更は選んだすべてに効きます（開始の時刻だけは、この 1 件）`));
    const defTr: Transition = store.p.transition === "none" ? "crossfade" : store.p.transition;
    body.append(
      row("不透明度", slider(c.opacity, 0, 1, 0.01, (v) => apply((x) => { x.opacity = v; })), pctField(c.opacity, (v) => { apply((x) => { x.opacity = v; }); build(); })),
      row("大きさ", slider(c.scale, 0.1, 2, 0.01, (v) => apply((x) => { x.scale = v; })), pctField(c.scale, (v) => { apply((x) => { x.scale = v; }); build(); }, [0.05, 4])),
      row("位置の微調整", nudgeField("横", c.offsetX, (v) => apply((x) => { x.offsetX = v; })), nudgeField("縦", c.offsetY, (v) => apply((x) => { x.offsetY = v; })),
        button("元に戻す", () => { apply((x) => { x.offsetX = 0; x.offsetY = 0; x.scale = 1; }); build(); }, { small: true })),
      row(checkbox("エフェクトを変える", c.transition !== undefined, (v) => { apply((x) => { x.transition = v ? defTr : undefined; }); build(); }),
        select(TRANSITIONS, c.transition ?? store.p.transition, (v) => apply((x) => { x.transition = v; }), { disabled: c.transition === undefined })),
      row(checkbox("表示の仕方を変える", c.fit !== undefined, (v) => { apply((x) => { x.fit = v ? store.p.fit : undefined; }); build(); }),
        select(FITS, c.fit ?? store.p.fit, (v) => apply((x) => { x.fit = v as FitMode; }), { disabled: c.fit === undefined })),
      row("開始と長さ", numField(c.start, (v) => apply((x) => { x.start = v; }, false)), h("span", { class: "dim" }, "秒 から"), numField(c.duration, (v) => apply((x) => { x.duration = v; })), h("span", { class: "dim" }, "秒間")),
      row("切り替えの長さ", h("span", { class: "dim" }, "イン"), numField(c.fadeIn, (v) => apply((x) => { x.fadeIn = Math.max(0, v); }), { width: 56 }), h("span", { class: "dim" }, "秒　アウト"), numField(c.fadeOut, (v) => apply((x) => { x.fadeOut = Math.max(0, v); }), { width: 56 }), h("span", { class: "dim" }, "秒")));
  };
  build();
  return sheet(basename(clip0.path), 660, [box, body], [
    button("🗑 このクリップを消す", () => { store.selOverlays = new Set([id]); store.removeSelectedOverlays(); closeSheet(); }, { danger: true }),
    h("span", { class: "spacer" }), button("閉じる", closeSheet, { primary: true })]);
}

// ───────────────────── 写真ごとの設定 ─────────────────────
function overrideSheet(arg: { paths: string[] }): HTMLElement | null {
  const paths = arg.paths.filter((p) => store.photos.includes(p));
  if (!paths.length) return null;
  const first = store.p.overrides[paths[0]];
  let useDwell = first?.dwell !== undefined, dwell = first?.dwell ?? store.p.dwell;
  let useTr = !!first?.transition, tr: Transition = first?.transition ?? (store.p.transition === "none" ? "crossfade" : store.p.transition);
  let useFit = !!first?.fit, fit: FitMode = first?.fit ?? store.p.fit;
  const body = h("div", {});
  const build = () => {
    body.replaceChildren(
      row(checkbox("表示時間を変える", useDwell, (v) => { useDwell = v; build(); }), numField(dwell, (v) => { dwell = Math.max(0.3, v); }, { disabled: !useDwell }), h("span", { class: "dim" }, "秒")),
      row(checkbox("エフェクトを変える", useTr, (v) => { useTr = v; build(); }), select(TRANSITIONS, tr, (v) => { tr = v; }, { disabled: !useTr })),
      row(checkbox("表示の仕方を変える", useFit, (v) => { useFit = v; build(); }), select(FITS, fit, (v) => { fit = v; }, { disabled: !useFit })),
      h("div", { class: "dim", style: { fontSize: "11px", margin: "8px 0" } }, "オフの項目は、設定のタブの値に従います。エフェクトは、その写真が出てくるときの切り替えです。"));
  };
  build();
  const thumbs = h("div", { style: { display: "flex", gap: "4px", flexWrap: "wrap", margin: "6px 0" } },
    paths.slice(0, 12).map((p) => { const cv = h("canvas", { width: 72, height: 72, style: { width: "36px", height: "36px", borderRadius: "4px" } }) as HTMLCanvasElement; paintInto(cv, p); return cv; }),
    paths.length > 12 ? h("span", { class: "dim" }, `ほか ${paths.length - 12} 枚`) : null);
  const { box, canvas } = miniCanvas(420);
  decodeImage(paths[0], 900).then((b) => { const c = canvas.getContext("2d")!; c.fillStyle = "#000"; c.fillRect(0, 0, canvas.width, canvas.height); const r = Math.min(canvas.width / b.width, canvas.height / b.height); c.drawImage(b, (canvas.width - b.width * r) / 2, (canvas.height - b.height * r) / 2, b.width * r, b.height * r); }).catch(() => {});
  box.style.alignSelf = "center";
  const hasAny = paths.some((p) => { const o = store.p.overrides[p]; return o && (o.dwell !== undefined || o.transition || o.fit); });
  return sheet(paths.length === 1 ? `${store.photos.indexOf(paths[0]) + 1} 枚目  ${basename(paths[0])}` : `選んだ ${paths.length} 枚`, 520, [box, thumbs, body], [
    button("個別設定を外す", () => { store.setOverride(paths, {}); closeSheet(); }, { disabled: !hasAny }),
    h("span", { class: "spacer" }), button("キャンセル", closeSheet),
    button("適用", () => { store.setOverride(paths, { dwell: useDwell ? Math.max(0.3, dwell) : undefined, transition: useTr ? tr : undefined, fit: useFit ? fit : undefined }); closeSheet(); }, { primary: true })]);
}

function paintInto(cv: HTMLCanvasElement, path: string) {
  store.thumbs.request(path);
  const draw = () => { const b = store.thumbs.get(path); if (!b) return false; const c = cv.getContext("2d")!; const r = Math.max(cv.width / b.width, cv.height / b.height); c.drawImage(b, (cv.width - b.width * r) / 2, (cv.height - b.height * r) / 2, b.width * r, b.height * r); return true; };
  if (!draw()) { let n = 0; const t = setInterval(() => { if (draw() || ++n > 40) clearInterval(t); }, 150); }
}

// ───────────────────── トラックの設定 ─────────────────────
function trackSheet(arg: { ref: TrackRef }): HTMLElement {
  const ref = arg.ref;
  const audio = ref.kind === "audio";
  const name = ref.kind === "main" ? "V1" : ref.kind === "title" ? `T${ref.index + 1}` : ref.kind === "overlay" ? `V${ref.index + 2}` : `A${ref.index + 1}`;
  const title = ref.kind === "main" ? "V1 トラック（スライドショーの写真）" : ref.kind === "title" ? `${name} トラック（タイトル）` : ref.kind === "overlay" ? `${name} トラック（重ねる写真）` : `${name} トラック（音声）`;
  const count = ref.kind === "main" ? store.playCount : ref.kind === "title" ? store.p.titles.filter((t) => t.track === ref.index).length : ref.kind === "overlay" ? store.p.overlayClips.filter((c) => c.track === ref.index).length : store.p.clips.filter((c) => c.track === ref.index).length;
  const body = h("div", {});
  const build = () => {
    body.replaceChildren();
    const st = store.trackSetting(ref);
    body.append(h("div", { class: "dim", style: { margin: "4px 0 8px" } }, ref.kind === "main" ? `${count} 枚の写真` : `${count} 個のクリップ`));
    if (audio) {
      body.append(
        row("", checkbox("ミュート（このトラックの音を出さない）", st.muted, (v) => { store.updateTrackSetting(ref, (s) => { s.muted = v; }); build(); })),
        row("音量", slider(st.volume, 0, 1, 0.01, (v) => store.updateTrackSetting(ref, (s) => { s.volume = v; }), { disabled: st.muted }), pctField(st.volume, (v) => { store.updateTrackSetting(ref, (s) => { s.volume = v; }); build(); }, [0, 1], { disabled: st.muted })));
    } else {
      body.append(
        row("", checkbox("非表示にする（画面にも mp4 にも出さない）", st.hidden, (v) => { store.updateTrackSetting(ref, (s) => { s.hidden = v; }); build(); })),
        row("不透明度", slider(st.opacity, 0, 1, 0.01, (v) => store.updateTrackSetting(ref, (s) => { s.opacity = v; }), { disabled: st.hidden }), pctField(st.opacity, (v) => { store.updateTrackSetting(ref, (s) => { s.opacity = v; }); build(); }, [0, 1], { disabled: st.hidden })));
    }
    body.append(h("div", { class: "dim", style: { fontSize: "11px", margin: "8px 0" } }, audio ? "クリップごとの音量に、このトラックの音量を掛けます。" : "クリップごとの透明度に、このトラックの不透明度を掛けます。V1 は、写真の層ぜんたいの濃さです（下は黒）。"));
  };
  build();
  return sheet(title, 480, [body], [
    button("既定に戻す", () => { store.updateTrackSetting(ref, (s) => { s.opacity = 1; s.hidden = false; s.volume = 1; s.muted = false; }); build(); }),
    h("span", { class: "spacer" }), button("閉じる", closeSheet, { primary: true })]);
}

// ───────────────────── 単色画像 ─────────────────────
function colorSheet(): HTMLElement {
  let color = "#000000", dwell = store.p.dwell;
  const { box, canvas } = miniCanvas(360);
  const draw = () => { const c = canvas.getContext("2d")!; c.fillStyle = color; c.fillRect(0, 0, canvas.width, canvas.height); drawTitles(c, canvas.width, canvas.height, store.p.titles, null); };
  const input = h("input", { type: "color", value: color }) as HTMLInputElement;
  input.addEventListener("input", () => { color = input.value; draw(); });
  const swatches = ["#000000", "#FFFFFF", "#808080", "#0D194D", "#B31A1A", "#1A8033"].map((c) => {
    const b = h("button", { class: "btn small", title: c, style: { width: "24px", height: "24px", padding: "0", borderRadius: "12px", background: c } });
    b.addEventListener("click", () => { color = c; input.value = c; draw(); });
    return b;
  });
  draw();
  return sheet("単色画像を追加", 440, [box,
    row("色", input, ...swatches),
    row("表示時間", numField(dwell, (v) => { dwell = Math.max(0.3, v); }), h("span", { class: "dim" }, "秒")),
    h("div", { class: "dim", style: { fontSize: "11px" } }, `再生ヘッドの位置（${fmt(store.playhead)}）に入ります。順番は「手動」になります。`)],
    [h("span", { class: "spacer" }), button("キャンセル", closeSheet), button("追加", () => { void store.addColorCard(color, dwell); closeSheet(); }, { primary: true })]);
}

// ───────────────────── mp4 書き出し ─────────────────────
function exportSheet(): HTMLElement {
  const job: ExportJob = { cancelled: false, progress: 0, message: "", state: "running" };
  let running = false;
  const body = h("div", {});
  const foot = h("div", { class: "foot" });
  const root = h("div", { class: "sheet", style: { width: "520px" } }, h("h2", {}, "mp4 に書き出す"), body, foot);
  const draw = () => {
    body.replaceChildren(); foot.replaceChildren();
    body.className = "body";
    const total = store.totalDuration;
    if (!running && job.state === "running") {
      body.append(
        h("div", { class: "dim", style: { margin: "4px 0 8px" } }, `${store.playCount} 枚 × ${store.p.dwell} 秒 ＝ 約 ${fmt(total)}（V2・タイトル・音楽を含む）`),
        row("大きさ", select(EXPORT_SIZES.map((s) => ({ id: s.id, label: s.label })), store.p.exportSize, (v) => { store.p.exportSize = v; })),
        row("コマ数", select([{ id: "24", label: "24 fps" }, { id: "30", label: "30 fps" }, { id: "60", label: "60 fps" }], String(store.p.exportFps), (v) => { store.p.exportFps = parseInt(v); })),
        h("div", { class: "dim", style: { fontSize: "11px" } }, "H.264 の mp4（16:9）。初めてのときは ffmpeg を自動で用意します（数十 MB のダウンロード）。"));
      foot.append(h("span", { class: "spacer" }), button("キャンセル", closeSheet), button("書き出す…", () => void start(), { primary: true }));
    } else {
      body.append(h("div", { class: "progress" }, h("div", { style: { width: `${Math.round(job.progress * 100)}%` } })), h("div", { class: job.state === "failed" ? "" : "dim", style: job.state === "failed" ? { color: "var(--red)" } : {} }, job.message));
      if (job.state === "running") foot.append(h("span", { class: "spacer" }), button("中止", () => { job.cancelled = true; }, { danger: true }));
      else foot.append(...(job.state === "done" && job.output ? [button("フォルダで表示", () => void native.reveal(job.output!))] : []), h("span", { class: "spacer" }), button("閉じる", closeSheet, { primary: true }));
    }
  };
  const start = async () => {
    const { save } = await import("@tauri-apps/plugin-dialog");
    const base = store.documentPath ? basename(store.documentPath).replace(/\.cpsd$/i, "") : store.p.sources[0] ? basename(store.p.sources[0]).replace(/\.[^.]*$/, "") : "Slideshow";
    const dest = await save({ title: "スライドショーを mp4 として保存します", defaultPath: `${base}.mp4`, filters: [{ name: "MP4 ムービー", extensions: ["mp4"] }] });
    if (!dest) return;
    running = true; job.state = "running"; draw();
    await exportMovie(dest.endsWith(".mp4") ? dest : `${dest}.mp4`, job, draw);
    running = true; draw();
  };
  draw();
  return root;
}

// ───────────────────── 拡大表示 ─────────────────────
function viewerSheet(arg: { path: string }): HTMLElement | null {
  let index = store.photos.indexOf(arg.path);
  if (index < 0) index = 0;
  if (!store.photos.length) return null;
  const canvas = h("canvas", { width: 1600, height: 900, style: { width: "100%", height: "100%", display: "block", background: "#000" } }) as HTMLCanvasElement;
  const info = h("div", {});
  const load = async () => {
    const p = store.photos[index];
    info.replaceChildren(h("b", {}, basename(p)), h("span", { class: "dim", style: { marginLeft: "10px" } }, `${index + 1} / ${store.photos.length}`));
    const b = await decodeImage(p, 3000).catch(() => null);
    const c = canvas.getContext("2d")!;
    c.fillStyle = "#000"; c.fillRect(0, 0, canvas.width, canvas.height);
    if (b) { const r = Math.min(canvas.width / b.width, canvas.height / b.height); c.drawImage(b, (canvas.width - b.width * r) / 2, (canvas.height - b.height * r) / 2, b.width * r, b.height * r); }
  };
  const step = (d: number) => { index = clamp(index + d, 0, store.photos.length - 1); void load(); };
  const key = (e: KeyboardEvent) => { if (e.key === "ArrowLeft") { e.stopPropagation(); step(-1); } else if (e.key === "ArrowRight") { e.stopPropagation(); step(1); } else if (e.key === "Escape") { window.removeEventListener("keydown", key, true); closeSheet(); } };
  window.addEventListener("keydown", key, true);
  void load();
  const root = h("div", { class: "sheet", style: { width: "min(1000px, 92vw)", height: "min(740px, 88vh)" } },
    h("div", { style: { flex: "1", minHeight: "0" } }, canvas),
    h("div", { class: "foot" }, button("◀", () => step(-1), { icon: true }), button("▶", () => step(1), { icon: true }), info, h("span", { class: "spacer" }),
      button("フォルダで表示", () => void native.reveal(store.photos[index])), button("閉じる", () => { window.removeEventListener("keydown", key, true); closeSheet(); }, { primary: true })));
  return root;
}

function viewerImageSheet(arg: { path: string }): HTMLElement {
  const canvas = h("canvas", { width: 1600, height: 900, style: { width: "100%", height: "100%", display: "block", background: "#000" } }) as HTMLCanvasElement;
  decodeImage(arg.path, 3000).then((b) => { const c = canvas.getContext("2d")!; const r = Math.min(canvas.width / b.width, canvas.height / b.height); c.drawImage(b, (canvas.width - b.width * r) / 2, (canvas.height - b.height * r) / 2, b.width * r, b.height * r); }).catch(() => {});
  return h("div", { class: "sheet", style: { width: "min(1000px, 92vw)", height: "min(740px, 88vh)" } },
    h("div", { style: { flex: "1", minHeight: "0" } }, canvas),
    h("div", { class: "foot" }, h("span", {}, basename(arg.path)), h("span", { class: "spacer" }), button("閉じる", closeSheet, { primary: true })));
}

void round1;
