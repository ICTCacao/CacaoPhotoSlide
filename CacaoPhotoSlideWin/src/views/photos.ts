// 「写真」のタブ: V1（スライドショーの写真）と V2（重ねる写真）のライブラリ。
import { basename } from "../native.ts";
import { beginDrag, registerDropTarget } from "../drag.ts";
import { button, contextMenu, h, mod } from "../dom.ts";
import { startSlideshow } from "../fullscreen.ts";
import { store } from "../store.ts";
import { openSheet } from "../sheets.ts";

const CELL = 64;

/** サムネイルを、まだ描いていない canvas に描く */
export function paintThumbs(root: ParentNode) {
  root.querySelectorAll<HTMLCanvasElement>("canvas[data-thumb]").forEach((cv) => {
    if (cv.dataset.done) return;
    const path = cv.dataset.thumb!;
    const b = store.thumbs.get(path);
    if (!b) return;
    const w = (cv.width = CELL * 2), hgt = (cv.height = Math.round(cv.dataset.aspect === "wide" ? CELL * 1.5 : CELL * 2));
    const c = cv.getContext("2d")!;
    const r = Math.max(w / b.width, hgt / b.height);        // 余白なく埋める
    c.drawImage(b, (w - b.width * r) / 2, (hgt - b.height * r) / 2, b.width * r, b.height * r);
    cv.dataset.done = "1";
  });
}

function thumbCanvas(path: string, wide = false) {
  const cv = h("canvas", { "data-thumb": path, "data-aspect": wide ? "wide" : "" }) as HTMLCanvasElement;
  store.thumbs.request(path);
  return cv;
}

export function renderPhotos(pane: HTMLElement) {
  pane.replaceChildren();
  const wrap = h("div", { class: "photos-pane" });
  pane.append(wrap);
  wrap.append(h("div", { class: "tabs", style: { padding: "0" } },
    h("div", { class: "seg" },
      h("button", { class: store.libraryMode === "v1" ? "on" : "", onClick: () => { store.libraryMode = "v1"; store.emit(); } }, "V1 トラック"),
      h("button", { class: store.libraryMode === "v2" ? "on" : "", onClick: () => { store.libraryMode = "v2"; store.emit(); } }, "V2 トラック"))));
  wrap.append(store.libraryMode === "v1" ? v1Zone() : v2Zone());
  paintThumbs(wrap);
}

