// CacaoPhotoSlide Windows 版の Rust 側。ファイルの操作と、mp4 書き出し（ffmpeg の起動とフレームの受け渡し）を受け持つ。
// 画面・タイムライン・描画・音声は src/（TypeScript）。書類（.cpsd）の形式は Mac 版と同じ。
use serde::Serialize;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tauri::ipc::{InvokeBody, Request};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::Mutex;

#[cfg(target_os = "windows")]
fn hide_console(cmd: &mut Command) {
    // 黒いコンソール窓を出さない（CREATE_NO_WINDOW）
    cmd.creation_flags(0x0800_0000);
}
#[cfg(not(target_os = "windows"))]
fn hide_console(_cmd: &mut Command) {}

fn exe_name(base: &str) -> String {
    if cfg!(target_os = "windows") { format!("{base}.exe") } else { base.to_string() }
}

// ───────────────────────── ファイル ─────────────────────────

const IMAGE_EXT: [&str; 9] = ["jpg", "jpeg", "png", "gif", "webp", "bmp", "avif", "tif", "tiff"];

fn is_image(p: &Path) -> bool {
    p.extension().and_then(|e| e.to_str()).map(|e| IMAGE_EXT.contains(&e.to_lowercase().as_str())).unwrap_or(false)
}

fn collect(dir: &Path, recursive: bool, out: &mut Vec<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        if name.starts_with('.') { continue; }
        if p.is_dir() {
            // .cpsd などの「書類（フォルダ形式）」の中には入らない
            let ext = p.extension().and_then(|x| x.to_str()).unwrap_or("").to_lowercase();
            if recursive && ext != "cpsd" { collect(&p, recursive, out); }
        } else if is_image(&p) {
            out.push(p.to_string_lossy().to_string());
        }
    }
}

/// フォルダ・ファイルから画像だけを集める（フォルダは recursive なら中まで）
#[tauri::command]
fn list_images(paths: Vec<String>, recursive: bool) -> Vec<String> {
    let mut out = Vec::new();
    for s in paths {
        let p = PathBuf::from(&s);
        if p.is_dir() {
            collect(&p, recursive, &mut out);
        } else if p.is_file() && is_image(&p) {
            out.push(s);
        }
    }
    out
}

/// 撮影日時（EXIF の DateTimeOriginal。なければファイルの作成日）。epoch 秒
#[tauri::command]
fn photo_dates(paths: Vec<String>) -> Vec<f64> {
    paths.iter().map(|s| exif_date(s).unwrap_or_else(|| file_date(s))).collect()
}

