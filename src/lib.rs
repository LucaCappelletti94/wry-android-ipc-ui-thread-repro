use std::time::Instant;

/// On Android the UI thread is the process's first thread, so its id equals the process id.
fn on_ui_thread() -> bool {
  std::fs::read_link("/proc/thread-self")
    .ok()
    .and_then(|path| path.file_name()?.to_str()?.parse::<u32>().ok())
    .is_some_and(|tid| tid == std::process::id())
}

/// Synchronous, so Tauri runs it on whichever thread calls wry's IPC handler.
#[tauri::command]
fn read_url(webview: tauri::Webview) -> String {
  println!("REPRO read_url started, on_ui_thread={}", on_ui_thread());
  let start = Instant::now();
  let url = webview.url();
  let line = format!(
    "REPRO read_url returned after {} ms, ok={}",
    start.elapsed().as_millis(),
    url.is_ok()
  );
  println!("{line}");
  line
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
  let builder = tauri::Builder::default().invoke_handler(tauri::generate_handler![read_url]);
  // wry calls Tauri's page load handler from `onPageStarted` and `onPageFinished` on the UI thread.
  #[cfg(feature = "page-load")]
  let builder = builder.on_page_load(|webview, _| {
    println!("REPRO on_page_load started, on_ui_thread={}", on_ui_thread());
    let start = Instant::now();
    let url = webview.url();
    println!(
      "REPRO on_page_load returned after {} ms, ok={}",
      start.elapsed().as_millis(),
      url.is_ok()
    );
  });
  builder
    .run(tauri::generate_context!())
    .expect("error while running tauri application");
}