// ───────────── V1 ─────────────
function v1Zone() {
  const zone = h("div", { class: "dropzone" });
  if (!store.photos.length && !store.scanning) {
    zone.append(h("div", { class: "empty" },
      h("div", { class: "big" }, "🖼"),
      h("div", { class: "title" }, "ここに写真のフォルダをドロップ"),
      h("div", {}, "音声ファイルや .cpsd 書類も落とせます"),
      store.message ? h("div", {}, store.message) : null,
      h("div", { style: { display: "flex", gap: "8px" } },
        button("フォルダを開く…", () => void store.openPanel()),
        button("写真・音声を選ぶ…", () => void store.openFilesPanel()),
        button("書類を開く…", () => void store.openDocumentPanel()))));
    return zone;
  }
  const names = store.p.sources.map(basename);
  const title = names.length <= 2 ? names.join("、") : `${names[0]} ほか ${names.length - 1} 件`;
  zone.append(h("div", { class: "lib-head" },
    h("span", {}, "📁"), h("span", { style: { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" } }, title),
    h("span", { class: "spacer" }),
    store.scanning ? h("span", { class: "dim" }, "読み込み中…") : h("b", {}, `${store.photos.length} 枚`),
    store.removedCount ? button(`外した ${store.removedCount} 枚を戻す`, () => store.restoreRemoved(), { small: true }) : null,
    button("拡大表示", () => openSheet("viewer", { path: [...store.selection][0] ?? store.photos[0] }), { small: true, disabled: !store.photos.length }),
    button("個別設定", () => openSheet("override", { paths: [...store.selection] }), { small: true, disabled: !store.selection.size, title: "選んだ写真だけ、表示時間・エフェクト・表示の仕方を変える" }),
    button("開く…", () => void store.openPanel())));
  const label = store.selectionLabel;
  zone.append(h("div", { class: "lib-hint" },
    label ? h("span", { style: { color: "var(--accent)" } }, label,
      " ", h("a", { href: "#", style: { color: "var(--dim)" }, onClick: (e: Event) => { e.preventDefault(); store.clearSelection(); } }, "✕ 解除"))
          : "クリック: その写真から開始　Ctrl / ⇧クリック: 複数を選んで、その写真だけを流す　ダブルクリック: すぐ開始　ドラッグ: 並べ替え　右クリック: 個別設定・写真を外す"));

  const grid = h("div", { class: "grid" });
  zone.append(grid);
  const cells = new Map<string, HTMLElement>();
  for (let i = 0; i < store.photos.length; i++) {
    const path = store.photos[i];
    const sel = store.selection.has(path);
    const ov = store.p.overrides[path];
    const cell = h("div", { class: `cell${sel ? " sel" : ""}`, "data-path": path, title: `${i + 1} / ${store.photos.length}  ${basename(path)}` },
      thumbCanvas(path),
      ov && (ov.dwell !== undefined || ov.transition || ov.fit) ? h("div", { class: "badge" }, ov.dwell !== undefined ? `${ov.dwell}s` : "★") : null,
      sel ? h("div", { class: "mark" }, store.selection.size >= 2 ? "✓" : "▶") : null);
    cell.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const m = mod(e);
      beginDrag(e, () => {
        const group = store.selection.has(path) && store.selection.size >= 2 ? store.photos.filter((p) => store.selection.has(p)) : [path];
        return { kind: "photos", paths: group };
      }, () => (store.selection.has(path) && store.selection.size >= 2 ? `${store.selection.size} 枚` : "1 枚"), () => store.click(path, m));
    });
    cell.addEventListener("dblclick", () => { if (store.selection.size < 2) store.selection = new Set([path]); void startSlideshow(path); });
    contextMenu(cell, () => {
      const group = store.selection.has(path) && store.selection.size >= 2 ? store.photos.filter((p) => store.selection.has(p)) : [path];
      return [
        { label: group.length >= 2 ? `選んだ ${group.length} 枚を外す` : "この写真を外す", onClick: () => store.removePhotos(group) },
        { label: "表示時間・エフェクトを変える…", onClick: () => openSheet("override", { paths: group }) },
        { label: "拡大して見る", onClick: () => openSheet("viewer", { path }) },
        { separator: true },
        { label: "先頭へ移動", onClick: () => store.moveToEdge(group, true) },
        { label: "最後へ移動", onClick: () => store.moveToEdge(group, false) },
        { separator: true },
        { label: "フォルダで表示", onClick: () => void import("../native.ts").then((m) => m.native.reveal(path)) },
      ];
    });
    grid.append(cell);
    cells.set(path, cell);
  }
  // 並べ替えのドロップ先（セルの手前に線）
  registerGridDrop(grid, cells);
  return zone;
}

let unregister: (() => void) | null = null;
function registerGridDrop(grid: HTMLElement, cells: Map<string, HTMLElement>) {
  unregister?.();
  let mark: HTMLElement | null = null;
  const cellAt = (e: PointerEvent) => (document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null)?.closest<HTMLElement>(".cell[data-path]") ?? null;
  unregister = registerDropTarget({
    el: grid,
    accept: (p) => p.kind === "photos",
    over: (_p, e) => { const c = cellAt(e); if (mark !== c) { mark?.classList.remove("dropbefore"); mark = c; mark?.classList.add("dropbefore"); } },
    leave: () => { mark?.classList.remove("dropbefore"); mark = null; },
    drop: (p, e) => { const c = cellAt(e); mark?.classList.remove("dropbefore"); mark = null; if (c) store.movePhotos(p.paths, c.dataset.path!); },
  });
  void cells;
}

// ───────────── V2 ─────────────
function v2Zone() {
  const zone = h("div", { class: "dropzone" });
  const lib = store.p.overlayLibrary;
  if (!lib.length) {
    zone.append(h("div", { class: "empty" },
      h("div", { class: "big" }, "⧉"),
      h("div", { class: "title" }, "ここに V2（重ねる写真）の写真やフォルダをドロップ"),
      h("div", {}, "ロゴ・ワイプ・飾りなど、V1 の写真の上に透明度を付けて重ねる写真のライブラリです"),
      button("写真を追加…", () => void store.openOverlayPanel())));
    return zone;
  }
  const selected = lib.filter((p) => store.overlaySel.has(p));
  const place = (paths: string[]) => { if (!paths.length) return; store.placeOverlays(paths, store.playhead); store.tab = "preview"; store.emit(); };
  zone.append(h("div", { class: "lib-head" },
    h("span", {}, "⧉"), h("b", {}, "V2 ライブラリ"), h("span", { class: "dim" }, `${lib.length} 枚`), h("span", { class: "spacer" }),
    button("タイムラインに置く", () => place(selected), { small: true, disabled: !selected.length, title: "選んだ写真を、再生ヘッドの位置から V2 に置く" }),
    button("外す", () => store.removeOverlayLibrary(selected), { small: true, danger: true, disabled: !selected.length, title: "選んだ写真をライブラリから外す（タイムラインに置いたものも消えます）" }),
    button("写真を追加…", () => void store.openOverlayPanel())));
  zone.append(h("div", { class: "lib-hint" }, "クリック: 選ぶ　Ctrl / ⇧クリック: 複数　ドラッグ: タイムラインの V2 へ置く　ダブルクリック: 再生ヘッドの位置に置く"));
  const grid = h("div", { class: "grid v2" });
  zone.append(grid);
  let anchor: string | null = null;
  for (const path of lib) {
    const used = store.p.overlayClips.filter((c) => c.path === path).length;
    const cell = h("div", { class: `cell${store.overlaySel.has(path) ? " sel" : ""}`, title: basename(path) },
      thumbCanvas(path, true), used ? h("div", { class: "count", title: `タイムラインで ${used} 回使っています` }, String(used)) : null);
    cell.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      const m = mod(e);
      beginDrag(e, () => {
        const group = store.overlaySel.has(path) && store.overlaySel.size >= 2 ? lib.filter((p) => store.overlaySel.has(p)) : [path];
        return { kind: "v2", paths: group };
      }, () => (store.overlaySel.has(path) && store.overlaySel.size >= 2 ? `${store.overlaySel.size} 枚` : basename(path)), () => {
        if (m.meta) { if (store.overlaySel.has(path)) store.overlaySel.delete(path); else store.overlaySel.add(path); anchor = path; }
        else if (m.shift && anchor) { const a = lib.indexOf(anchor), b = lib.indexOf(path); for (let i = Math.min(a, b); i <= Math.max(a, b); i++) store.overlaySel.add(lib[i]); }
        else { store.overlaySel = new Set([path]); anchor = path; }
        store.emit();
      });
    });
    cell.addEventListener("dblclick", () => { store.overlaySel = new Set([path]); place([path]); });
    contextMenu(cell, () => [
      { label: "タイムラインに置く", onClick: () => { if (!store.overlaySel.has(path)) store.overlaySel = new Set([path]); place(lib.filter((p) => store.overlaySel.has(p))); } },
      { label: "ライブラリから外す", danger: true, onClick: () => store.removeOverlayLibrary(store.overlaySel.has(path) ? store.overlaySel : [path]) },
      { label: "フォルダで表示", onClick: () => void import("../native.ts").then((m) => m.native.reveal(path)) },
    ]);
    grid.append(cell);
  }
  return zone;
}
