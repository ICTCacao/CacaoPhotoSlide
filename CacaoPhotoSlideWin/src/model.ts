// 書類（.cpsd の project.json）と画面の状態のデータの形。Mac 版（Swift）の ProjectFile と同じキー名で、相互に開ける。

export type Transition = "kenBurns" | "crossfade" | "push" | "zoom" | "none";
export type FitMode = "fit" | "fill";
export type PhotoOrder = "name" | "date" | "random" | "manual";
export type TitleAnchor = "topLeft" | "top" | "topRight" | "left" | "center" | "right" | "bottomLeft" | "bottom" | "bottomRight";
export type TitleEffect = "none" | "fade" | "slideUp" | "slideDown" | "slideLeft" | "slideRight" | "zoom" | "typewriter";
export type TabName = "photos" | "preview" | "settings";

export const TRANSITIONS: { id: Transition; label: string }[] = [
  { id: "kenBurns", label: "Ken Burns（ゆっくり寄る・流れる）" },
  { id: "crossfade", label: "クロスフェード" },
  { id: "push", label: "スライド（横に流す）" },
  { id: "zoom", label: "ズーム" },
  { id: "none", label: "なし（パッと切り替え）" },
];
export const FITS: { id: FitMode; label: string }[] = [
  { id: "fit", label: "全体を表示" },
  { id: "fill", label: "画面いっぱい" },
];
export const ORDERS: { id: PhotoOrder; label: string }[] = [
  { id: "name", label: "名前順" },
  { id: "date", label: "撮影日順" },
  { id: "random", label: "ランダム" },
  { id: "manual", label: "手動" },
];
export const ANCHORS: { id: TitleAnchor; label: string }[] = [
  { id: "topLeft", label: "左上" }, { id: "top", label: "上" }, { id: "topRight", label: "右上" },
  { id: "left", label: "左" }, { id: "center", label: "中央" }, { id: "right", label: "右" },
  { id: "bottomLeft", label: "左下" }, { id: "bottom", label: "下" }, { id: "bottomRight", label: "右下" },
];
export const TITLE_EFFECTS: { id: TitleEffect; label: string }[] = [
  { id: "none", label: "なし（パッと出る）" },
  { id: "fade", label: "フェード" },
  { id: "slideUp", label: "下からスライド" },
  { id: "slideDown", label: "上からスライド" },
  { id: "slideLeft", label: "左からスライド" },
  { id: "slideRight", label: "右からスライド" },
  { id: "zoom", label: "ズームイン" },
  { id: "typewriter", label: "タイプライター（1 文字ずつ）" },
];
export const EXPORT_SIZES: { id: string; label: string; w: number; h: number }[] = [
  { id: "hd720", label: "720p（1280×720）", w: 1280, h: 720 },
  { id: "hd1080", label: "1080p（1920×1080）", w: 1920, h: 1080 },
  { id: "qhd1440", label: "1440p（2560×1440）", w: 2560, h: 1440 },
  { id: "uhd2160", label: "4K（3840×2160）", w: 3840, h: 2160 },
];
/** 表示時間の選択肢（秒） */
export const DWELL_CHOICES = [0.3, 0.5, 0.7, 1, 1.5, 2, 3, 4, 5, 7, 10, 15, 20, 30];

export interface PhotoOverride { dwell?: number; transition?: Transition; fit?: FitMode }

export interface MusicClip {
  id: string; name: string; path: string;
  start: number; duration: number;
  inPoint: number; outPoint?: number;
  track: number; volume: number; fadeIn: number; fadeOut: number;
}

export interface TitleItem {
  id: string; text: string; anchor: TitleAnchor; size: number; color: string; bold: boolean; shadow: boolean;
  fontName: string; start: number; duration: number; effect: TitleEffect; effectDuration: number;
  track: number; offsetX: number; offsetY: number; opacity: number;
}

export interface OverlayClip {
  id: string; path: string; start: number; duration: number;
  opacity: number; scale: number; offsetX: number; offsetY: number;
  fadeIn: number; fadeOut: number; track: number;
  transition?: Transition; fit?: FitMode;
}

