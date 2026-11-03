// 「設定」のタブ: スライドショー全体の設定。写真ごと・トラックごとの設定は、それぞれの編集の画面で。
import { DWELL_CHOICES, FITS, ORDERS, TRANSITIONS } from "../model.ts";
import { button, checkbox, fmtSec, h, row, select, slider } from "../dom.ts";
import { openSheet } from "../sheets.ts";
import { store } from "../store.ts";

function seg<T extends string>(options: { id: T; label: string }[], value: T, onChange: (v: T) => void) {
  return h("div", { class: "seg" }, options.map((o) => h("button", { class: o.id === value ? "on" : "", onClick: () => onChange(o.id) }, o.label)));
}

export function renderSettings(pane: HTMLElement) {
  pane.replaceChildren();
  const p = store.p;
  const idx = DWELL_CHOICES.reduce((best, v, i) => (Math.abs(v - p.dwell) < Math.abs(DWELL_CHOICES[best] - p.dwell) ? i : best), 0);
  const dwellLabel = h("span", { class: "unit", style: { width: "56px", textAlign: "right" } }, fmtSec(p.dwell));
  const trLabel = h("span", { class: "unit", style: { width: "56px", textAlign: "right" } }, fmtSec(Math.min(p.transitionDuration, p.dwell)));
  const efLabel = h("span", { class: "unit", style: { width: "56px", textAlign: "right" } }, p.endFade === 0 ? "なし" : fmtSec(p.endFade));
  const box = h("div", { style: { maxWidth: "760px", margin: "0 auto" } },
    row("表示時間", slider(idx, 0, DWELL_CHOICES.length - 1, 1, (v) => { const d = DWELL_CHOICES[Math.round(v)]; dwellLabel.textContent = fmtSec(d); store.set("dwell", d); }), dwellLabel),
    row("切り替え", select(TRANSITIONS, p.transition, (v) => store.set("transition", v))),
    row("切り替えの長さ", slider(p.transitionDuration, 0.3, 3, 0.1, (v) => { trLabel.textContent = fmtSec(Math.min(v, p.dwell)); store.set("transitionDuration", Math.round(v * 10) / 10); }, { disabled: p.transition === "none" }), trLabel),
    row("最後のフェードアウト", slider(p.endFade, 0, 10, 0.5, (v) => { efLabel.textContent = v === 0 ? "なし" : fmtSec(v); store.set("endFade", v); }), efLabel),
    row("順番", seg(ORDERS, p.order, (v) => { store.setOrder(v); })),
    row("表示", seg(FITS, p.fit, (v) => store.set("fit", v))),
    row("表示先", seg([{ id: "full", label: "全画面" }, { id: "win", label: "窓の中" }], p.fullscreenMode === false ? "win" : "full", (v) => store.set("fullscreenMode", v === "full"))),
    row("", checkbox("繰り返す", p.loop, (v) => store.set("loop", v)), checkbox("サブフォルダも含める", p.recursive, (v) => store.setRecursive(v))),
    row("タイトルなど", h("span", { class: "dim" }, p.titles.length ? `${p.titles.length} 件` : "なし"), button("編集…", () => openSheet("titles", {}))),
  );
  void checkbox;
  pane.append(box);
}