fn file_date(path: &str) -> f64 {
    std::fs::metadata(path).ok()
        .and_then(|m| m.created().or_else(|_| m.modified()).ok())
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn exif_date(path: &str) -> Option<f64> {
    let f = std::fs::File::open(path).ok()?;
    let mut r = std::io::BufReader::new(f);
    let ex = exif::Reader::new().read_from_container(&mut r).ok()?;
    let field = ex.get_field(exif::Tag::DateTimeOriginal, exif::In::PRIMARY)
        .or_else(|| ex.get_field(exif::Tag::DateTimeDigitized, exif::In::PRIMARY))?;
    let s = field.display_value().to_string();            // 2026-04-12 10:23:45
    let b: Vec<i64> = s.split(|c: char| !c.is_ascii_digit()).filter(|x| !x.is_empty()).filter_map(|x| x.parse().ok()).collect();
    if b.len() < 6 { return None; }
    // 並べ替え用なので、時差は気にせず UTC として数える
    let (y, m, d) = (b[0], b[1], b[2]);
    let days = days_from_civil(y, m, d);
    Some((days * 86400 + b[3] * 3600 + b[4] * 60 + b[5]) as f64)
}

fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

#[tauri::command]
async fn read_text(path: String) -> Result<String, String> {
    tokio::fs::read_to_string(&path).await.map_err(|e| format!("{}: {}", path, e))
}

#[tauri::command]
async fn write_text(path: String, text: String) -> Result<(), String> {
    if let Some(parent) = Path::new(&path).parent() { let _ = tokio::fs::create_dir_all(parent).await; }
    tokio::fs::write(&path, text).await.map_err(|e| format!("{}: {}", path, e))
}

/// 生のバイト列を書く（ヘッダ x-path に書き先。URL エンコード）
#[tauri::command]
async fn write_bytes(request: Request<'_>) -> Result<(), String> {
    let path = request.headers().get("x-path").and_then(|v| v.to_str().ok()).ok_or("x-path がありません")?.to_string();
    let path = percent_decode(&path);
    let InvokeBody::Raw(bytes) = request.body() else { return Err("バイト列ではありません".into()) };
    if let Some(parent) = Path::new(&path).parent() { let _ = tokio::fs::create_dir_all(parent).await; }
    tokio::fs::write(&path, bytes).await.map_err(|e| format!("{}: {}", path, e))
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) { out.push(v); i += 3; continue; }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

#[tauri::command]
fn path_exists(path: String) -> bool { Path::new(&path).exists() }

#[tauri::command]
fn is_dir(path: String) -> bool { Path::new(&path).is_dir() }

#[tauri::command]
async fn ensure_dir(path: String) -> Result<(), String> {
    tokio::fs::create_dir_all(&path).await.map_err(|e| format!("{}: {}", path, e))
}

#[tauri::command]
async fn copy_file(src: String, dst: String) -> Result<(), String> {
    if let Some(parent) = Path::new(&dst).parent() { let _ = tokio::fs::create_dir_all(parent).await; }
    if Path::new(&dst).exists() { let _ = tokio::fs::remove_file(&dst).await; }
    tokio::fs::copy(&src, &dst).await.map(|_| ()).map_err(|e| format!("{} → {}: {}", src, dst, e))
}

#[tauri::command]
async fn remove_path(path: String) -> Result<(), String> {
    let p = Path::new(&path);
    if p.is_dir() { tokio::fs::remove_dir_all(p).await } else if p.exists() { tokio::fs::remove_file(p).await } else { Ok(()) }
        .map_err(|e| format!("{}: {}", path, e))
}

#[derive(Serialize)]
struct Entry { name: String, is_dir: bool }

#[tauri::command]
fn list_dir(path: String) -> Vec<Entry> {
    let Ok(rd) = std::fs::read_dir(&path) else { return vec![] };
    rd.flatten().map(|e| Entry { name: e.file_name().to_string_lossy().to_string(), is_dir: e.path().is_dir() }).collect()
}

#[tauri::command]
fn temp_dir() -> String { std::env::temp_dir().to_string_lossy().to_string() }

#[tauri::command]
fn documents_dir() -> String {
    dirs::document_dir().or_else(dirs::home_dir).map(|p| p.to_string_lossy().to_string()).unwrap_or_default()
}

/// アプリの設定の置き場所（Windows: %APPDATA%\com.ictcacao.cacaophotoslidewin）
#[tauri::command]
fn app_data_dir(app: AppHandle) -> String {
    app.path().app_data_dir().map(|p| p.to_string_lossy().to_string()).unwrap_or_default()
}

/// 動作確認用の環境変数（CACAOPHOTOSLIDE_DOC など）
#[tauri::command]
fn get_env(name: String) -> Option<String> { std::env::var(name).ok().filter(|s| !s.is_empty()) }

#[tauri::command]
async fn reveal(path: String) -> Result<(), String> {
    let mut cmd = if cfg!(target_os = "windows") {
        let mut c = Command::new("explorer");
        c.arg(format!("/select,{}", path));
        c
    } else if cfg!(target_os = "macos") {
        let mut c = Command::new("open");
        c.arg("-R").arg(&path);
        c
    } else {
        let mut c = Command::new("xdg-open");
        c.arg(Path::new(&path).parent().map(|p| p.to_string_lossy().to_string()).unwrap_or(path.clone()));
        c
    };
    hide_console(&mut cmd);
    cmd.spawn().map_err(|e| e.to_string())?;
    Ok(())
}

// ───────────────────────── ffmpeg ─────────────────────────

fn tools_dir(app: &AppHandle) -> PathBuf {
    app.path().app_local_data_dir().map(|d| d.join("tools")).unwrap_or_else(|_| PathBuf::from("tools"))
}

fn find_in_path(name: &str) -> Option<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).collect()).unwrap_or_default();
    for extra in ["/opt/homebrew/bin", "/usr/local/bin"] { dirs.push(PathBuf::from(extra)); }
    dirs.into_iter().map(|d| d.join(name)).find(|p| p.is_file())
}

