// 画面づくりの小道具: 要素の作成、右クリックメニュー、数値の入力欄など。
export type Child = Node | string | null | undefined | false;

export function h<K extends keyof HTMLElementTagNameMap>(tag: K, props: Record<string, any> = {}, ...children: (Child | Child[])[]): HTMLElementTagNameMap[K] {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
    else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2).toLowerCase(), v);
    else if (k === "value") (el as any).value = v;
    else if (k === "checked" || k === "disabled" || k === "selected") (el as any)[k] = !!v;
    else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, String(v));
  }
  for (const c of children.flat()) { if (c === null || c === undefined || c === false) continue; el.append(c instanceof Node ? c : document.createTextNode(c)); }
  return el;
}

export const clear = (el: Element) => { while (el.firstChild) el.removeChild(el.firstChild); };
export const fmt = (s: number) => { const t = Math.max(0, Math.round(s)); return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`; };
export const fmtSec = (v: number) => (v === Math.round(v) ? `${v} 秒` : `${v.toFixed(1)} 秒`);
export const round1 = (v: number) => Math.round(v * 10) / 10;

// ───── 右クリックメニュー ─────
export interface MenuItem { label?: string; onClick?: () => void; disabled?: boolean; danger?: boolean; separator?: boolean }

let openMenu: HTMLElement | null = null;
export function closeMenu() { openMenu?.remove(); openMenu = null; }

export function showMenu(x: number, y: number, items: MenuItem[]) {
  closeMenu();
  const m = h("div", { class: "menu" });
  for (const it of items) {
    if (it.separator) { m.append(h("div", { class: "menu-sep" })); continue; }
    const row = h("div", { class: `menu-item${it.disabled ? " disabled" : ""}${it.danger ? " danger" : ""}` }, it.label ?? "");
    if (!it.disabled) row.addEventListener("click", () => { closeMenu(); it.onClick?.(); });
    m.append(row);
  }
  document.body.append(m);
  const r = m.getBoundingClientRect();
  m.style.left = `${Math.min(x, window.innerWidth - r.width - 6)}px`;
  m.style.top = `${Math.min(y, window.innerHeight - r.height - 6)}px`;
  openMenu = m;
  setTimeout(() => {
    const off = (e: Event) => { if (!m.contains(e.target as Node)) { closeMenu(); window.removeEventListener("pointerdown", off, true); window.removeEventListener("blur", off, true); } };
    window.addEventListener("pointerdown", off, true);
    window.addEventListener("blur", off, true);
  });
}

export function contextMenu(el: HTMLElement, build: (e: MouseEvent) => MenuItem[]) {
  el.addEventListener("contextmenu", (e) => { e.preventDefault(); e.stopPropagation(); showMenu(e.clientX, e.clientY, build(e)); });
}

// ───── 入力欄 ─────
/** 数値の入力欄（Enter か、他へ移ったとき確定） */
export function numField(value: number, onChange: (v: number) => void, opts: { width?: number; step?: number; min?: number; max?: number; disabled?: boolean; digits?: number } = {}) {
  const input = h("input", { type: "number", class: "num", value: String(round(value, opts.digits ?? 2)), step: opts.step ?? 0.1, min: opts.min, max: opts.max, disabled: opts.disabled, style: { width: `${opts.width ?? 64}px` } });
  const commit = () => { const v = parseFloat(input.value); if (Number.isFinite(v)) onChange(v); };
  input.addEventListener("change", commit);
  input.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter") commit(); });
  return input;
}
export const round = (v: number, d: number) => { const p = 10 ** d; return Math.round(v * p) / p; };

/** 割合（0〜1）を % で入力する欄 */
export function pctField(value: number, onChange: (v: number) => void, range: [number, number] = [0, 1], opts: { disabled?: boolean } = {}) {
  const input = h("input", { type: "number", class: "num", value: String(round(value * 100, 1)), step: 0.5, disabled: opts.disabled, style: { width: "62px" } });
  const commit = () => { const v = parseFloat(input.value); if (Number.isFinite(v)) onChange(Math.min(range[1], Math.max(range[0], v / 100))); };
  input.addEventListener("change", commit);
  input.addEventListener("keydown", (e) => { e.stopPropagation(); if (e.key === "Enter") commit(); });
  return h("span", { class: "pct" }, input, h("span", { class: "unit" }, "%"));
}

export function slider(value: number, min: number, max: number, step: number, onInput: (v: number) => void, opts: { disabled?: boolean; width?: number } = {}) {
  const s = h("input", { type: "range", min, max, step, value: String(value), disabled: opts.disabled, style: opts.width ? { width: `${opts.width}px` } : {} });
  s.addEventListener("input", () => onInput(parseFloat(s.value)));
  return s;
}

export function select<T extends string>(options: { id: T; label: string }[], value: T, onChange: (v: T) => void, opts: { disabled?: boolean } = {}) {
  const s = h("select", { disabled: opts.disabled }, options.map((o) => h("option", { value: o.id, selected: o.id === value }, o.label)));
  s.addEventListener("change", () => onChange(s.value as T));
  return s;
}

export function checkbox(label: string, checked: boolean, onChange: (v: boolean) => void, opts: { disabled?: boolean } = {}) {
  const c = h("input", { type: "checkbox", checked, disabled: opts.disabled });
  c.addEventListener("change", () => onChange(c.checked));
  return h("label", { class: "check" }, c, h("span", {}, label));
}

export function button(label: string, onClick: () => void, opts: { primary?: boolean; disabled?: boolean; danger?: boolean; title?: string; small?: boolean; icon?: boolean } = {}) {
  return h("button", { class: `btn${opts.primary ? " primary" : ""}${opts.danger ? " danger" : ""}${opts.small ? " small" : ""}${opts.icon ? " icon" : ""}`, disabled: opts.disabled, title: opts.title, onClick }, label);
}

/** 修飾キー */
export const mod = (e: MouseEvent | PointerEvent | KeyboardEvent) => ({ meta: e.metaKey || e.ctrlKey, shift: e.shiftKey });

/** 行（ラベル + 内容）。設定の画面の見出しと値の並び */
export function row(label: Child, ...content: Child[]) { return h("div", { class: "row" }, h("div", { class: "row-label" }, label), h("div", { class: "row-body" }, ...content)); }
