// 画面の骨組み: タブ、下の固定バー、ファイル操作、ドロップ、キー操作。
import { button, h } from "./dom.ts";
import { isShowing, startSlideshow } from "./fullscreen.ts";
import { player } from "./player.ts";
import { store } from "./store.ts";
import { closeSheet, renderSheet, openSheet } from "./sheets.ts";
import { paintThumbs, renderPhotos } from "./views/photos.ts";
import { renderSettings } from "./views/settings.ts";
import { renderTimeline, handleExternalDrop } from "./views/timeline.ts";
import { isAbsolute, isAudioPath, isImagePath, native } from "./native.ts";

const TAB_LABELS = { photos: "写真", preview: "タイムライン", settings: "設定" } as const;

export async function mountApp(root: HTMLElement) {
  const tabs = h("div", { class: "tabs" });
  const files = h("div", { style: { position: "absolute", right: "18px", top: "10px", display: "flex", gap: "6px" } });
  const content = h("div", { class: "content" });
  const pane = h("div", { class: "pane" });
  content.append(pane);
  const footer = h("div", { class: "footer" });
  const sheetRoot = h("div", {});
  root.append(h("div", { style: { position: "relative" } }, tabs, files), content, footer, sheetRoot);

  let lastTab = store.tab;
  const render = () => {
    // タブ
    tabs.replaceChildren(h("div", { class: "seg" }, (Object.keys(TAB_LABELS) as (keyof typeof TAB_LABELS)[]).map((k) =>
      h("button", { class: store.tab === k ? "on" : "", onClick: () => { if (player.playing) player.pause(); store.tab = k; store.emit(); } }, TAB_LABELS[k]))));
    files.replaceChildren(
      button("新規", () => store.newDocument(), { small: true }),
      button("開く…", () => void store.openDocumentPanel(), { small: true }),
      button("保存", () => void store.saveDocument(), { small: true }),
      button("別名で保存…", () => void store.saveDocumentAs(), { small: true }));
    document.title = `${store.documentTitle} — CacaoPhotoSlide`;
    if (lastTab === "preview" && store.tab !== "preview" && player.playing) player.pause();
    lastTab = store.tab;
    // 中身
    if (store.tab === "photos") renderPhotos(pane);
    else if (store.tab === "preview") renderTimeline(pane);
    else renderSettings(pane);
    // 下の固定バー
    footer.replaceChildren(
      h("div", { class: "hint" }, h("div", {}, "Space  停止 / 再開　　←  →  前へ / 次へ"), h("div", {}, "Esc  終了　　右クリックで、トラックの追加・設定"),
        store.saving ? h("div", { style: { color: "var(--accent)" } }, store.saving) : null),
      button("mp4 に書き出す…", () => openSheet("export", {}), { disabled: !store.photos.length || store.scanning }),
      button("▶ スライドショーを開始", () => void startSlideshow([...store.selection][0]), { primary: true, disabled: !store.photos.length || store.scanning }));
    renderSheet(sheetRoot);
  };
  store.subscribe(render);
  store.onLiveChange = () => player.refreshLive();
  store.thumbs.onLoad = (() => {
    let q = false, e = 0;
    return () => {
      if (!q) { q = true; requestAnimationFrame(() => { q = false; paintThumbs(document.body); }); }
      // タイムラインのサムネイルは、読み込めたものから描き直す（まとめて、少し間をおいて）
      if (store.tab === "preview" && !e) e = window.setTimeout(() => { e = 0; if (!player.playing) store.emit(); }, 250);
    };
  })();

  // ───── キー操作 ─────
  window.addEventListener("keydown", (e) => {
    if (isShowing()) return;
    const t = e.target as HTMLElement | null;
    const typing = !!t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.tagName === "SELECT" || t.isContentEditable);
    const ctrl = e.ctrlKey || e.metaKey;
    if (ctrl && e.key.toLowerCase() === "s") { e.preventDefault(); void (e.shiftKey ? store.saveDocumentAs() : store.saveDocument()); return; }
    if (ctrl && e.key.toLowerCase() === "o") { e.preventDefault(); void store.openDocumentPanel(); return; }
    if (ctrl && e.key.toLowerCase() === "n") { e.preventDefault(); store.newDocument(); return; }
    if (ctrl && e.key === "1") { store.tab = "photos"; store.emit(); return; }
    if (ctrl && e.key === "2") { store.tab = "preview"; store.emit(); return; }
    if (ctrl && e.key === "3") { store.tab = "settings"; store.emit(); return; }
    if (ctrl && e.key === "Enter") { void startSlideshow(); return; }
    if (typing || store.sheet) { if (e.key === "Escape" && store.sheet) closeSheet(); return; }
    if (store.tab === "preview" && e.key === " ") {
      e.preventDefault();
      if (store.p.titles.length || true) player.toggle();
      store.emit();
      return;
    }
    if (e.key === "Delete" || e.key === "Backspace") {
      if (store.tab === "preview") {
        if (store.selOverlays.size) { store.removeSelectedOverlays(); return; }
        if (store.selTitles.size) { store.removeTitles(store.selTitles); return; }
        if (store.selClip) { store.removeClip(store.selClip); return; }
      } else if (store.tab === "photos" && store.selection.size) store.removePhotos([...store.selection]);
    }
    if (e.key === "Escape") { store.selection.clear(); store.selOverlays.clear(); store.selTitles.clear(); store.timelineSel.clear(); store.emit(); }
  });

  // ───── ファイルのドロップ（Tauri が窓の外から運んでくる）─────
  try {
    const { getCurrentWebview } = await import("@tauri-apps/api/webview");
    await getCurrentWebview().onDragDropEvent(async (ev) => {
      const pl: any = ev.payload;
      const zone = document.querySelector(".dropzone");
      if (pl.type === "over" || pl.type === "enter") zone?.classList.add("target");
      else if (pl.type === "leave") zone?.classList.remove("target");
      else if (pl.type === "drop") {
        zone?.classList.remove("target");
        const paths: string[] = pl.paths ?? [];
        const dpr = window.devicePixelRatio || 1;
        const x = (pl.position?.x ?? 0) / dpr, y = (pl.position?.y ?? 0) / dpr;
        if (store.tab === "preview" && (await handleExternalDrop(paths, x, y))) return;
        if (store.tab === "photos" && store.libraryMode === "v2") { await store.addOverlayPhotos(paths.filter((p) => !isAudioPath(p))); return; }
        await store.load(paths);
      }
    });
  } catch { /* ブラウザで開いているときなど */ }

  // ───── 動作確認の仕掛け（環境変数）─────
  const doc = await native.getEnv("CACAOPHOTOSLIDE_DOC").catch(() => null);
  if (doc) await store.openDocument(doc); else await store.restoreLast();
  render();
  // 動作確認用: 環境変数 CACAOPHOTOSLIDE_JS に JavaScript のファイルを指定すると、読み込みのあとで実行する（画面にイベントを送って、操作を試せる）
  (window as any).__cps = { store, player, openSheet, closeSheet, startSlideshow, native };
  const js = await native.getEnv("CACAOPHOTOSLIDE_JS").catch(() => null);
  if (js) {
    try { const code = await native.readText(js); setTimeout(() => { try { new Function(code)(); } catch (e) { document.title = `JS ERROR ${e}`; } }, 1500); } catch { /* なし */ }
  }
  // 書き出しの自動テスト: 環境変数 CACAOPHOTOSLIDE_EXPORT=<mp4 の保存先>。終わったら <保存先>.status に結果を書く
  const exp = await native.getEnv("CACAOPHOTOSLIDE_EXPORT").catch(() => null);
  if (exp) {
    const { exportMovie } = await import("./exporter.ts");
    const job = { cancelled: false, progress: 0, message: "", state: "running" as "running" | "done" | "failed" | "cancelled", output: undefined as string | undefined };
    await exportMovie(exp, job, () => {});
    await native.writeText(`${exp}.status`, `${job.state}: ${job.message}`);
  }
  if ((await native.getEnv("CACAOPHOTOSLIDE_PLAY").catch(() => null)) === "1") { store.tab = "preview"; store.emit(); setTimeout(() => { player.play(0); store.emit(); }, 800); }
  const tab = await native.getEnv("CACAOPHOTOSLIDE_TAB").catch(() => null);
  if (tab === "photos" || tab === "preview" || tab === "settings") { store.tab = tab; store.emit(); }
  const sheet = await native.getEnv("CACAOPHOTOSLIDE_SHEET").catch(() => null);
  if (sheet) setTimeout(() => { if (sheet === "titles") { store.selTitles = new Set(store.p.titles.slice(0, 1).map((t) => t.id)); openSheet("titles", {}); } else if (sheet === "overlay") openSheet("overlay", { id: store.p.overlayClips[0]?.id }); else if (sheet === "export") openSheet("export", {}); }, 1200);
  void isAbsolute; void isImagePath;
}