fn locate_ffmpeg(app: &AppHandle) -> Option<PathBuf> {
    let name = exe_name("ffmpeg");
    let local = tools_dir(app).join(&name);
    if local.is_file() { return Some(local); }
    find_in_path(&name)
}

#[derive(Serialize, Clone)]
struct ToolsProgress { message: String }

fn emit_progress(app: &AppHandle, msg: impl Into<String>) {
    let _ = app.emit("tools-progress", ToolsProgress { message: msg.into() });
}

#[derive(Serialize)]
struct FfmpegStatus { path: Option<String>, can_install: bool }

#[tauri::command]
fn ffmpeg_status(app: AppHandle) -> FfmpegStatus {
    FfmpegStatus { path: locate_ffmpeg(&app).map(|p| p.to_string_lossy().to_string()), can_install: cfg!(target_os = "windows") }
}

async fn curl_download(app: &AppHandle, url: &str, dest: &Path, label: &str) -> Result<(), String> {
    let mut cmd = Command::new("curl");
    cmd.args(["-L", "--fail", "--silent", "--show-error", "-o"]).arg(dest).arg(url)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    hide_console(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("curl を起動できません: {}", e))?;
    let stderr = child.stderr.take();
    loop {
        tokio::select! {
            st = child.wait() => {
                let st = st.map_err(|e| e.to_string())?;
                if !st.success() {
                    let mut msg = String::new();
                    if let Some(mut e) = stderr { let _ = e.read_to_string(&mut msg).await; }
                    return Err(format!("{} のダウンロードに失敗しました: {}", label, msg.trim()));
                }
                return Ok(());
            }
            _ = tokio::time::sleep(std::time::Duration::from_millis(700)) => {
                if let Ok(m) = tokio::fs::metadata(dest).await {
                    emit_progress(app, format!("{} をダウンロード中… {:.1} MB", label, m.len() as f64 / 1_048_576.0));
                }
            }
        }
    }
}

async fn tar_extract(zip: &Path, member: &str, dest_dir: &Path, strip: usize) -> Result<(), String> {
    let mut cmd = Command::new("tar");
    cmd.arg("-xf").arg(zip).arg("-C").arg(dest_dir).arg("--strip-components").arg(strip.to_string()).arg(member)
        .stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
    hide_console(&mut cmd);
    let out = cmd.output().await.map_err(|e| format!("tar を起動できません: {}", e))?;
    if !out.status.success() {
        return Err(format!("{} を取り出せません: {}", member, String::from_utf8_lossy(&out.stderr).trim()));
    }
    Ok(())
}

/// Windows: ffmpeg を GitHub の公式ビルド（yt-dlp チーム）から落として tools に置く
#[tauri::command]
async fn install_ffmpeg(app: AppHandle) -> Result<FfmpegStatus, String> {
    if !cfg!(target_os = "windows") {
        return Err("この機能は Windows 用です。Mac では brew install ffmpeg を使ってください。".into());
    }
    let dir = tools_dir(&app);
    tokio::fs::create_dir_all(&dir).await.map_err(|e| format!("{}: {}", dir.display(), e))?;
    let zip = dir.join("ffmpeg.zip");
    let arch = if cfg!(target_arch = "aarch64") { "winarm64" } else { "win64" };
    let base = format!("ffmpeg-master-latest-{}-gpl", arch);
    curl_download(&app, &format!("https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/{}.zip", base), &zip, "ffmpeg").await?;
    emit_progress(&app, "ffmpeg を取り出し中…");
    tar_extract(&zip, &format!("{}/bin/ffmpeg.exe", base), &dir, 2).await?;
    let _ = tokio::fs::remove_file(&zip).await;
    emit_progress(&app, "準備ができました");
    Ok(ffmpeg_status(app))
}

