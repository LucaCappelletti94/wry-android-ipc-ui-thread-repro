# wry Android: calling the IPC handler on the UI thread deadlocks sync commands

[![wry PR](https://img.shields.io/badge/tauri--apps%2Fwry-%231891-blue)](https://github.com/tauri-apps/wry/pull/1891)
[![Tauri](https://img.shields.io/badge/tauri-2.12.4-24c8db)](https://crates.io/crates/tauri/2.12.4)
[![Android](https://img.shields.io/badge/Android-API%2035-3ddc84)](https://developer.android.com/about/versions/15)

Reproducer for [this review thread](https://github.com/tauri-apps/wry/pull/1891#discussion_r4344062304) on [tauri-apps/wry#1891](https://github.com/tauri-apps/wry/pull/1891). The app is a stock Tauri 2.12.4 app whose page calls one synchronous command, [`read_url`](src/lib.rs), when it loads. The command calls `webview.url()` and logs which thread it ran on and how long the call took.

| Variant | wry | Where `Rust.ipc` runs |
|---|---|---|
| `dev` | [`6642074`](https://github.com/tauri-apps/wry/tree/6642074224a2db9eb197f69d21b300b02b5dcd49), the PR's merge base | JavaBridge thread, from `postMessage` |
| `pr` | [`0c95f9a`](https://github.com/LucaCappelletti94/wry/tree/0c95f9a3577c4e5b9e9b6fc6ea69597dd772d272), the PR head | background executor, from the message listener |
| `inline` | the PR head with [`inline.patch`](variants/inline.patch) | UI thread, from the message listener |

`inline.patch` is the [variant measured in the PR](https://github.com/tauri-apps/wry/pull/1891#issuecomment-6319812281), which drops the executor and passes `webView.url`.

## Run

Requires the [Tauri Android prerequisites](https://tauri.app/start/prerequisites/#android) and one emulator or device.

```sh
ANDROID_SERIAL=emulator-5554 ./repro.sh inline   # also dev or pr, optional run count (3)
```

The build targets `x86_64`. Set `TARGET=aarch64` for a phone.

## Why it deadlocks

Tauri [runs a sync command inside the IPC handler](https://github.com/tauri-apps/tauri/blob/tauri-macros-v2.7.4/crates/tauri-macros/src/command/wrapper.rs#L398-L429), so in `inline` it runs on the UI thread. `webview.url()` [waits for the event loop thread](https://github.com/tauri-apps/tauri/blob/tauri-runtime-wry-v2.12.3/crates/tauri-runtime-wry/src/lib.rs#L196-L203), which calls [wry's `url()`](https://github.com/tauri-apps/wry/blob/0c95f9a3577c4e5b9e9b6fc6ea69597dd772d272/src/android/mod.rs#L347-L348). That posts `GetUrl` to the main pipe and waits up to 10 s, and only the blocked UI thread drains the main pipe. After the timeout the UI thread drains the stale `GetUrl`, whose reply goes to a dropped receiver, and [the `unwrap` in `main_pipe.rs`](https://github.com/tauri-apps/wry/blob/0c95f9a3577c4e5b9e9b6fc6ea69597dd772d272/src/android/main_pipe.rs#L413) aborts the process.

A handler that never waits on the UI thread, such as an async command or a sync command that does not touch the webview, does not freeze.

## Results

Android 15 x86_64 emulator, WebView 124.0.6367.219, debug builds, cold start per run.

| Variant | `read_url` thread | `webview.url()` | Outcome |
|---|---|---|---|
| `dev` | not the UI thread | 0–2 ms | 5 of 5 returned |
| `pr` | not the UI thread | 0–8 ms | 5 of 5 returned |
| `inline` | UI thread | 10 000 ms, then error | 5 of 5 crashed |

One `inline` run:

```
run 1: crashed
  10-22 09:44:54.896 REPRO read_url started, on_ui_thread=true
  10-22 09:45:04.897 REPRO read_url returned after 10000 ms, ok=false
  10-22 09:45:04.899 thread '<unnamed>' (29722) panicked at .wry-inline/src/android/main_pipe.rs:413:24:
  10-22 09:45:04.899 called `Result::unwrap()` on an `Err` value: "SendError(..)"
```
