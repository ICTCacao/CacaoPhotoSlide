// 画面の中のドラッグ（写真の並べ替え・V2 ライブラリからタイムラインへ）。HTML5 のドラッグ＆ドロップは、
// Windows の WebView2 でファイルのドロップと衝突するので、ポインタのイベントで自前で行う。
import { h } from "./dom.ts";

export interface DragPayload { kind: "photos" | "v2"; paths: string[] }
export interface DropTarget { el: HTMLElement; accept: (p: DragPayload, e: PointerEvent) => boolean; over?: (p: DragPayload, e: PointerEvent, el: HTMLElement) => void; drop: (p: DragPayload, e: PointerEvent, el: HTMLElement) => void; leave?: (el: HTMLElement) => void }

const targets = new Set<DropTarget>();
export function registerDropTarget(t: DropTarget) { targets.add(t); return () => targets.delete(t); }

/** ポインタを 5px 動かしたらドラッグが始まる。start は pointerdown で呼ぶ。動かなければ、ふつうのクリック */
export function beginDrag(e: PointerEvent, payload: () => DragPayload, label: () => string, onClickOnly?: () => void) {
  const sx = e.clientX, sy = e.clientY;
  let ghost: HTMLElement | null = null;
  let current: DropTarget | null = null;
  let data: DragPayload | null = null;
  const pick = (ev: PointerEvent): DropTarget | null => {
    const under = document.elementFromPoint(ev.clientX, ev.clientY);
    if (!under || !data) return null;
    for (const t of targets) if (t.el.contains(under) && t.accept(data, ev)) return t;
    return null;
  };
  const move = (ev: PointerEvent) => {
    if (!ghost) {
      if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 5) return;
      data = payload();
      ghost = h("div", { class: "drag-ghost" }, label());
      document.body.append(ghost);
    }
    ghost.style.left = `${ev.clientX + 12}px`;
    ghost.style.top = `${ev.clientY + 12}px`;
    const t = pick(ev);
    if (t !== current) { if (current) current.leave?.(current.el); current = t; }
    if (t && data) t.over?.(data, ev, t.el);
  };
  const up = (ev: PointerEvent) => {
    window.removeEventListener("pointermove", move, true);
    window.removeEventListener("pointerup", up, true);
    window.removeEventListener("pointercancel", up, true);
    if (!ghost) { onClickOnly?.(); return; }
    ghost.remove();
    const t = pick(ev);
    if (current) current.leave?.(current.el);
    if (t && data) t.drop(data, ev, t.el);
    // ドラッグのあとのクリックを無視させる
    const swallow = (c: MouseEvent) => { c.stopPropagation(); c.preventDefault(); };
    window.addEventListener("click", swallow, { capture: true, once: true });
    setTimeout(() => window.removeEventListener("click", swallow, true), 50);
  };
  window.addEventListener("pointermove", move, true);
  window.addEventListener("pointerup", up, true);
  window.addEventListener("pointercancel", up, true);
}