// ───────────────────────── mp4 書き出し ─────────────────────────

#[derive(Default)]
struct Exporter {
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    stderr: Option<tokio::task::JoinHandle<String>>,
}

#[derive(Default)]
struct ExportState(Mutex<Exporter>);

/// ffmpeg を起動する。映像は標準入力から RGBA の生のフレームを受け取る。音声は WAV のファイル（任意）
#[tauri::command]
async fn export_begin(state: State<'_, ExportState>, ffmpeg: String, width: u32, height: u32, fps: u32,
                      audio: Option<String>, output: String, crf: u32) -> Result<(), String> {
    let mut ex = state.0.lock().await;
    if ex.child.is_some() { return Err("すでに書き出し中です".into()); }
    let _ = tokio::fs::remove_file(&output).await;
    let mut cmd = Command::new(&ffmpeg);
    cmd.args(["-y", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s"])
        .arg(format!("{}x{}", width, height)).arg("-r").arg(fps.to_string()).args(["-i", "-"]);
    if let Some(a) = &audio { cmd.arg("-i").arg(a); }
    cmd.args(["-map", "0:v"]);
    if audio.is_some() { cmd.args(["-map", "1:a"]); }
    cmd.args(["-c:v", "libx264", "-preset", "medium", "-crf"]).arg(crf.to_string())
        .args(["-pix_fmt", "yuv420p", "-r"]).arg(fps.to_string());
    if audio.is_some() { cmd.args(["-c:a", "aac", "-b:a", "192k", "-shortest"]); }
    cmd.args(["-movflags", "+faststart"]).arg(&output)
        .stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::piped());
    hide_console(&mut cmd);
    let mut child = cmd.spawn().map_err(|e| format!("ffmpeg を起動できません（{}）: {}", ffmpeg, e))?;
    ex.stdin = child.stdin.take();
    let mut err = child.stderr.take();
    ex.stderr = Some(tokio::spawn(async move {
        let mut s = String::new();
        if let Some(e) = err.as_mut() { let _ = e.read_to_string(&mut s).await; }
        s
    }));
    ex.child = Some(child);
    Ok(())
}

/// 1 コマぶんの生のバイト列（RGBA）を ffmpeg に渡す
#[tauri::command]
async fn export_frame(state: State<'_, ExportState>, request: Request<'_>) -> Result<(), String> {
    let InvokeBody::Raw(bytes) = request.body() else { return Err("バイト列ではありません".into()) };
    let mut ex = state.0.lock().await;
    let Some(stdin) = ex.stdin.as_mut() else { return Err("書き出しが始まっていません".into()) };
    stdin.write_all(bytes).await.map_err(|e| format!("ffmpeg に渡せません: {}", e))
}

/// 入力を閉じて、ffmpeg の終わりを待つ。失敗したら ffmpeg の出力を返す
#[tauri::command]
async fn export_end(state: State<'_, ExportState>) -> Result<(), String> {
    let mut ex = state.0.lock().await;
    drop(ex.stdin.take());
    let status = match ex.child.take() { Some(mut c) => c.wait().await.map_err(|e| e.to_string())?, None => return Err("書き出しが始まっていません".into()) };
    let err = match ex.stderr.take() { Some(h) => h.await.unwrap_or_default(), None => String::new() };
    if status.success() { Ok(()) } else { Err(format!("ffmpeg が失敗しました: {}", err.trim())) }
}

#[tauri::command]
async fn export_cancel(state: State<'_, ExportState>) -> Result<(), String> {
    let mut ex = state.0.lock().await;
    drop(ex.stdin.take());
    if let Some(mut c) = ex.child.take() { let _ = c.kill().await; let _ = c.wait().await; }
    ex.stderr.take();
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(ExportState::default())
        .invoke_handler(tauri::generate_handler![
            list_images, photo_dates, read_text, write_text, write_bytes, path_exists, is_dir, ensure_dir, copy_file,
            remove_path, list_dir, temp_dir, documents_dir, app_data_dir, get_env, reveal,
            ffmpeg_status, install_ffmpeg, export_begin, export_frame, export_end, export_cancel
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
