# wry Android: Tauri webview getters called on the UI thread deadlock

[![wry PR](https://img.shields.io/badge/tauri--apps%2Fwry-%231891-blue)](https://github.com/tauri-apps/wry/pull/1891)
[![Tauri](https://img.shields.io/badge/tauri-2.12.4-24c8db)](https://crates.io/crates/tauri/2.12.4)
[![wry](https://img.shields.io/badge/wry-0.57.0-blue)](https://crates.io/crates/wry/0.57.0)
[![Android](https://img.shields.io/badge/Android-API%2035-3ddc84)](https://developer.android.com/about/versions/15)

A stock Tauri 2.12.4 app that calls `webview.url()` from two places and logs which thread each call ran on and how long it took.

- `command` mode: the page calls the synchronous command [`read_url`](src/lib.rs) when it loads.
- `page-load` mode: [`on_page_load`](src/lib.rs) also calls it, from wry's `onPageStarted` on the UI thread.

| Variant | wry | Where `Rust.ipc` runs |
|---|---|---|
| `release` | 0.57.0 from crates.io | JavaBridge thread, from `postMessage` |
| `dev` | [`6642074`](https://github.com/tauri-apps/wry/tree/6642074224a2db9eb197f69d21b300b02b5dcd49), the merge base of [tauri-apps/wry#1891](https://github.com/tauri-apps/wry/pull/1891) | JavaBridge thread, from `postMessage` |
| `pr` | [`0c95f9a`](https://github.com/LucaCappelletti94/wry/tree/0c95f9a3577c4e5b9e9b6fc6ea69597dd772d272), an earlier head of that PR | background executor, from the message listener |
| `inline` | that head with [`inline.patch`](variants/inline.patch) | UI thread, from the message listener |

`inline.patch` is the [variant measured in the PR](https://github.com/tauri-apps/wry/pull/1891#issuecomment-6319812281), which drops the executor and passes `webView.url`.

## Run

Requires the [Tauri Android prerequisites](https://tauri.app/start/prerequisites/#android) and one emulator or device.

```sh
ANDROID_SERIAL=emulator-5554 ./repro.sh release 5 page-load
ANDROID_SERIAL=emulator-5554 ./repro.sh inline 5          # command mode
```

The build targets `x86_64`. Set `TARGET=aarch64` for a phone.

## Why it deadlocks

Tauri's `webview.url()` [forwards the call to the event loop thread](https://github.com/tauri-apps/tauri/blob/tauri-runtime-wry-v2.12.3/crates/tauri-runtime-wry/src/lib.rs#L263-L280) and [waits for its answer](https://github.com/tauri-apps/tauri/blob/tauri-runtime-wry-v2.12.3/crates/tauri-runtime-wry/src/lib.rs#L196-L203). The event loop thread [calls wry's `url()`](https://github.com/tauri-apps/tauri/blob/tauri-runtime-wry-v2.12.3/crates/tauri-runtime-wry/src/lib.rs#L3801-L3804), which [posts `GetUrl` to the main pipe and waits up to 10 s](https://github.com/tauri-apps/wry/blob/wry-v0.57.0/src/android/mod.rs#L346-L350), and only the UI thread drains the main pipe. When the first call is made on the UI thread, each thread waits on the other. After the timeout the UI thread drains the stale `GetUrl`, whose reply goes to a dropped receiver, and [the `unwrap` in `main_pipe.rs`](https://github.com/tauri-apps/wry/blob/wry-v0.57.0/src/android/main_pipe.rs#L421) aborts the process.

`on_page_load` already runs on the UI thread in released versions. In `inline`, sync commands do too.

## Results

Android 15 x86_64 emulator, WebView 124.0.6367.219, debug builds, cold start per run.

| Variant | Mode | Thread of the first call | `webview.url()` | Outcome |
|---|---|---|---|---|
| `release` | `page-load` | UI thread | 10 000 ms, then error | 5 of 5 crashed |
| `dev` | `command` | not the UI thread | 0–2 ms | 5 of 5 returned |
| `pr` | `command` | not the UI thread | 0–8 ms | 5 of 5 returned |
| `inline` | `command` | UI thread | 10 000 ms, then error | 5 of 5 crashed |

One `release page-load` run:

```
run 2: crashed
  10-22 11:02:37.475 REPRO on_page_load started, on_ui_thread=true
  10-22 11:02:37.486 REPRO read_url started, on_ui_thread=false
  10-22 11:02:47.477 REPRO on_page_load returned after 10001 ms, ok=false
  10-22 11:02:47.478 thread '<unnamed>' (8245) panicked at .../wry-0.57.0/src/android/main_pipe.rs:421:24:
  10-22 11:02:47.478 called `Result::unwrap()` on an `Err` value: "SendError(..)"
```
