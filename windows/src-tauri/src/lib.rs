//! FocusEdit for Windows (experimental): the Rust side only reads and writes
//! the user's text files and reports a file passed on the command line
//! (double-click / "Open with"). Everything else lives in the web front end.

use std::path::Path;

/// Read a document as text. Invalid UTF-8 is replaced rather than refused,
/// so an old ANSI-encoded file still opens.
#[tauri::command]
fn read_text(path: String) -> Result<String, String> {
    let bytes = std::fs::read(&path).map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

/// Write a document as UTF-8 (the front end keeps the original BOM and line endings).
#[tauri::command]
fn write_text(path: String, text: String) -> Result<(), String> {
    std::fs::write(&path, text).map_err(|e| e.to_string())
}

/// The first command-line argument that is an existing file, if any.
#[tauri::command]
fn startup_file() -> Option<String> {
    std::env::args()
        .skip(1)
        .find(|arg| !arg.starts_with('-') && Path::new(arg).is_file())
}

/// Open a web address in the default browser. Only plain http(s) addresses are
/// accepted, so a link in a document cannot make the app launch anything else.
#[tauri::command]
fn open_url(url: String) -> Result<(), String> {
    let web = url.starts_with("https://") || url.starts_with("http://");
    if !web || url.chars().any(|c| c.is_whitespace() || c.is_control()) {
        return Err("only http(s) addresses can be opened".into());
    }
    #[cfg(target_os = "windows")]
    let mut command = std::process::Command::new("explorer.exe");
    #[cfg(target_os = "macos")]
    let mut command = std::process::Command::new("open");
    #[cfg(all(unix, not(target_os = "macos")))]
    let mut command = std::process::Command::new("xdg-open");
    command.arg(&url).spawn().map(|_| ()).map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![read_text, write_text, startup_file, open_url])
        .run(tauri::generate_context!())
        .expect("error while running FocusEdit");
}