export interface TrackSettings { opacity: number; hidden: boolean; volume: number; muted: boolean }

export interface ViewState { tab: TabName; timelineZoom: number; previewHeight: number; playhead: number }

export interface ProjectFile {
  version: number;
  sources: string[]; selection: string[];
  dwell: number; transition: Transition; transitionDuration: number; order: PhotoOrder;
  loop: boolean; recursive: boolean; fit: FitMode; exportSize: string; exportFps: number;
  clips: MusicClip[]; includesPhotos: boolean; excluded: string[]; manualOrder: string[];
  titles: TitleItem[]; overrides: Record<string, PhotoOverride>;
  overlayLibrary: string[]; overlayClips: OverlayClip[];
  trackSettings?: Record<string, TrackSettings>;
  titleTracks?: number; overlayTracks?: number; audioTracks?: number;
  endFade: number; view?: ViewState;
  fullscreenMode?: boolean;           // Windows 版のみ: スライドショーを全画面にするか（false なら窓の中）
}

export function uuid(): string {
  return (globalThis.crypto?.randomUUID?.() ?? `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`).toUpperCase();
}

export function newTitle(over: Partial<TitleItem> = {}): TitleItem {
  return {
    id: uuid(), text: "タイトル", anchor: "bottom", size: 0.07, color: "#FFFFFF", bold: true, shadow: true, fontName: "",
    start: 0, duration: 5, effect: "fade", effectDuration: 0.5, track: 0, offsetX: 0, offsetY: 0, opacity: 1, ...over,
  };
}

export function newOverlay(path: string, start: number, duration: number, track = 0): OverlayClip {
  return { id: uuid(), path, start, duration, opacity: 1, scale: 1, offsetX: 0, offsetY: 0, fadeIn: 0.5, fadeOut: 0.5, track };
}

export function newMusic(name: string, path: string, start: number, duration: number, track = 0): MusicClip {
  return { id: uuid(), name, path, start, duration, inPoint: 0, track, volume: 0.8, fadeIn: 0, fadeOut: 2 };
}

export function defaultProject(): ProjectFile {
  return {
    version: 1, sources: [], selection: [], dwell: 5, transition: "kenBurns", transitionDuration: 1.5, order: "name",
    loop: true, recursive: true, fit: "fit", exportSize: "hd1080", exportFps: 30,
    clips: [], includesPhotos: false, excluded: [], manualOrder: [], titles: [], overrides: {},
    overlayLibrary: [], overlayClips: [], endFade: 0,
  };
}

/** 古い書類や Mac 版の書類で、無い項目を既定で補う */
export function normalizeProject(raw: any): ProjectFile {
  const d = defaultProject();
  const p: ProjectFile = { ...d, ...raw };
  p.titles = (raw.titles ?? []).map((t: any) => ({ ...newTitle(), ...t }));
  p.overlayClips = (raw.overlayClips ?? []).map((c: any) => ({ ...newOverlay("", 0, 5), ...c }));
  p.clips = (raw.clips ?? []).map((c: any) => ({ ...newMusic("", "", 0, 0), ...c }));
  p.overrides = raw.overrides ?? {};
  p.sources = raw.sources ?? [];
  p.selection = raw.selection ?? [];
  p.excluded = raw.excluded ?? [];
  p.manualOrder = raw.manualOrder ?? [];
  p.overlayLibrary = raw.overlayLibrary ?? [];
  return p;
}

export function trackKey(kind: "title" | "overlay" | "audio" | "main", index: number): string {
  switch (kind) {
    case "main": return "V1";
    case "title": return `T${index}`;
    case "overlay": return `O${index}`;
    case "audio": return `A${index}`;
  }
}

export function trackName(kind: "title" | "overlay" | "audio" | "main", index: number): string {
  switch (kind) {
    case "main": return "V1";
    case "title": return `T${index + 1}`;
    case "overlay": return `V${index + 2}`;
    case "audio": return `A${index + 1}`;
  }
}

export const defaultTrackSettings = (): TrackSettings => ({ opacity: 1, hidden: false, volume: 1, muted: false });
