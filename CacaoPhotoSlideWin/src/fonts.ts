// フォントの一覧。Chromium（WebView2）の queryLocalFonts で、入っているものを取る。取れなければ、よく使うものを並べる。
const COMMON = ["Yu Gothic UI", "Yu Gothic", "Yu Mincho", "Meiryo", "Meiryo UI", "MS Gothic", "MS PGothic", "MS Mincho", "MS PMincho", "BIZ UDGothic", "BIZ UDMincho",
  "UD Digi Kyokasho N-R", "HGP創英角ポップ体", "Hiragino Sans", "Hiragino Mincho ProN", "Hiragino Maru Gothic ProN", "Arial", "Segoe UI", "Times New Roman", "Georgia", "Verdana", "Impact"];
const RECOMMENDED = ["Yu Gothic UI", "Yu Gothic", "Yu Mincho", "Meiryo", "BIZ UDGothic", "BIZ UDMincho", "Hiragino Sans", "Hiragino Mincho ProN", "Hiragino Maru Gothic ProN", "Arial", "Georgia"];

let cache: { recommended: string[]; all: string[] } | null = null;

export async function listFonts(): Promise<{ recommended: string[]; all: string[] }> {
  if (cache) return cache;
  let families: string[] = [];
  try {
    const q = (window as any).queryLocalFonts;
    if (q) { const fonts: { family: string }[] = await q.call(window); families = [...new Set(fonts.map((f) => f.family))]; }
  } catch { /* 許可されなかった */ }
  if (!families.length) families = COMMON;
  families.sort((a, b) => a.localeCompare(b, "ja"));
  cache = { recommended: RECOMMENDED.filter((f) => families.includes(f)), all: families };
  return cache;
}
