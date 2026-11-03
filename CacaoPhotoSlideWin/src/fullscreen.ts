// 全画面（または窓いっぱい）のスライドショー。Space で止める／動かす、← → で前へ／次へ、Esc で終わる。
import { h } from "./dom.ts";
import { Player } from "./player.ts";
import { store } from "./store.ts";

let active: { close: () => void } | null = null;
export const isShowing = () => active !== null;

export async function startSlideshow(fromPath?: string) {
  if (active || !store.photos.length) return;
  store.audio.stop();
  const wasTab = store.tab;
  const scene = store.scene();
  const player = new Player();
  player.loop = store.p.loop;
  let hudTimer = 0;

  const canvas = h("canvas") as HTMLCanvasElement;
  const hud = h("div", { class: "hud", style: { display: "none" } });
  const root = h("div", { class: "fs hidecursor" }, canvas, hud);
  document.body.append(root);

  const fullscreen = store.p.fullscreenMode !== false;
  let appWindow: any = null;
  if (fullscreen) {
    try { const { getCurrentWindow } = await import("@tauri-apps/api/window"); appWindow = getCurrentWindow(); await appWindow.setFullscreen(true); } catch { /* 窓のまま */ }
  }

  const fit = () => {
    const dpr = window.devicePixelRatio || 1;
    const w = Math.max(2, Math.round(root.clientWidth * dpr)), hh = Math.max(2, Math.round(root.clientHeight * dpr));
    // 画面の縦横比のまま描く（16:9 でない画面では、写真が画面いっぱいになる）
    if (canvas.width !== w || canvas.height !== hh) { canvas.width = w; canvas.height = hh; }
    player.maxPixel = Math.min(8192, Math.round(Math.max(w, hh) * 1.3));
  };
  fit();
  const onResize = () => { fit(); if (!player.playing) player.draw(); };
  window.addEventListener("resize", onResize);
  player.attach(canvas);

  const showHud = (pause: boolean) => {
    const tm = scene.timing;
    const k = tm.index(player.time);
    hud.replaceChildren(
      pause ? h("span", { style: { fontWeight: "600" } }, "⏸ 一時停止") : "",
      h("span", {}, `${k + 1} / ${tm.count}`),
      h("span", { class: "dim" }, scene.paths[k]?.split(/[\\/]/).pop() ?? ""),
    );
    hud.style.display = "flex";
    clearTimeout(hudTimer);
    if (!pause) hudTimer = window.setTimeout(() => (hud.style.display = "none"), 1800);
  };

  const jump = (t: number) => {
    player.time = t;
    if (player.playing) player.seek(t); else { player.draw(); }
  };
  const goto = (delta: number) => {
    const tm = scene.timing;
    let k = tm.index(player.time) + delta;
    if (delta < 0 && player.time > tm.starts[tm.index(player.time)] + 0.5) k = tm.index(player.time);
    if (k < 0) k = store.p.loop ? tm.count - 1 : 0;
    if (k >= tm.count) k = store.p.loop ? 0 : tm.count - 1;
    store.images.request(scene.paths[k], player.maxPixel).then(() => { jump(tm.starts[k]); showHud(!player.playing); });
  };

  const close = async () => {
    clearTimeout(hudTimer);
    player.pause();
    window.removeEventListener("keydown", onKey, true);
    window.removeEventListener("resize", onResize);
    root.remove();
    active = null;
    if (appWindow) { try { await appWindow.setFullscreen(false); } catch { /* なし */ } }
    store.tab = wasTab;
    store.playhead = 0;
    store.emit();
  };
  player.onEnd = () => void close();

  const onKey = (e: KeyboardEvent) => {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    switch (e.key) {
      case " ": e.preventDefault(); e.stopPropagation(); player.toggle(); showHud(!player.playing); break;
      case "ArrowLeft": case "ArrowUp": case "PageUp": e.preventDefault(); e.stopPropagation(); goto(-1); break;
      case "ArrowRight": case "ArrowDown": case "PageDown": e.preventDefault(); e.stopPropagation(); goto(1); break;
      case "Escape": case "q": case "Q": e.preventDefault(); e.stopPropagation(); void close(); break;
    }
  };
  window.addEventListener("keydown", onKey, true);
  root.addEventListener("dblclick", () => void close());

  active = { close: () => void close() };
  // 最初の写真を読んでから流す
  const start = fromPath ? Math.max(0, scene.paths.indexOf(fromPath)) : 0;
  await store.images.request(scene.paths[start], player.maxPixel);
  player.scene0(scene);
  player.play(scene.timing.starts[start]);
}
